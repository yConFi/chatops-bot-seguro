#!/usr/bin/env bash
# =============================================================================
# orden.sh — Cliente del bot ChatOps (Ejercicio 5)
#
# Autores : Pol, Fran, Javi, Yeray, Ricardo — Grupo 4
#           Máster de Ciberseguridad & IA (Evolve)
#
# Descripción:
#   Envía una orden firmada (HMAC-SHA256) al canal ordenes-g4 y espera como
#   máximo 15 s una respuesta de respuestas-g4 con el mismo id_orden y una
#   firma válida. NO valida ni limpia el objetivo: solo lo codifica con
#   jq --arg. La defensa está en el bot (y así la demo puede enviarle ataques).
#
# Uso:
#   export TOKEN_G4='...'  CLAVE='...'
#   ./orden.sh [opciones] <accion> [objetivo]
#     ./orden.sh ping 8.8.8.8
#     ./orden.sh estado
#     ./orden.sh puertos
#     ./orden.sh ayuda
#     ./orden.sh ping '8.8.8.8; id'      # ataque: SIEMPRE entre comillas simples
#
# Opciones (van ANTES de la acción; algunas SOLO PARA PRUEBAS):
#   --de NOMBRE     remitente (por defecto, el usuario local)
#   --sin-firma     [PRUEBAS] envía la orden sin firma
#   --firma-falsa   [PRUEBAS] envía una firma aleatoria
#   --ts-viejo      [PRUEBAS] envía un ts de hace 10 minutos
#   -h, --ayuda     muestra esta ayuda
#
# Variables de entorno: TOKEN_G4, CLAVE (obligatorias), RECEPTOR, URL_WEBHOOK,
#   URL_SYNC, MAX_BYTES_SYNC (iguales que en bot.sh).
#
# Códigos de salida: 0 ok · 1 respuesta error/rechazada · 2 uso o configuración
#                    3 sin respuesta válida en 15 s · 4 fallo de red al enviar
# =============================================================================
set -euo pipefail
umask 077
export LC_ALL=C

RUTA_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
readonly RUTA_SCRIPT
readonly ESPERA_MAX=15        # segundos en TOTAL
readonly MAX_TAM_MSG=4096

RECEPTOR="${RECEPTOR:-profesor}"
URL_WEBHOOK="${URL_WEBHOOK:-http://127.0.0.1:8099/webhook}"
URL_SYNC="${URL_SYNC:-http://127.0.0.1:8099/sync}"
MAX_BYTES_SYNC="${MAX_BYTES_SYNC:-2000000}"

# Opciones
MODO_FIRMA="normal"           # normal | sin | falsa
DE="${USER:-anonimo}"
TS_VIEJO=0
ACCION=""
OBJETIVO=""
TIENE_OBJETIVO=0

# Estado
DIR_TMP=""; F_RESPUESTA=""; F_CUERPO=""; F_SYNC=""; F_LISTA=""
HTTP_CODIGO=""
HTTP_MAX_TIEMPO=5
CURSOR=0
ID_ORDEN=""
ORDEN=""

# =============================================================================
# Utilidades
# =============================================================================

log() {
  printf '[orden] %s\n' "$(printf '%s' "$*" | tr -d '\000-\037\177')" >&2
}

# fallar MENSAJE… → error de configuración (código 2).
fallar() {
  log "ERROR: $*"
  exit 2
}

mostrar_uso() {
  sed -n '2,/^# =====/p' "$RUTA_SCRIPT" | sed -e '$d' -e 's/^# \{0,1\}//'
}

comprobar_dependencias() {
  local falta=() cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || falta+=("$cmd")
  done
  if (( ${#falta[@]} > 0 )); then
    printf 'ERROR: faltan dependencias: %s\n' "${falta[*]}" >&2
    printf 'En Kali: sudo apt install jq curl openssl coreutils\n' >&2
    exit 2
  fi
}

# Las opciones solo se aceptan ANTES de la acción. Todo lo que va después de la
# acción es el objetivo literal (aunque empiece por "-", p. ej. '-f').
leer_argumentos() {
  while (( $# > 0 )); do
    case "$1" in
      --sin-firma)   MODO_FIRMA="sin"; shift ;;
      --firma-falsa) MODO_FIRMA="falsa"; shift ;;
      --ts-viejo)    TS_VIEJO=1; shift ;;
      --de)
        if (( $# < 2 )); then log "ERROR: --de necesita un nombre"; exit 2; fi
        DE="$2"; shift 2 ;;
      -h|--ayuda)    mostrar_uso; exit 0 ;;
      --)            shift; break ;;
      --*)           log "ERROR: opción desconocida"; mostrar_uso >&2; exit 2 ;;
      *)             break ;;
    esac
  done
  if (( $# < 1 || $# > 2 )); then
    log "ERROR: uso: orden.sh [opciones] <accion> [objetivo]  (pon el objetivo entre comillas simples)"
    exit 2
  fi
  ACCION="$1"
  if (( $# == 2 )); then
    OBJETIVO="$2"
    TIENE_OBJETIVO=1
  fi
}

comprobar_entorno() {
  [[ -n "${TOKEN_G4:-}" ]] || fallar "falta TOKEN_G4 (export TOKEN_G4=...)"
  [[ -n "${CLAVE:-}" ]]    || fallar "falta CLAVE (export CLAVE=...). No hay clave por defecto."
  [[ "$TOKEN_G4" =~ ^[A-Za-z0-9._~-]+$ ]] || fallar "TOKEN_G4 contiene caracteres no válidos para una URL"
  case "$RECEPTOR" in
    profesor) ;;
    webhooksite) fallar "RECEPTOR=webhooksite es solo un esqueleto documentado (ver TODO en el código)" ;;
    *) fallar "RECEPTOR debe ser 'profesor' o 'webhooksite'" ;;
  esac
  [[ "$MAX_BYTES_SYNC" =~ ^[1-9][0-9]{0,9}$ ]] || fallar "MAX_BYTES_SYNC debe ser un entero positivo"
}

# =============================================================================
# Transporte HTTP (mismo diseño que bot.sh)
# =============================================================================

# peticion_http METODO URL [FICHERO_CUERPO]
#   0 = 2xx · 1 = fallo temporal · 2 = 403. La URL nunca se registra (lleva el token).
peticion_http() {
  local metodo="$1" url="$2" cuerpo="${3:-}" rc=0
  local opciones=(--silent --connect-timeout 5 --max-time "$HTTP_MAX_TIEMPO"
                  --max-filesize "$MAX_BYTES_SYNC" --output "$F_RESPUESTA"
                  --write-out '%{http_code}' --request "$metodo")
  if [[ -n "$cuerpo" ]]; then
    opciones+=(--header 'Content-Type: application/json' --data-binary "@$cuerpo")
  fi
  : > "$F_RESPUESTA"
  HTTP_CODIGO="$(curl "${opciones[@]}" "$url" 2>/dev/null)" || rc=$?
  case "$rc" in
    0)  ;;
    6)  log "fallo de DNS al contactar con el receptor"; return 1 ;;
    7)  log "no se puede conectar con el receptor (¿servidor caído?)"; return 1 ;;
    28) log "tiempo de espera agotado con el receptor"; return 1 ;;
    63) log "respuesta mayor de $MAX_BYTES_SYNC bytes: descartada"; return 1 ;;
    *)  log "error de curl (código $rc)"; return 1 ;;
  esac
  case "$HTTP_CODIGO" in
    2??) return 0 ;;
    403) log "HTTP 403: token incorrecto o configuración errónea"; return 2 ;;
    5??) log "HTTP $HTTP_CODIGO: error del servidor"; return 1 ;;
    *)   log "HTTP inesperado: $HTTP_CODIGO"; return 1 ;;
  esac
}

publicar_profesor() {
  local rc=0
  printf '%s' "$1" > "$F_CUERPO"
  peticion_http POST "$URL_WEBHOOK/$TOKEN_G4" "$F_CUERPO" || rc=$?
  if (( rc == 2 )); then
    fallar "el servidor rechaza el token (403). Revisa TOKEN_G4 y URL_WEBHOOK."
  fi
  (( rc == 0 )) || return 1
  if ! jq -e '.ok == true' "$F_RESPUESTA" >/dev/null 2>&1; then
    log "el receptor no confirmó la publicación (respuesta vacía o JSON inválido)"
    return 1
  fi
}

consultar_profesor() {
  local desde="${1:-}" url="$URL_SYNC" rc=0
  if [[ -n "$desde" ]]; then
    url="$URL_SYNC?since=$desde"
  fi
  peticion_http GET "$url" || rc=$?
  (( rc == 0 )) || return 1
  if ! jq -e 'type == "object" and (.messages | type) == "array"
              and ((.last_id | type) == "number" or .last_id == null)' \
       "$F_RESPUESTA" >/dev/null 2>&1; then
    log "respuesta de /sync vacía o con JSON inválido"
    return 1
  fi
  cp -- "$F_RESPUESTA" "$F_SYNC"
}

# --- Plan B: webhook.site (ESQUELETO, no operativo) ---------------------------
# TODO 1: crear el canal: curl -s -X POST https://webhook.site/token | jq -r .uuid
# TODO 2: publicar = POST https://webhook.site/$WEBHOOKSITE_UUID con el JSON.
# TODO 3: consultar = GET https://webhook.site/token/$WEBHOOKSITE_UUID/requests;
#         cuerpo como TEXTO en .data[].content (fromjson con try); sin "since".
publicar_webhooksite()  { log "RECEPTOR=webhooksite: pendiente (TODO)"; return 1; }
consultar_webhooksite() { log "RECEPTOR=webhooksite: pendiente (TODO)"; return 1; }

publicar() {
  case "$RECEPTOR" in
    profesor)    publicar_profesor "$1" ;;
    webhooksite) publicar_webhooksite "$1" ;;
  esac
}

consultar() {
  case "$RECEPTOR" in
    profesor)    consultar_profesor "${1:-}" ;;
    webhooksite) consultar_webhooksite "${1:-}" ;;
  esac
}

# =============================================================================
# HMAC-SHA256 (mismas funciones en bot.sh y orden.sh)
# =============================================================================

hmac_hex() {
  openssl dgst -sha256 -hmac "$CLAVE" | awk '{print $NF}'
}

canonico() {
  jq -cS 'del(.firma, ._id, ._recibido, ._origen)' <<<"$1"
}

firmar() {
  local canon firma
  canon="$(canonico "$1")" || return 1
  firma="$(printf '%s' "$canon" | hmac_hex)" || return 1
  jq -c --arg firma "$firma" '. + {firma: $firma}' <<<"$1"
}

verificar() {
  local recibida esperada canon
  recibida="$(jq -r 'if (.firma | type) == "string" then .firma else "" end' <<<"$1")" || return 1
  [[ "$recibida" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  canon="$(canonico "$1")" || return 1
  esperada="$(printf '%s' "$canon" | hmac_hex)" || return 1
  [[ "${recibida,,}" == "$esperada" ]]
}

# =============================================================================
# Orden y respuesta
# =============================================================================

construir_orden() {
  local ts
  ID_ORDEN="$(openssl rand -hex 4)"
  if (( TS_VIEJO )); then
    ts="$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  else
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  # jq --arg codifica CUALQUIER texto como cadena JSON (comillas, ;, $(), saltos...).
  ORDEN="$(jq -nc --arg id "$ID_ORDEN" --arg de "$DE" --arg accion "$ACCION" --arg ts "$ts" \
      --arg objetivo "$OBJETIVO" --argjson con_obj "$TIENE_OBJETIVO" \
      '{id_orden: $id, de: $de, accion: $accion,
        args: (if $con_obj == 1 then {objetivo: $objetivo} else {} end),
        ts: $ts, canal: "ordenes-g4"}')"
  case "$MODO_FIRMA" in
    normal) ORDEN="$(firmar "$ORDEN")" ;;
    falsa)  ORDEN="$(jq -c --arg f "$(openssl rand -hex 32)" '. + {firma: $f}' <<<"$ORDEN")" ;;
    sin)    ;;
  esac
}

# mostrar_respuesta JSON → nunca envía caracteres de control al terminal.
mostrar_respuesta() {
  local resp="$1"
  local limpio='def limpio: tostring | explode | map(select((. >= 32 and . < 127) or . >= 160 or . == 10)) | implode;'
  jq -r "$limpio"'
    "id_orden      : \(.id_orden | limpio)",
    "bot           : \(.bot | limpio)",
    "estado        : \(.estado | limpio)",
    "codigo_salida : \(.codigo_salida | limpio)",
    "duracion_ms   : \(.duracion_ms | limpio)",
    "salida        :"' <<<"$resp"
  if jq -e '.salida | fromjson' <<<"$resp" >/dev/null 2>&1; then
    jq '.salida | fromjson' <<<"$resp"         # jq escapa los controles al imprimir JSON
  else
    jq -r "$limpio"' .salida | limpio' <<<"$resp"
  fi
}

# esperar_respuesta → 0 ok · 1 error/rechazada · 3 sin respuesta válida a tiempo.
esperar_respuesta() {
  local linea id_msg estado restante
  while (( SECONDS < ESPERA_MAX )); do
    restante=$(( ESPERA_MAX - SECONDS ))
    HTTP_MAX_TIEMPO=$(( restante < 5 ? restante : 5 ))
    if (( HTTP_MAX_TIEMPO > 0 )) && consultar "$CURSOR"; then
      jq -c --argjson cursor "$CURSOR" --argjson tam "$MAX_TAM_MSG" '
          [ .messages[]
            | select(type == "object" and (._id | type) == "number"
                     and ._id == (._id | floor) and ._id > $cursor and ._id < 1e15) ]
          | sort_by(._id) | .[]
          | select((tojson | utf8bytelength) <= $tam)' "$F_SYNC" > "$F_LISTA" || : > "$F_LISTA"
      while IFS= read -r linea <&3; do
        id_msg="$(jq -r '._id | floor' <<<"$linea")"
        [[ "$id_msg" =~ ^[0-9]{1,15}$ ]] && CURSOR="$id_msg"
        # Solo nos interesan respuestas de respuestas-g4 con NUESTRO id_orden.
        if [[ "$(jq -r --arg id "$ID_ORDEN" \
                 '.canal == "respuestas-g4" and has("bot") and .id_orden == $id' <<<"$linea")" != "true" ]]; then
          continue
        fi
        if ! verificar "$linea"; then
          log "AVISO: llegó una respuesta con nuestro id_orden pero firma NO válida: ignorada"
          continue
        fi
        mostrar_respuesta "$linea"
        estado="$(jq -r '.estado' <<<"$linea")"
        if [[ "$estado" == "ok" ]]; then return 0; else return 1; fi
      done 3< "$F_LISTA"
    fi
    if (( SECONDS < ESPERA_MAX )); then sleep 1; fi
  done
  log "ERROR: sin respuesta válida en ${ESPERA_MAX} s (¿bot apagado, relojes desincronizados o CLAVE distinta?)"
  return 3
}

# shellcheck disable=SC2317,SC2329  # se invoca desde el trap EXIT
limpiar() {
  local codigo=$?
  trap - EXIT INT TERM
  if [[ -n "$DIR_TMP" && -d "$DIR_TMP" ]]; then rm -rf -- "$DIR_TMP"; fi
  exit "$codigo"
}

main() {
  local rc=0
  leer_argumentos "$@"
  comprobar_dependencias jq curl openssl date awk tr sed readlink mktemp
  comprobar_entorno
  trap limpiar EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  DIR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/orden_g4.XXXXXX")"
  F_RESPUESTA="$DIR_TMP/respuesta"; F_CUERPO="$DIR_TMP/cuerpo"
  F_SYNC="$DIR_TMP/sync"; F_LISTA="$DIR_TMP/lista"

  SECONDS=0   # el límite de 15 s cuenta desde aquí

  # 1. last_id ANTES de enviar: la respuesta tendrá un _id mayor. Hace falta /sync
  #    completo: con un since enorme el servidor real devuelve last_id = since.
  consultar "" || { log "ERROR: no se pudo leer el canal antes de enviar"; exit 4; }
  CURSOR="$(jq -r '.last_id // 0 | floor' "$F_SYNC")"
  [[ "$CURSOR" =~ ^[0-9]{1,15}$ ]] || { log "ERROR: last_id inesperado en /sync"; exit 4; }

  # 2. Construir y enviar.
  construir_orden
  case "$MODO_FIRMA" in
    sin)   log "[PRUEBAS] orden enviada SIN firma" ;;
    falsa) log "[PRUEBAS] orden enviada con firma FALSA" ;;
  esac
  if (( TS_VIEJO )); then log "[PRUEBAS] orden enviada con ts de hace 10 minutos"; fi
  publicar "$ORDEN" || { log "ERROR: no se pudo enviar la orden"; exit 4; }
  log "orden enviada (id_orden=$ID_ORDEN). JSON enviado:"
  jq . <<<"$ORDEN" >&2

  # 3. Esperar la respuesta firmada (15 s en total).
  log "esperando respuesta..."
  esperar_respuesta || rc=$?
  exit "$rc"
}

main "$@"
