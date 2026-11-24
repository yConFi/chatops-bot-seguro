#!/usr/bin/env bash
# =============================================================================
# bot.sh — Bot ChatOps con lista blanca de órdenes (Ejercicio 5)
#
# Autores : Pol, Fran, Javi, Yeray, Ricardo — Grupo 4
#           Máster de Ciberseguridad & IA (Evolve)
#
# Descripción:
#   Consulta el canal del grupo cada 2 s, trata TODO mensaje recibido como
#   hostil y solo ejecuta acciones de una lista blanca (ping, estado, puertos,
#   ayuda). Cada orden candidata con id válido recibe una respuesta firmada con
#   HMAC-SHA256 y deja una línea en auditoria.jsonl.
#   Nunca interpreta texto recibido como código: sin eval, sin bash -c, sin source.
#
# Uso:
#   export TOKEN_G4='...'   # secreto: solo por variable de entorno
#   export CLAVE='...'      # secreto HMAC compartido: solo por variable de entorno
#   ./bot.sh                # arranca el bucle principal (Ctrl+C para parar)
#   ./bot.sh --ayuda        # muestra esta ayuda
#   (uso interno) ./bot.sh --trabajador estado|puertos|ayuda
#
# Variables de entorno:
#   TOKEN_G4       obligatoria. Token del webhook del grupo.
#   CLAVE          obligatoria. Clave HMAC. No hay valor por defecto.
#   RECEPTOR       profesor (por defecto) | webhooksite (solo esqueleto).
#   EXIGIR_FIRMA   1 (por defecto) | 0 (acepta órdenes sin firma, con aviso).
#   URL_WEBHOOK    por defecto http://127.0.0.1:8099/webhook
#   URL_SYNC       por defecto http://127.0.0.1:8099/sync
#   DIR_ESTADO     por defecto ./estado_bot (permisos 700)
#   NOMBRE_BOT     por defecto kali-g4
#   MAX_MSGS_CICLO máximo de mensajes procesados por ciclo (por defecto 20)
#   MAX_BYTES_SYNC tamaño máximo aceptado de /sync en bytes (por defecto 2000000)
# =============================================================================
set -euo pipefail
umask 077            # todo lo que crea el bot es privado (rw solo para el dueño)
export LC_ALL=C      # regex y rangos [A-Za-z] estrictamente ASCII, salida en inglés

# --- Constantes --------------------------------------------------------------
RUTA_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
readonly RUTA_SCRIPT
DIR_SCRIPT="$(dirname "$RUTA_SCRIPT")"
readonly DIR_SCRIPT

readonly INTERVALO=2             # segundos entre consultas
readonly TIMEOUT_ACCION=10       # timeout de cada acción
readonly MAX_SALIDA=2000         # caracteres máximos de "salida"
readonly MAX_CAPTURA=8000        # bytes máximos capturados de un comando
readonly MAX_TAM_MSG=4096        # bytes máximos de un mensaje
readonly VENTANA_TS=60           # ± segundos aceptados en "ts"
readonly LIMITE_FRECUENCIA=5     # órdenes por "de"...
readonly VENTANA_FRECUENCIA=60   # ...en esta ventana deslizante (s)
readonly MAX_VISTOS=10000        # ids recordados (de sobra con ventana de 60 s)
readonly HTTP_MAX_TIEMPO=8       # --max-time de curl
readonly UMBRAL_SALTO=3          # fallos de contenido seguidos de /sync antes de saltar un mensaje
readonly SINCE_MAX=999999999999999   # since mayor que cualquier _id: /sync sin mensajes (prueba de salud)

# Expresiones regulares (LC_ALL=C → solo ASCII).
readonly RE_ID='^[A-Za-z0-9_-]{1,32}$'
readonly OCTETO='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'   # 0-255 sin ceros a la izquierda
readonly RE_IPV4="^${OCTETO}[.]${OCTETO}[.]${OCTETO}[.]${OCTETO}$"
readonly ETIQUETA='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'    # 1-63, sin guion al inicio/fin
readonly RE_HOST="^${ETIQUETA}([.]${ETIQUETA})*$"
readonly RE_TS='^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})([.][0-9]{1,6})?Z$'

# --- Configuración (solo desde el entorno) -----------------------------------
RECEPTOR="${RECEPTOR:-profesor}"
EXIGIR_FIRMA="${EXIGIR_FIRMA:-1}"
URL_WEBHOOK="${URL_WEBHOOK:-http://127.0.0.1:8099/webhook}"
URL_SYNC="${URL_SYNC:-http://127.0.0.1:8099/sync}"
DIR_ESTADO="${DIR_ESTADO:-$DIR_SCRIPT/estado_bot}"
NOMBRE_BOT="${NOMBRE_BOT:-kali-g4}"
MAX_MSGS_CICLO="${MAX_MSGS_CICLO:-20}"
MAX_BYTES_SYNC="${MAX_BYTES_SYNC:-2000000}"

# --- Estado global -----------------------------------------------------------
F_CURSOR="$DIR_ESTADO/cursor"
F_VISTOS="$DIR_ESTADO/ids_vistos.txt"
F_FRECUENCIA="$DIR_ESTADO/frecuencia.json"
F_BLOQUEO="$DIR_ESTADO/bot.lock"
F_AUDITORIA="$DIR_ESTADO/auditoria.jsonl"

DIR_TMP=""          # temporales de esta ejecución (se borran al salir)
F_RESPUESTA=""      # cuerpo de la última respuesta HTTP
F_CUERPO=""         # cuerpo a enviar por POST
F_SYNC=""           # último /sync validado
F_LISTA=""          # mensajes nuevos, uno por línea
F_BRUTO=""          # salida completa de la acción
F_SALIDA=""         # salida recortada con head -c
PID_HIJO=""         # proceso en curso (para matarlo al salir)
ESTADO_LISTO=0      # 1 cuando tenemos el bloqueo y el directorio de estado
HTTP_CODIGO=""
CURSOR=0            # último _id tratado
ULTIMO_ID=0         # last_id del canal (lo rellena leer_last_id)
FALLOS_CONTENIDO=0  # ciclos seguidos en los que /sync llegó pero no se pudo interpretar

# Contexto del mensaje que se está procesando.
MSG=""; MSG_ID=""; ID_ORDEN=""; T_INICIO=0; MOTIVO=""; AVISO=""; DURACION=""
EJ_CODIGO=0

# =============================================================================
# Utilidades
# =============================================================================

# log MENSAJE… → stderr con hora; quita caracteres de control (anti-inyección en terminal).
log() {
  printf '%s [bot] %s\n' "$(date -u +%H:%M:%S)" "$(printf '%s' "$*" | tr -d '\000-\037\177')" >&2
}

# fallar MENSAJE… → error fatal (la limpieza la hace el trap EXIT).
fallar() {
  log "ERROR: $*"
  exit 1
}

mostrar_uso() {
  sed -n '2,/^# =====/p' "$RUTA_SCRIPT" | sed -e '$d' -e 's/^# \{0,1\}//'
}

# comprobar_dependencias CMD… → sale con mensaje claro si falta alguna.
comprobar_dependencias() {
  local falta=() cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || falta+=("$cmd")
  done
  if (( ${#falta[@]} > 0 )); then
    printf 'ERROR: faltan dependencias: %s\n' "${falta[*]}" >&2
    printf 'En Kali: sudo apt install jq curl openssl iputils-ping iproute2 util-linux procps coreutils\n' >&2
    exit 1
  fi
}

# ahora_ms → milisegundos de un reloj MONOTÓNICO (tiempo desde el arranque).
#   Solo sirve para medir duraciones (restas), no como fecha. No usamos `date`
#   porque el reloj de pared puede saltar (NTP, WSL2 sincronizando con Windows)
#   y dar duraciones falsas; /proc/uptime nunca va hacia atrás.
#   Formato "SEGUNDOS.CC": 10# evita que "05" se lea como octal.
ahora_ms() {
  local up _
  read -r up _ < /proc/uptime
  printf '%s\n' "$(( ${up%.*} * 1000 + 10#${up#*.} * 10 ))"
}

# esperar SEGUNDOS → sleep interrumpible por Ctrl+C / SIGTERM.
esperar() {
  sleep "$1" &
  PID_HIJO=$!
  wait "$PID_HIJO" || true
  PID_HIJO=""
}

# escribir_atomico DESTINO CONTENIDO → mktemp en el mismo directorio + mv (atómico).
escribir_atomico() {
  local destino="$1" contenido="$2" tmp
  tmp="$(mktemp "$DIR_ESTADO/.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$contenido" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$destino"
}

# =============================================================================
# Modo trabajador: acciones de varios comandos, lanzadas con timeout.
# No consulta ni publica nada. Imprime JSON compacto por stdout.
# =============================================================================

trabajador_estado() {
  local arranque mem_total mem_usada mem_disp disco_total disco_usado disco_libre disco_uso
  arranque="$(uptime -p)"
  read -r mem_total mem_usada mem_disp < <(free -m | awk '$1 == "Mem:" {print $2, $3, $7}')
  read -r disco_total disco_usado disco_libre disco_uso < <(df -Pm / | awk 'NR == 2 {print $2, $3, $4, $5}')
  # --argjson falla si el valor no es un número: nunca se mete texto arbitrario en el JSON.
  jq -nc --arg uptime "$arranque" \
    --argjson mt "$mem_total" --argjson mu "$mem_usada" --argjson md "$mem_disp" \
    --argjson dt "$disco_total" --argjson du "$disco_usado" --argjson dl "$disco_libre" \
    --arg dp "$disco_uso" \
    '{uptime: $uptime,
      memoria_mb: {total: $mt, usada: $mu, disponible: $md},
      disco_raiz_mb: {total: $dt, usado: $du, libre: $dl, uso: $dp}}'
}

trabajador_puertos() {
  # Columnas de ss -tuln: Netid State Recv-Q Send-Q Local:Puerto Peer:Puerto
  # Sin puertos en escucha → [] (jq con entrada vacía).
  ss -tuln | awk 'NR > 1 {print $1, $2, $5}' \
    | jq -Rnc '[inputs | split(" ") | {protocolo: .[0], estado: .[1], local: .[2]}]'
}

trabajador_ayuda() {
  jq -nc '{acciones: [
    {accion: "ping",    args: {objetivo: "IPv4 o nombre de host (obligatorio)"}, descripcion: "envía 4 paquetes ICMP"},
    {accion: "estado",  args: {}, descripcion: "uptime, memoria y disco"},
    {accion: "puertos", args: {}, descripcion: "puertos en escucha (ss -tuln)"},
    {accion: "ayuda",   args: {}, descripcion: "esta lista"}]}'
}

trabajador() {
  case "${1:-}" in
    estado)  trabajador_estado ;;
    puertos) trabajador_puertos ;;
    ayuda)   trabajador_ayuda ;;
    *)       printf 'trabajador: subcomando desconocido\n' >&2; exit 2 ;;
  esac
}

# =============================================================================
# Transporte HTTP: publicar() y consultar(). El resto del código no sabe
# qué receptor se usa.
# =============================================================================

# peticion_http METODO URL [FICHERO_CUERPO]
#   Deja el cuerpo en $F_RESPUESTA y el código HTTP en $HTTP_CODIGO.
#   Devuelve 0 = 2xx · 1 = fallo temporal (5xx, timeout, red, DNS, tamaño) · 2 = 403.
#   La URL nunca se escribe en el log (contiene el token).
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

# --- Receptor principal: servidor del profesor (verificado) -------------------
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

# consultar_profesor [SINCE] → deja en $F_SYNC un /sync validado.
#   Devuelve 0 = ok · 1 = fallo de red o HTTP · 3 = llegó (2xx) pero no se puede
#   interpretar (JSON inválido o estructura inesperada: posible mensaje envenenado).
consultar_profesor() {
  local desde="${1:-}" url="$URL_SYNC" rc=0
  if [[ -n "$desde" ]]; then
    url="$URL_SYNC?since=$desde"      # el parámetro se llama "since"
  fi
  peticion_http GET "$url" || rc=$?
  (( rc == 0 )) || return 1
  if ! jq -e 'type == "object" and (.messages | type) == "array"
              and ((.last_id | type) == "number" or .last_id == null)' \
       "$F_RESPUESTA" >/dev/null 2>&1; then
    log "respuesta de /sync vacía o con JSON inválido"
    return 3
  fi
  cp -- "$F_RESPUESTA" "$F_SYNC"
}

# leer_last_id → deja en ULTIMO_ID el last_id actual del canal (con /sync completo).
#   NO vale pedir un since enorme: el servidor real devuelve last_id = since cuando
#   since es mayor que el último _id (comprobado el 2026-11-24).
leer_last_id() {
  local valor
  consultar "" || return $?
  valor="$(jq -r '.last_id // 0 | floor' "$F_SYNC")"
  [[ "$valor" =~ ^[0-9]{1,15}$ ]] || return 3
  ULTIMO_ID=$(( 10#$valor ))
}

# --- Plan B: webhook.site (ESQUELETO, no operativo) ---------------------------
# TODO 1: crear el canal una vez:
#           curl -s -X POST https://webhook.site/token | jq -r .uuid
#         y exportar WEBHOOKSITE_UUID con ese valor.
# TODO 2: publicar = POST https://webhook.site/$WEBHOOKSITE_UUID con el JSON.
# TODO 3: consultar = GET https://webhook.site/token/$WEBHOOKSITE_UUID/requests
#         El cuerpo llega como TEXTO en .data[].content → aplicar fromjson con try.
#         No existe "since": habría que numerar en local, filtrar por cursor y
#         devolver el mismo formato {last_id, messages:[...]} que /sync.
# Limitaciones: sin paginación ni persistencia garantizada. Solo plan B.
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

# hmac_hex → HMAC-SHA256 en hexadecimal de la entrada estándar. Nunca registra la clave.
hmac_hex() {
  openssl dgst -sha256 -hmac "$CLAVE" | awk '{print $NF}'
}

# canonico JSON → claves ordenadas (-S), compacto (-c), sin firma ni metadatos del servidor.
canonico() {
  jq -cS 'del(.firma, ._id, ._recibido, ._origen)' <<<"$1"
}

# firmar JSON → imprime el JSON con el campo "firma" añadido.
firmar() {
  local canon firma
  canon="$(canonico "$1")" || return 1
  firma="$(printf '%s' "$canon" | hmac_hex)" || return 1
  jq -c --arg firma "$firma" '. + {firma: $firma}' <<<"$1"
}

# verificar JSON → 0 si "firma" tiene formato válido y coincide.
verificar() {
  local recibida esperada canon
  recibida="$(jq -r 'if (.firma | type) == "string" then .firma else "" end' <<<"$1")" || return 1
  [[ "$recibida" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  canon="$(canonico "$1")" || return 1
  esperada="$(printf '%s' "$canon" | hmac_hex)" || return 1
  [[ "${recibida,,}" == "$esperada" ]]
}

# =============================================================================
# Validaciones
# =============================================================================

# leer_texto FILTRO → imprime el campo de $MSG solo si es una cadena SIN
#   caracteres de control (\n, ESC, NUL, C1...). Falla si falta o no es cadena.
#   FILTRO es siempre una constante de este script, nunca un dato recibido.
leer_texto() {
  jq -j "$1"' | if type == "string" and (explode | all(. >= 32 and (. < 127 or . >= 160)))
                then . else error("no válido") end' <<<"$MSG" 2>/dev/null
}

# validar_objetivo TEXTO → 0 si es IPv4 válida o nombre de host válido.
validar_objetivo() {
  local o="$1"
  if (( ${#o} < 1 || ${#o} > 253 )); then return 1; fi
  if [[ "$o" == -* ]]; then return 1; fi          # inyección de argumentos (-f, -c 100000)
  if [[ "$o" =~ ^[0-9.]+$ ]]; then                # parece numérico → solo vale como IPv4
    [[ "$o" =~ $RE_IPV4 ]]
    return
  fi
  [[ "$o" =~ $RE_HOST ]] || return 1
  [[ "${o##*.}" =~ [A-Za-z] ]]                    # la última etiqueta no puede ser solo números
}

# validar_ts TS → 0 si es ISO 8601 UTC real y está a ±VENTANA_TS del reloj local.
validar_ts() {
  local ts="$1" base epoch ahora diferencia
  if [[ ! "$ts" =~ $RE_TS ]]; then
    MOTIVO="ts no tiene formato ISO 8601 UTC (AAAA-MM-DDThh:mm:ssZ)"
    return 1
  fi
  base="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  if ! epoch="$(date -u -d "$base UTC" +%s 2>/dev/null)" \
     || [[ "$(date -u -d "@$epoch" '+%Y-%m-%d %H:%M:%S')" != "$base" ]]; then
    MOTIVO="ts no es una fecha real"
    return 1
  fi
  ahora="$(date -u +%s)"
  diferencia=$(( ahora - epoch ))
  if (( diferencia > VENTANA_TS || diferencia < -VENTANA_TS )); then
    MOTIVO="ts fuera de la ventana de ±${VENTANA_TS} s (repetición o relojes desincronizados)"
    return 1
  fi
}

id_ya_visto() {
  grep -Fxq -- "$1" "$F_VISTOS"
}

marcar_visto() {
  local contenido
  contenido="$(tail -n "$(( MAX_VISTOS - 1 ))" "$F_VISTOS"; printf '%s' "$1")" || return 1
  escribir_atomico "$F_VISTOS" "$contenido"
}

# registrar_frecuencia DE → 0 y anota la orden si DE no supera el límite.
registrar_frecuencia() {
  local de="$1" ahora desde usadas nuevo
  ahora="$(date +%s)"
  desde=$(( ahora - VENTANA_FRECUENCIA ))
  if ! usadas="$(jq --arg de "$de" --argjson desde "$desde" \
        '[.[] | select(.de == $de and .t > $desde)] | length' "$F_FRECUENCIA")"; then
    MOTIVO="error interno leyendo el límite de frecuencia"
    return 1
  fi
  if (( usadas >= LIMITE_FRECUENCIA )); then
    MOTIVO="límite de frecuencia: máximo $LIMITE_FRECUENCIA órdenes por minuto para '$de'"
    return 1
  fi
  if ! nuevo="$(jq -c --arg de "$de" --argjson desde "$desde" --argjson ahora "$ahora" \
        '[.[] | select(.t > $desde)] + [{t: $ahora, de: $de}]' "$F_FRECUENCIA")" \
     || ! escribir_atomico "$F_FRECUENCIA" "$nuevo"; then
    MOTIVO="error interno guardando el límite de frecuencia"
    return 1
  fi
}

# =============================================================================
# Auditoría, respuestas y ejecución
# =============================================================================

# auditar DECISION MOTIVO [ESTADO] [CODIGO_JSON] [PUBLICADA_JSON]
auditar() {
  local decision="$1" motivo="$2" estado="${3:-}" codigo="${4:-null}" publicada="${5:-null}"
  local m="${MSG:-null}" dur="${DURACION:-$(( $(ahora_ms) - T_INICIO ))}"
  jq -nc --argjson m "$m" --argjson idm "${MSG_ID:-null}" --arg id "$ID_ORDEN" \
    --arg decision "$decision" --arg motivo "$motivo" --arg estado "$estado" \
    --argjson codigo "$codigo" --argjson dur "$dur" --argjson publicada "$publicada" \
    --arg aviso "$AVISO" '
    def limpio: tostring | explode | map(select((. >= 32 and . < 127) or . >= 160)) | implode | .[0:200];
    def campo($k): if ($m | type) == "object" and ($m | has($k)) then ($m | .[$k] | limpio) else null end;
    {ts: (now | todate), _id: $idm,
     id_orden: (if $id == "" then null else $id end),
     de: campo("de"), accion: campo("accion"),
     decision: $decision, motivo: ($motivo | limpio),
     estado: (if $estado == "" then null else $estado end),
     codigo_salida: $codigo, duracion_ms: $dur, publicada: $publicada}
    + (if $aviso == "" then {} else {aviso: $aviso} end)' >> "$F_AUDITORIA" \
    || log "no se pudo escribir en la auditoría"
}

# responder ESTADO CODIGO_JSON FICHERO_SALIDA MODO(texto|json) → construye, firma y publica.
responder() {
  local estado="$1" codigo="$2" fichero="$3" modo="$4" respuesta
  DURACION=$(( $(ahora_ms) - T_INICIO ))
  respuesta="$(jq -nc --arg id "$ID_ORDEN" --arg bot "$NOMBRE_BOT" --arg estado "$estado" \
      --argjson codigo "$codigo" --rawfile bruto "$fichero" --arg modo "$modo" \
      --argjson max "$MAX_SALIDA" --argjson dur "$DURACION" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      # Recorte por caracteres dentro de jq (nunca a mitad de un carácter).
      # En modo json se quitan elementos del array hasta que quepa: el JSON sigue siendo válido.
      def recortar:
        if $modo == "json" then
          (. as $s | try (fromjson
                          | if type == "array" then until((tojson | length) <= $max; .[:-1]) else . end
                          | tojson)
                     catch $s)
        else . end
        | .[0:$max];
      {id_orden: $id, bot: $bot, estado: $estado, codigo_salida: $codigo,
       salida: ($bruto | recortar), duracion_ms: $dur, ts: $ts, canal: "respuestas-g4"}')" \
    || return 1
  respuesta="$(firmar "$respuesta")" || return 1
  publicar "$respuesta"
}

# rechazar MOTIVO → responde "rechazada" (sin ejecutar nada) y lo audita.
rechazar() {
  local motivo="$1" publicada="true"
  printf 'rechazada: %s' "$motivo" > "$F_SALIDA"
  if ! responder "rechazada" null "$F_SALIDA" texto; then
    publicada="false"
    log "no se pudo publicar la respuesta de $ID_ORDEN (no se reintenta)"
  fi
  auditar rechazada "$motivo" rechazada null "$publicada"
  log "orden $ID_ORDEN RECHAZADA: $motivo"
}

# correr_con_timeout CMD ARG… → ejecuta con timeout, en segundo plano + wait
#   para que Ctrl+C sea inmediato. Deja el código en EJ_CODIGO y la salida en F_SALIDA.
#   timeout (sin --foreground) mata a todo su grupo de procesos: no quedan huérfanos.
correr_con_timeout() {
  EJ_CODIGO=0
  timeout "$TIMEOUT_ACCION" "$@" > "$F_BRUTO" 2>&1 < /dev/null &
  PID_HIJO=$!
  wait "$PID_HIJO" || EJ_CODIGO=$?
  PID_HIJO=""
  head -c "$MAX_CAPTURA" "$F_BRUTO" > "$F_SALIDA"
}

# ejecutar_accion ACCION OBJETIVO → selección con case. El objetivo llega a ping
#   como UN solo argumento, entre comillas y después de "--".
ejecutar_accion() {
  local accion="$1" objetivo="$2"
  case "$accion" in
    ping)    correr_con_timeout ping -c 4 -- "$objetivo" ;;
    estado)  correr_con_timeout bash "$RUTA_SCRIPT" --trabajador estado ;;
    puertos) correr_con_timeout bash "$RUTA_SCRIPT" --trabajador puertos ;;
    ayuda)   correr_con_timeout bash "$RUTA_SCRIPT" --trabajador ayuda ;;
    *)       return 1 ;;   # inalcanzable: ya filtrado por la lista blanca
  esac
}

# =============================================================================
# Pipeline de validación de un mensaje (orden del enunciado, §6)
# =============================================================================

# procesar_mensaje _ID JSON|null
procesar_mensaje() {
  MSG_ID="$1"; MSG="$2"; ID_ORDEN=""; MOTIVO=""; AVISO=""; DURACION=""
  T_INICIO="$(ahora_ms)"
  local tipo extra de accion ts objetivo="" tiene_objetivo=0 estado modo motivo_ej publicada

  # 1. Tamaño ≤ 4 KB (jq ya garantizó JSON válido y raíz objeto al leer /sync).
  if [[ "$MSG" == "null" ]]; then
    auditar ignorada "mensaje mayor de $MAX_TAM_MSG bytes"
    log "mensaje $MSG_ID ignorado: demasiado grande"
    return 0
  fi

  # 2. Clasificar: respuesta o ajeno → ignorar; sin canal u ordenes-g4 → candidata.
  tipo="$(jq -r '
      if has("bot") then "respuesta"
      elif (has("canal") | not) then "orden"
      elif .canal == "ordenes-g4" then "orden"
      elif .canal == "respuestas-g4" then "respuesta"
      else "ajeno" end' <<<"$MSG")"
  if [[ "$tipo" != "orden" ]]; then
    log "mensaje $MSG_ID ignorado ($tipo)"
    return 0
  fi

  # 3. id_orden válido; si no, no hay a quién responder.
  if ! ID_ORDEN="$(leer_texto '.id_orden')" || [[ ! "$ID_ORDEN" =~ $RE_ID ]]; then
    ID_ORDEN=""
    auditar ignorada "id_orden ausente o no válido: no se puede responder"
    log "mensaje $MSG_ID ignorado: id_orden no válido"
    return 0
  fi

  # 4. Claves permitidas (contrato + canal + firma + metadatos del servidor).
  extra="$(jq -r '[keys[] | select(IN("id_orden","de","accion","args","ts","canal","firma",
                                       "_id","_recibido","_origen") | not)
                   | explode | map(select(. >= 32 and . < 127)) | implode | .[0:40]] | join(",")' <<<"$MSG")"
  if [[ -n "$extra" ]]; then rechazar "clave no permitida: $extra"; return 0; fi
  extra="$(jq -r 'if (.args | type) == "object"
                  then [.args | keys[] | select(. != "objetivo")
                        | explode | map(select(. >= 32 and . < 127)) | implode | .[0:40]] | join(",")
                  else "" end' <<<"$MSG")"
  if [[ -n "$extra" ]]; then rechazar "clave no permitida en args: $extra"; return 0; fi

  # 5. Tipos.
  if ! de="$(leer_texto '.de')"; then
    rechazar "'de' ausente, no es texto o contiene caracteres de control"; return 0
  fi
  if (( ${#de} < 1 || ${#de} > 64 )); then rechazar "'de' debe tener entre 1 y 64 caracteres"; return 0; fi
  if ! accion="$(leer_texto '.accion')"; then rechazar "'accion' ausente o no es texto"; return 0; fi
  if ! ts="$(leer_texto '.ts')"; then rechazar "'ts' ausente o no es texto"; return 0; fi
  case "$(jq -r 'if has("args") then (.args | type) else "ausente" end' <<<"$MSG")" in
    object|ausente) ;;
    *) rechazar "'args' debe ser un objeto"; return 0 ;;
  esac
  if [[ "$(jq -r 'has("args") and (.args | has("objetivo"))' <<<"$MSG")" == "true" ]]; then
    if ! objetivo="$(leer_texto '.args.objetivo')"; then
      rechazar "'args.objetivo' debe ser texto sin caracteres de control"; return 0
    fi
    tiene_objetivo=1
  fi

  # 6. Firma HMAC.
  if [[ "$(jq -r 'has("firma")' <<<"$MSG")" == "true" ]]; then
    if ! verificar "$MSG"; then rechazar "firma incorrecta"; return 0; fi
  elif [[ "$EXIGIR_FIRMA" == "1" ]]; then
    rechazar "firma ausente"; return 0
  else
    AVISO="orden SIN FIRMA aceptada (EXIGIR_FIRMA=0)"
  fi

  # 7. Anti-repetición: antigüedad e id ya visto (se marca ANTES de ejecutar).
  if ! validar_ts "$ts"; then rechazar "$MOTIVO"; return 0; fi
  if id_ya_visto "$ID_ORDEN"; then rechazar "id_orden repetido"; return 0; fi
  if ! marcar_visto "$ID_ORDEN"; then rechazar "error interno guardando ids vistos"; return 0; fi

  # 8. Límite de frecuencia por "de" (solo tras verificar la firma).
  if ! registrar_frecuencia "$de"; then rechazar "$MOTIVO"; return 0; fi

  # 9. Lista blanca de acciones y argumentos. El objetivo atacante NUNCA se refleja.
  case "$accion" in
    ping)
      if (( ! tiene_objetivo )); then rechazar "ping necesita args.objetivo"; return 0; fi
      if ! validar_objetivo "$objetivo"; then
        rechazar "objetivo no válido para ping (solo IPv4 o nombre de host)"; return 0
      fi
      ;;
    estado|puertos|ayuda)
      if (( tiene_objetivo )); then rechazar "la acción $accion no admite objetivo"; return 0; fi
      ;;
    *)
      rechazar "acción no permitida (permitidas: ping, estado, puertos, ayuda)"; return 0
      ;;
  esac

  # 10. Ejecutar.
  log "orden $ID_ORDEN: ejecutando $accion"
  ejecutar_accion "$accion" "$objetivo"
  if (( EJ_CODIGO == 0 )); then estado="ok"; else estado="error"; fi
  if [[ "$accion" == "ping" ]]; then modo="texto"; else modo="json"; fi
  motivo_ej="acción ejecutada"
  if (( EJ_CODIGO == 124 )); then motivo_ej="tiempo agotado (${TIMEOUT_ACCION} s)"; fi

  publicada="true"
  if ! responder "$estado" "$EJ_CODIGO" "$F_SALIDA" "$modo"; then
    publicada="false"
    log "no se pudo publicar la respuesta de $ID_ORDEN (no se vuelve a ejecutar)"
  fi
  auditar ejecutada "$motivo_ej" "$estado" "$EJ_CODIGO" "$publicada"
  log "orden $ID_ORDEN: $estado (código $EJ_CODIGO, ${DURACION} ms)"
}

# =============================================================================
# Estado, cursor y bucle principal
# =============================================================================

comprobar_entorno() {
  [[ -n "${TOKEN_G4:-}" ]] || fallar "falta TOKEN_G4 (export TOKEN_G4=...)"
  [[ -n "${CLAVE:-}" ]]    || fallar "falta CLAVE (export CLAVE=...). No hay clave por defecto."
  [[ "$TOKEN_G4" =~ ^[A-Za-z0-9._~-]+$ ]] || fallar "TOKEN_G4 contiene caracteres no válidos para una URL"
  case "$RECEPTOR" in
    profesor) ;;
    webhooksite) fallar "RECEPTOR=webhooksite es solo un esqueleto documentado (ver TODO en el código)" ;;
    *) fallar "RECEPTOR debe ser 'profesor' o 'webhooksite'" ;;
  esac
  case "$EXIGIR_FIRMA" in
    0|1) ;;
    *) fallar "EXIGIR_FIRMA debe ser 0 o 1" ;;
  esac
  [[ "$MAX_MSGS_CICLO" =~ ^[1-9][0-9]{0,3}$ ]]  || fallar "MAX_MSGS_CICLO debe ser un entero entre 1 y 9999"
  [[ "$MAX_BYTES_SYNC" =~ ^[1-9][0-9]{0,9}$ ]]  || fallar "MAX_BYTES_SYNC debe ser un entero positivo"
  [[ "$NOMBRE_BOT" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || fallar "NOMBRE_BOT no válido"
}

preparar_estado() {
  mkdir -p -- "$DIR_ESTADO"
  chmod 700 -- "$DIR_ESTADO"
  exec 9> "$F_BLOQUEO"
  flock -n 9 || fallar "ya hay otro bot.sh en marcha con este DIR_ESTADO"
  ESTADO_LISTO=1
  [[ -f "$F_VISTOS" ]] || : > "$F_VISTOS"
  [[ -f "$F_AUDITORIA" ]] || : > "$F_AUDITORIA"
  if ! jq -e 'type == "array"' "$F_FRECUENCIA" >/dev/null 2>&1; then
    escribir_atomico "$F_FRECUENCIA" '[]' || fallar "no se pudo crear $F_FRECUENCIA"
  fi
  DIR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bot_g4.XXXXXX")"
  F_RESPUESTA="$DIR_TMP/respuesta"; F_CUERPO="$DIR_TMP/cuerpo"; F_SYNC="$DIR_TMP/sync"
  F_LISTA="$DIR_TMP/lista"; F_BRUTO="$DIR_TMP/bruto"; F_SALIDA="$DIR_TMP/salida"
}

guardar_cursor() {
  CURSOR="$1"
  escribir_atomico "$F_CURSOR" "$1" || log "no se pudo guardar el cursor"
}

# Primer arranque: cursor = last_id actual (no se ejecuta el histórico).
# Reinicio: se continúa desde el cursor guardado.
inicializar_cursor() {
  local guardado
  if [[ -f "$F_CURSOR" ]]; then
    guardado="$(head -c 32 "$F_CURSOR" | tr -d '[:space:]')"
    if [[ "$guardado" =~ ^[0-9]{1,15}$ ]]; then
      CURSOR=$(( 10#$guardado ))
      log "reinicio: continúo desde _id $CURSOR"
      return 0
    fi
    log "cursor guardado no válido: se toma el último mensaje actual"
  fi
  until leer_last_id; do
    log "no se pudo leer el last_id del canal; reintento en ${INTERVALO} s"
    esperar "$INTERVALO"
  done
  guardar_cursor "$ULTIMO_ID"
  log "primer arranque: se ignora el histórico (cursor = $CURSOR)"
}

# Un ciclo: leer mensajes nuevos y tratarlos uno a uno (máx. MAX_MSGS_CICLO).
#   Devuelve 0 = ok · 1 = fallo de red/HTTP · 3 = /sync llegó pero no se puede interpretar.
ciclo() {
  local linea id_msg msg
  consultar "$CURSOR" || return $?
  if ! jq -c --argjson cursor "$CURSOR" --argjson max "$MAX_MSGS_CICLO" --argjson tam "$MAX_TAM_MSG" '
        (.last_id // 0) as $ultimo
        | [ .messages[]
            | select(type == "object" and (._id | type) == "number"
                     and ._id == (._id | floor) and ._id > $cursor
                     and ._id <= $ultimo and ._id < 1e15) ]
        | sort_by(._id) | .[0:$max] | .[]
        | {id: (._id | floor), msg: (if (tojson | utf8bytelength) <= $tam then . else null end)}
      ' "$F_SYNC" > "$F_LISTA"; then
    log "no se pudo interpretar la lista de mensajes"
    return 3
  fi
  # fd 3: ningún comando del bucle puede "comerse" la lista leyendo stdin.
  while IFS= read -r linea <&3; do
    id_msg="$(jq -r '.id' <<<"$linea")"
    [[ "$id_msg" =~ ^[0-9]{1,15}$ ]] || { log "_id no entero: ciclo abortado"; return 1; }
    msg="$(jq -c '.msg' <<<"$linea")"
    procesar_mensaje "$id_msg" "$msg"
    guardar_cursor "$id_msg"          # el cursor avanza DESPUÉS de tratar el mensaje
  done 3< "$F_LISTA"
}

# saltar_mensaje ID → avanza el cursor por encima de un mensaje que hace fallar /sync.
#   No se ejecuta ni se responde nada: solo queda en la auditoría y en el log.
saltar_mensaje() {
  local id="$1"
  jq -nc --argjson id "$id" --argjson fallos "$FALLOS_CONTENIDO" \
    '{ts: (now | todate), evento: "salto", _id: $id, fallos_seguidos: $fallos,
      motivo: "mensaje no procesable: /sync falla mientras lo incluye (posible mensaje envenenado)"}' \
    >> "$F_AUDITORIA" || log "no se pudo escribir en la auditoría"
  guardar_cursor "$id"
  log "AVISO: mensaje $id saltado SIN procesar tras $FALLOS_CONTENIDO fallos seguidos de /sync"
}

# tratar_fallo_ciclo RC → decide qué hacer cuando un ciclo falla (riesgo R1).
#   RC = 1 → fallo de red o HTTP (servidor caído, timeout…).
#   RC = 3 → /sync llegó pero no se puede interpretar (posible mensaje envenenado).
#   Política:
#   - Un fallo de red NO cuenta ni pone a cero el contador: no dice nada del contenido,
#     y saltar con el servidor caído perdería órdenes legítimas.
#   - Tras UMBRAL_SALTO fallos de contenido seguidos se comprueba que el servidor está
#     sano pidiendo since=SINCE_MAX (no trae mensajes). Si ESO sí es JSON válido, lo que
#     rompe /sync?since=CURSOR es un mensaje con _id > CURSOR: ese mensaje ya existe, así
#     que saltar CURSOR+1 nunca hace perder una orden futura (llegará con un _id mayor).
#   - Si tampoco eso es válido, el fallo es del servidor, no de un mensaje: no se salta.
tratar_fallo_ciclo() {
  local rc="$1"
  if (( rc != 3 )); then
    log "ciclo con errores de red (código $rc); se reintenta en ${INTERVALO} s"
    return 0
  fi
  FALLOS_CONTENIDO=$(( FALLOS_CONTENIDO + 1 ))
  log "/sync no interpretable ($FALLOS_CONTENIDO/$UMBRAL_SALTO seguidos)"
  (( FALLOS_CONTENIDO >= UMBRAL_SALTO )) || return 0
  if consultar "$SINCE_MAX"; then
    saltar_mensaje "$(( CURSOR + 1 ))"
    FALLOS_CONTENIDO=0
  else
    log "el servidor tampoco responde bien sin mensajes: el fallo no viene de un mensaje, no se salta"
  fi
}

anunciar_arranque() {
  log "bot $NOMBRE_BOT arrancado · receptor=$RECEPTOR · sync=$URL_SYNC · estado=$DIR_ESTADO"
  if [[ "$EXIGIR_FIRMA" == "0" ]]; then
    printf '\n%s\n%s\n%s\n\n' \
      '############################################################' \
      '###  AVISO: EXIGIR_FIRMA=0 → se aceptan órdenes SIN FIRMA ###' \
      '############################################################' >&2
  fi
  jq -nc --argjson ef "$EXIGIR_FIRMA" --arg bot "$NOMBRE_BOT" \
    '{ts: (now | todate), evento: "arranque", bot: $bot, exigir_firma: $ef}
     + (if $ef == 0 then {aviso: "se aceptan órdenes sin firma"} else {} end)' \
    >> "$F_AUDITORIA"
}

# shellcheck disable=SC2317,SC2329  # se invoca desde el trap EXIT
limpiar() {
  local codigo=$?
  trap - EXIT INT TERM
  if [[ -n "$PID_HIJO" ]]; then
    kill -TERM "$PID_HIJO" 2>/dev/null || true
    wait "$PID_HIJO" 2>/dev/null || true
  fi
  if [[ -n "$DIR_TMP" && -d "$DIR_TMP" ]]; then rm -rf -- "$DIR_TMP"; fi
  if (( ESTADO_LISTO )); then
    rm -f -- "$DIR_ESTADO"/.tmp.*
    flock -u 9 2>/dev/null || true
  fi
  log "bot detenido (código $codigo)"
  exit "$codigo"
}

main() {
  if [[ "${1:-}" == "--trabajador" ]]; then
    trabajador "${2:-}"
    exit 0
  fi
  case "${1:-}" in
    "") ;;
    -h|--ayuda) mostrar_uso; exit 0 ;;
    *) mostrar_uso >&2; exit 2 ;;
  esac

  comprobar_dependencias jq curl openssl timeout ping ss flock awk free df uptime \
                         head tail grep mktemp date readlink sed tr
  comprobar_entorno
  trap limpiar EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  preparar_estado
  anunciar_arranque
  inicializar_cursor
  log "escuchando órdenes cada ${INTERVALO} s (Ctrl+C para salir)"
  while true; do
    if ciclo; then
      FALLOS_CONTENIDO=0
    else
      tratar_fallo_ciclo "$?"
    fi
    esperar "$INTERVALO"
  done
}

main "$@"
