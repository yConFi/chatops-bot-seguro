#!/usr/bin/env bash
# =============================================================================
# pruebas.sh — Pruebas reproducibles del bot ChatOps contra el SERVIDOR FALSO
#
# Autores : Pol, Fran, Javi, Yeray, Ricardo — Grupo 4
#           Máster de Ciberseguridad & IA (Evolve)
#
# Descripción:
#   Arranca servidor_falso.py en 127.0.0.1 y bot.sh con un estado temporal,
#   lanza los casos de la tabla del README y comprueba cada resultado esperado.
#   NUNCA usa el servidor real: fuerza URL_WEBHOOK/URL_SYNC a 127.0.0.1.
#   Los ataques se escriben entre comillas SIMPLES para que no los ejecute la
#   propia shell de quien lanza la prueba.
#   El resultado se guarda en resultados_pruebas.md (resultado REAL de esta ejecución).
#
# Uso:
#   ./pruebas.sh                  # tarda unos 4-5 minutos
#   PUERTO=8099 ./pruebas.sh      # puerto del servidor falso
#
# Requisitos: bash, jq, curl, openssl, python3, ss, flock, pgrep, sha256sum.
#   "ping 8.8.8.8" necesita Internet; el resto funciona sin red exterior.
# =============================================================================
set -euo pipefail
export LC_ALL=C

DIR_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
readonly DIR_SCRIPT
readonly PUERTO="${PUERTO:-8099}"
readonly NOMBRE_BOT="kali-g4"

DIR_PRUEBAS=""
PID_SERVIDOR=""; PID_BOT=""; PID_PUERTOS=""
F_LOG_BOT=""; F_OUT=""; F_ERR=""; F_TABLA=""; F_AUD=""
ARRANQUES=0
PASA=0; FALLA=0
ORDEN_ID=""; ORDEN_ESTADO=""
TESTIGO=""; PWNED=""

# =============================================================================
# Utilidades
# =============================================================================

titulo() { printf '\n== %s\n' "$*"; }

comprobar_dependencias() {
  local falta=() cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || falta+=("$cmd")
  done
  if (( ${#falta[@]} > 0 )); then
    printf 'ERROR: faltan dependencias: %s\n' "${falta[*]}" >&2
    printf 'En Kali: sudo apt install jq curl openssl python3 iproute2 util-linux procps coreutils\n' >&2
    exit 1
  fi
}

# resultado CASO ESPERADO OBTENIDO → cuenta, imprime y añade una fila a la tabla.
#   (Ojo: ((PASA++)) devuelve 1 cuando PASA vale 0 y set -e pararía el script.)
resultado() {
  local caso="$1" esperado="$2" obtenido="$3" marca
  if [[ "$esperado" == "$obtenido" ]]; then
    PASA=$(( PASA + 1 )); marca="PASA"
  else
    FALLA=$(( FALLA + 1 )); marca="FALLA"
  fi
  printf '  [%-5s] %-50s esperado=%s obtenido=%s\n' "$marca" "$caso" "$esperado" "$obtenido"
  printf '| %s | %s | %s | %s |\n' "${caso//|/\\|}" "$esperado" "$obtenido" "$marca" >> "$F_TABLA"
}

ahora_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
nuevo_id() { openssl rand -hex 4; }

# --- HMAC: copia exacta de las funciones del bot (para fabricar órdenes) -----
hmac_hex() { openssl dgst -sha256 -hmac "$CLAVE" | awk '{print $NF}'; }
canonico() { jq -cS 'del(.firma, ._id, ._recibido, ._origen)' <<<"$1"; }
firmar() {
  local canon firma
  canon="$(canonico "$1")"
  firma="$(printf '%s' "$canon" | hmac_hex)"
  jq -c --arg firma "$firma" '. + {firma: $firma}' <<<"$1"
}

# orden_json ID DE ACCION → orden mínima válida (sin firma) para modificar con jq.
orden_json() {
  jq -nc --arg id "$1" --arg de "$2" --arg accion "$3" --arg ts "$(ahora_iso)" \
    '{id_orden: $id, de: $de, accion: $accion, args: {}, ts: $ts, canal: "ordenes-g4"}'
}

# publicar_crudo JSON → POST directo al servidor falso (sin pasar por orden.sh).
publicar_crudo() {
  curl -s -o /dev/null --max-time 5 -H 'Content-Type: application/json' \
    --data-binary @- "$URL_WEBHOOK/$TOKEN_G4" <<<"$1" || true
}

# respuestas_de ID [SINCE] → array JSON con las respuestas del bot para ese id_orden.
#   SINCE permite leer solo lo posterior a un mensaje envenenado.
respuestas_de() {
  local s r url="$URL_SYNC"
  if [[ -n "${2:-}" ]]; then url="$URL_SYNC?since=$2"; fi
  s="$(curl -s --max-time 5 "$url" || true)"
  r="$(jq -c --arg id "$1" --arg bot "$NOMBRE_BOT" \
        '[.messages[] | select(.canal == "respuestas-g4" and .id_orden == $id and .bot == $bot)]' \
        <<<"$s" 2>/dev/null || true)"
  printf '%s' "${r:-[]}"
}

# esperar_respuestas ID N [SEGUNDOS] [SINCE] → espera (15 s por defecto) a que haya
#   N respuestas; imprime el array.
esperar_respuestas() {
  local r _ intentos=$(( ${3:-15} * 2 ))
  for _ in $(seq 1 "$intentos"); do
    r="$(respuestas_de "$1" "${4:-}")"
    if (( $(jq 'length' <<<"$r") >= $2 )); then break; fi
    sleep 0.5
  done
  printf '%s' "$r"
}

# enviar_y_estado JSON ID → publica y devuelve el estado de la respuesta (o sin_respuesta).
enviar_y_estado() {
  publicar_crudo "$1"
  esperar_respuestas "$2" 1 | jq -r 'last.estado // "sin_respuesta"'
}

# orden DE ARGS… → ejecuta orden.sh; deja ORDEN_ID y ORDEN_ESTADO.
#   El código de salida no se usa aquí: el estado se lee de la propia respuesta.
orden() {
  local de="$1"; shift
  bash "$DIR_SCRIPT/orden.sh" --de "$de" "$@" > "$F_OUT" 2> "$F_ERR" || true
  ORDEN_ID="$(grep -oE 'id_orden=[0-9a-f]{8}' "$F_ERR" | head -n 1 | cut -d= -f2 || true)"
  ORDEN_ESTADO="$(sed -n 's/^estado *: //p' "$F_OUT" | head -n 1)"
  [[ -n "$ORDEN_ESTADO" ]] || ORDEN_ESTADO="sin_respuesta"
}

# aud_contar FILTRO_JQ → líneas de auditoría que cumplen el filtro (constante del script).
aud_contar() {
  jq -s "[.[] | select($1)] | length" "$F_AUD"
}

bot_vivo() { [[ -n "$PID_BOT" ]] && kill -0 "$PID_BOT" 2>/dev/null; }

# =============================================================================
# Arranque y parada de procesos
# =============================================================================

arrancar_servidor() {
  python3 "$DIR_SCRIPT/servidor_falso.py" --puerto "$PUERTO" > "$DIR_PRUEBAS/servidor.log" 2>&1 &
  PID_SERVIDOR=$!
  local _
  for _ in $(seq 1 50); do
    if curl -s -o /dev/null --max-time 1 "$URL_SYNC"; then return 0; fi
    sleep 0.2
  done
  echo "ERROR: el servidor falso no arrancó (ver $DIR_PRUEBAS/servidor.log)" >&2
  exit 1
}

# arrancar_bot EXIGIR_FIRMA [DIR_PATH_EXTRA]
#   env --default-signal=INT: en una shell no interactiva los procesos en segundo
#   plano heredan SIGINT ignorado; así el bot puede recibir un "Ctrl+C" real.
#   DIR_PATH_EXTRA se pone DELANTE del PATH del bot (para comandos falsos de prueba).
arrancar_bot() {
  local exigir="$1" ruta="$PATH" lanzador=() _
  if [[ -n "${2:-}" ]]; then ruta="$2:$PATH"; fi
  ARRANQUES=$(( ARRANQUES + 1 ))
  F_LOG_BOT="$DIR_PRUEBAS/bot_${ARRANQUES}.log"
  if env --default-signal=INT true 2>/dev/null; then lanzador=(env --default-signal=INT); fi
  PATH="$ruta" EXIGIR_FIRMA="$exigir" "${lanzador[@]}" bash "$DIR_SCRIPT/bot.sh" > "$F_LOG_BOT" 2>&1 &
  PID_BOT=$!
  for _ in $(seq 1 75); do
    if grep -q 'escuchando órdenes' "$F_LOG_BOT"; then return 0; fi
    bot_vivo || break
    sleep 0.2
  done
  echo "ERROR: el bot no arrancó (ver $F_LOG_BOT)" >&2
  exit 1
}

# parar_bot SEÑAL → 0 si el bot termina en menos de 5 s.
parar_bot() {
  local senal="$1" _
  bot_vivo || return 0
  kill -"$senal" "$PID_BOT" 2>/dev/null || true
  for _ in $(seq 1 50); do
    bot_vivo || break
    sleep 0.1
  done
  if bot_vivo; then return 1; fi
  wait "$PID_BOT" 2>/dev/null || true
  PID_BOT=""
}

# shellcheck disable=SC2317,SC2329  # se invoca desde el trap EXIT
limpiar() {
  local codigo=$?
  trap - EXIT INT TERM
  for pid in "$PID_BOT" "$PID_PUERTOS" "$PID_SERVIDOR"; do
    if [[ -n "$pid" ]]; then kill -TERM "$pid" 2>/dev/null || true; fi
  done
  wait 2>/dev/null || true
  if [[ -n "$DIR_PRUEBAS" ]]; then printf '\nLogs y estado de esta ejecución: %s\n' "$DIR_PRUEBAS"; fi
  exit "$codigo"
}

# =============================================================================
# Casos
# =============================================================================

casos_legitimos() {
  local a json
  titulo "Órdenes legítimas"
  orden c-ping8 ping 8.8.8.8
  resultado "ping 8.8.8.8 (necesita Internet)" ok "$ORDEN_ESTADO"
  orden c-pingloc ping localhost
  resultado "ping localhost" ok "$ORDEN_ESTADO"
  for a in estado puertos ayuda; do
    orden "c-$a" "$a"
    json="no"
    if respuestas_de "$ORDEN_ID" | jq -e 'last.salida | fromjson' >/dev/null 2>&1; then json="json"; fi
    resultado "$a (JSON válido en salida)" "ok+json" "$ORDEN_ESTADO+$json"
  done
}

casos_invalidos() {
  local id j
  titulo "Acciones y argumentos no válidos"
  orden c-borrar borrar
  resultado "acción 'borrar'" rechazada "$ORDEN_ESTADO"

  id="$(nuevo_id)"; j="$(firmar "$(orden_json "$id" c-num ayuda | jq -c '.accion = 5')")"
  resultado "accion numérica (firmada)" rechazada "$(enviar_y_estado "$j" "$id")"

  id="$(nuevo_id)"; j="$(firmar "$(orden_json "$id" c-args ping | jq -c '.args = "8.8.8.8"')")"
  resultado "args de tipo cadena (firmada)" rechazada "$(enviar_y_estado "$j" "$id")"

  id="$(nuevo_id)"; j="$(firmar "$(orden_json "$id" c-extra ayuda | jq -c '.extra = 1')")"
  resultado "clave extra (firmada)" rechazada "$(enviar_y_estado "$j" "$id")"
}

casos_inyeccion() {
  local hash_antes hash_despues a i=0 estado_testigo estado_pwned
  titulo "Inyección (comillas simples) + fichero testigo"
  printf 'intacto\n' > "$TESTIGO"
  hash_antes="$(sha256sum "$TESTIGO" | cut -d' ' -f1)"
  # shellcheck disable=SC2016  # los $( ) y ` ` son literales a propósito: son el ataque
  local ataques=(
    '8.8.8.8; id'
    '$(whoami)'
    '-f'
    '-c 100000'
    '999.999.999.999'
    '8.8.8.8 8.8.4.4'
    $'8.8.8.8\nid'
    $'\e[31m8.8.8.8'
    '8.8.8.8; echo pwned > '"$TESTIGO"
    '$(touch '"$PWNED"')'
    '`touch '"$PWNED"'`'
    '8.8.8.8 && touch '"$PWNED"
    '8.8.8.8 | touch '"$PWNED"
  )
  for a in "${ataques[@]}"; do
    i=$(( i + 1 ))
    orden "c-ataque$i" ping "$a"
    resultado "ping $(printf '%q' "$a")" rechazada "$ORDEN_ESTADO"
  done
  hash_despues="$(sha256sum "$TESTIGO" | cut -d' ' -f1)"
  estado_testigo="modificado"; [[ "$hash_antes" == "$hash_despues" ]] && estado_testigo="intacto"
  estado_pwned="existe";       [[ -e "$PWNED" ]] || estado_pwned="no_existe"
  resultado "fichero testigo tras los ataques" intacto "$estado_testigo"
  resultado "fichero pwned tras los ataques" no_existe "$estado_pwned"
}

casos_mal_formados() {
  local antes despues id j vivo
  titulo "JSON mal formado, mensaje > 4 KB e id_orden no válido"
  curl -s -o /dev/null --max-time 5 -X POST "http://127.0.0.1:$PUERTO/_pruebas/romper_sync/$TOKEN_G4" || true
  sleep 5
  vivo="muerto"; bot_vivo && grep -q 'JSON inválido' "$F_LOG_BOT" && vivo="ignorado+vivo"
  resultado "/sync con JSON mal formado" "ignorado+vivo" "$vivo"

  antes="$(aud_contar '(.motivo // "") | startswith("mensaje mayor")')"
  id="$(nuevo_id)"; j="$(orden_json "$id" c-grande ayuda | jq -c '.relleno = ("x" * 5000)')"
  publicar_crudo "$j"; sleep 6
  despues="$(aud_contar '(.motivo // "") | startswith("mensaje mayor")')"
  resultado "mensaje > 4 KB (respuestas, auditoría +1)" "0,+1" \
            "$(respuestas_de "$id" | jq 'length'),+$(( despues - antes ))"

  antes="$(aud_contar '(.motivo // "") | startswith("id_orden ausente")')"
  j="$(orden_json "../../etc" c-idmalo ayuda)"
  publicar_crudo "$j"; sleep 6
  despues="$(aud_contar '(.motivo // "") | startswith("id_orden ausente")')"
  resultado "id_orden no válido (sin respuesta, auditado)" "0,+1" \
            "$(respuestas_de "../../etc" | jq 'length'),+$(( despues - antes ))"
}

casos_firma() {
  local id j
  titulo "Firma HMAC (EXIGIR_FIRMA=1)"
  orden c-sinfirma --sin-firma ayuda
  resultado "--sin-firma" rechazada "$ORDEN_ESTADO"
  orden c-firmafalsa --firma-falsa ayuda
  resultado "--firma-falsa" rechazada "$ORDEN_ESTADO"
  id="$(nuevo_id)"
  j="$(firmar "$(orden_json "$id" c-alterada ping | jq -c '.args.objetivo = "localhost"')")"
  j="$(jq -c '.args.objetivo = "127.0.0.1"' <<<"$j")"      # alterada DESPUÉS de firmar
  resultado "orden alterada tras firmar" rechazada "$(enviar_y_estado "$j" "$id")"
}

casos_repeticion() {
  local id j estados _
  titulo "Anti-repetición y límite de frecuencia"
  id="$(nuevo_id)"; j="$(firmar "$(orden_json "$id" c-repe ayuda)")"
  publicar_crudo "$j"; publicar_crudo "$j"
  estados="$(esperar_respuestas "$id" 2 | jq -r 'map(.estado) | join(",")')"
  resultado "misma orden enviada dos veces" "ok,rechazada" "$estados"

  orden c-tsviejo --ts-viejo ayuda
  resultado "--ts-viejo" rechazada "$ORDEN_ESTADO"

  estados=""
  for _ in 1 2 3 4 5 6; do
    orden c-rafaga ayuda
    estados+="${estados:+,}$ORDEN_ESTADO"
  done
  resultado "6 órdenes en un minuto (mismo 'de')" "ok,ok,ok,ok,ok,rechazada" "$estados"
}

casos_ignorados() {
  local id j
  titulo "Mensajes que no son órdenes"
  id="$(nuevo_id)"; j="$(firmar "$(orden_json "$id" c-prueba ayuda | jq -c '.canal = "prueba"')")"
  publicar_crudo "$j"; sleep 6
  resultado "canal 'prueba' (respuestas, auditoría)" "0,0" \
            "$(respuestas_de "$id" | jq 'length'),$(jq -s --arg id "$id" '[.[] | select(.id_orden == $id)] | length' "$F_AUD")"

  id="$(nuevo_id)"; j="$(orden_json "$id" c-resp ayuda | jq -c '.canal = "respuestas-g4"')"
  publicar_crudo "$j"; sleep 6
  resultado "canal 'respuestas-g4' (respuestas del bot)" "0" "$(respuestas_de "$id" | jq 'length')"
}

caso_salida_larga() {
  local r largo
  titulo "Salida > 2000 caracteres"
  # 80 puertos en escucha en 127.0.0.1 → el JSON de 'puertos' supera los 2000 caracteres.
  python3 -c '
import socket, time
s = []
for _ in range(80):
    x = socket.socket(); x.bind(("127.0.0.1", 0)); x.listen(); s.append(x)
time.sleep(60)' &
  PID_PUERTOS=$!
  sleep 1
  largo="$(ss -tuln | awk 'NR > 1' | wc -l)"
  orden c-largo puertos
  r="$(respuestas_de "$ORDEN_ID" | jq -r 'last | if (.salida | length) <= 2000
          and ((.salida | fromjson | type) == "array") then "recortada+json" else "mal" end' 2>/dev/null || echo mal)"
  resultado "puertos con $largo líneas en ss" "recortada+json" "$r"
  kill "$PID_PUERTOS" 2>/dev/null || true
  wait "$PID_PUERTOS" 2>/dev/null || true
  PID_PUERTOS=""
}

casos_reinicio() {
  local pid_o id rc aviso falsa_ok repetidas _
  titulo "Bot parado: respuesta falsa · reinicio · EXIGIR_FIRMA=0"
  parar_bot TERM || true

  # Con el bot parado, solo puede llegar una respuesta falsa.
  bash "$DIR_SCRIPT/orden.sh" --de c-falsa ayuda > "$F_OUT" 2> "$F_ERR" &
  pid_o=$!
  id=""
  for _ in $(seq 1 50); do
    id="$(grep -oE 'id_orden=[0-9a-f]{8}' "$F_ERR" | head -n 1 | cut -d= -f2 || true)"
    [[ -n "$id" ]] && break
    sleep 0.1
  done
  publicar_crudo "$(jq -nc --arg id "$id" --arg ts "$(ahora_iso)" \
    '{id_orden: $id, bot: "kali-g4", estado: "ok", codigo_salida: 0, salida: "FALSA",
      duracion_ms: 1, ts: $ts, canal: "respuestas-g4"}')"
  publicar_crudo "$(jq -nc --arg id "$id" --arg ts "$(ahora_iso)" --arg f "$(openssl rand -hex 32)" \
    '{id_orden: $id, bot: "kali-g4", estado: "ok", codigo_salida: 0, salida: "FALSA",
      duracion_ms: 1, ts: $ts, canal: "respuestas-g4", firma: $f}')"
  rc=0; wait "$pid_o" || rc=$?
  falsa_ok="aceptada"
  if (( rc == 3 )) && grep -q 'firma NO válida' "$F_ERR"; then falsa_ok="no_aceptada"; fi
  resultado "respuesta falsa con nuestro id" "no_aceptada" "$falsa_ok"

  arrancar_bot 0
  resultado "reinicio: continúa desde el cursor" "si" \
            "$(grep -q 'reinicio: continúo desde' "$F_LOG_BOT" && echo si || echo no)"

  orden c-sinfirma0 --sin-firma ayuda
  aviso="$(jq -s --arg id "$ORDEN_ID" '[.[] | select(.id_orden == $id and has("aviso"))] | length' "$F_AUD")"
  resultado "sin firma con EXIGIR_FIRMA=0 (+aviso)" "ok+1" "$ORDEN_ESTADO+$aviso"

  orden c-falsa0 --firma-falsa ayuda
  resultado "firma falsa con EXIGIR_FIRMA=0" rechazada "$ORDEN_ESTADO"

  repetidas="$(jq -s '[.[] | select(.decision == "ejecutada") | .id_orden]
                      | group_by(.) | map(select(length > 1)) | length' "$F_AUD")"
  resultado "ninguna orden ejecutada dos veces" "0" "$repetidas"
}

caso_token_incorrecto() {
  local rc=0
  titulo "Token incorrecto (403)"
  TOKEN_G4="token-incorrecto" bash "$DIR_SCRIPT/orden.sh" --de c-403 ayuda > "$F_OUT" 2> "$F_ERR" || rc=$?
  resultado "token incorrecto (rc, mensaje 403)" "2+403" \
            "$rc+$(grep -q '403' "$F_ERR" && echo 403 || echo otro)"
}

caso_ctrl_c() {
  local pid_o limpio senal="INT" _
  titulo "Ctrl+C durante una acción"
  env --default-signal=INT true 2>/dev/null || senal="TERM"
  bash "$DIR_SCRIPT/orden.sh" --de c-ctrlc ping localhost > /dev/null 2>&1 &
  pid_o=$!
  sleep 3                                  # el bot ya está ejecutando el ping (≈3 s)
  limpio="si"
  parar_bot "$senal" || limpio="no(sigue_vivo)"
  sleep 0.5
  if pgrep -f -- '--trabajador' >/dev/null || pgrep -x ping >/dev/null || pgrep -x timeout >/dev/null; then
    limpio="no(huerfanos)"
  fi
  if ! flock -n "$DIR_ESTADO/bot.lock" true; then limpio="no(bloqueo)"; fi
  if compgen -G "$DIR_ESTADO/.tmp.*" >/dev/null; then limpio="no(temporales)"; fi
  resultado "SIG$senal: cierre limpio sin huérfanos" "si" "$limpio"
  kill "$pid_o" 2>/dev/null || true
  wait "$pid_o" 2>/dev/null || true
}

# --- Antiguas "revisiones manuales" de revision.md (filas 9, 14, 21, 24, 33 y 36) ---

# Fila 24: sin CLAVE, ni el bot ni el cliente arrancan (no hay clave por defecto).
#   timeout 10: si por un fallo el bot SÍ arrancara, la prueba no se queda colgada.
caso_sin_clave() {
  local rc_bot=0 rc_orden=0 msg
  titulo "Sin CLAVE (fila 24)"
  env -u CLAVE timeout 10 bash "$DIR_SCRIPT/bot.sh" > "$F_OUT" 2> "$F_ERR" || rc_bot=$?
  msg="otro"; grep -q 'falta CLAVE' "$F_ERR" && msg="falta_clave"
  resultado "bot.sh sin CLAVE (rc, mensaje)" "1+falta_clave" "$rc_bot+$msg"
  env -u CLAVE timeout 10 bash "$DIR_SCRIPT/orden.sh" ayuda > "$F_OUT" 2> "$F_ERR" || rc_orden=$?
  msg="otro"; grep -q 'falta CLAVE' "$F_ERR" && msg="falta_clave"
  resultado "orden.sh sin CLAVE (rc, mensaje)" "2+falta_clave" "$rc_orden+$msg"
}

# Filas 9 y 21: un ping FALSO que se cuelga (delante en el PATH del bot) fuerza el
#   timeout de 10 s. La respuesta debe ser error/124 y duracion_ms debe medir el tiempo real.
caso_timeout() {
  local dir_falso="$DIR_PRUEBAS/bin_lento" id j r
  titulo "Timeout de 10 s y duracion_ms (filas 9 y 21)"
  mkdir -p "$dir_falso"
  printf '%s\n' '#!/usr/bin/env bash' \
    '# ping FALSO (solo pruebas): se cuelga para forzar el timeout del bot' \
    'exec sleep 30' > "$dir_falso/ping"
  chmod +x "$dir_falso/ping"
  arrancar_bot 1 "$dir_falso"
  id="$(nuevo_id)"
  j="$(firmar "$(orden_json "$id" c-timeout ping | jq -c '.args = {objetivo: "localhost"}')")"
  publicar_crudo "$j"
  r="$(esperar_respuestas "$id" 1 30)"
  resultado "ping colgado → timeout" "error+124" \
            "$(jq -r 'last | "\(.estado)+\(.codigo_salida)"' <<<"$r" 2>/dev/null || echo sin_respuesta)"
  resultado "duracion_ms real (entre 10 y 15 s)" "si" \
            "$(jq -r 'last | if (.duracion_ms // 0) >= 10000 and (.duracion_ms // 0) < 15000
                             then "si" else "no(\(.duracion_ms))" end' <<<"$r" 2>/dev/null || echo no)"
  parar_bot TERM || true
}

# Fila 33: si falla la publicación de la respuesta, se audita publicada=false, la acción
#   NO se repite y el bot sigue atendiendo órdenes.
caso_fallo_publicacion() {
  local id j auditado
  titulo "Fallo al publicar la respuesta (fila 33)"
  arrancar_bot 1
  curl -s -o /dev/null --max-time 5 -X POST "http://127.0.0.1:$PUERTO/_pruebas/fallar_respuesta/$TOKEN_G4" || true
  id="$(nuevo_id)"; j="$(firmar "$(orden_json "$id" c-nopub ayuda)")"
  publicar_crudo "$j"; sleep 8
  auditado="$(jq -rs --arg id "$id" '[.[] | select(.id_orden == $id)]
              | "\(length)+\(.[0].decision)+\(.[0].publicada)"' "$F_AUD")"
  resultado "auditoría (líneas, decisión, publicada) y respuestas" "1+ejecutada+false;0" \
            "$auditado;$(respuestas_de "$id" | jq 'length')"
  orden c-trasnopub ayuda
  resultado "orden siguiente tras el fallo" ok "$ORDEN_ESTADO"
  parar_bot TERM || true
}

# Fila 36: orden.sh nunca envía caracteres de control al terminal. Con el bot parado se
#   publica una respuesta VÁLIDA (firmada) cuya salida lleva ESC y BEL.
caso_salida_con_escapes() {
  local pid_o id="" _ limpio
  titulo "Salida con caracteres de control en orden.sh (fila 36)"
  bash "$DIR_SCRIPT/orden.sh" --de c-escapes ayuda > "$F_OUT" 2> "$F_ERR" &
  pid_o=$!
  for _ in $(seq 1 50); do
    id="$(grep -oE 'id_orden=[0-9a-f]{8}' "$F_ERR" | head -n 1 | cut -d= -f2 || true)"
    [[ -n "$id" ]] && break
    sleep 0.1
  done
  publicar_crudo "$(firmar "$(jq -nc --arg id "$id" --arg ts "$(ahora_iso)" \
    --arg s $'\e[31mROJO\e]0;titulo-cambiado\a' \
    '{id_orden: $id, bot: "kali-g4", estado: "ok", codigo_salida: 0, salida: $s,
      duracion_ms: 1, ts: $ts, canal: "respuestas-g4"}')")"
  wait "$pid_o" || true
  limpio="sin_respuesta"
  if grep -q 'ROJO' "$F_OUT"; then
    limpio="limpia"
    if tr -d '\n' < "$F_OUT" | grep -q '[[:cntrl:]]'; then limpio="con_controles"; fi
  fi
  resultado "salida con ESC y BEL mostrada sin controles" "limpia" "$limpio"
}

# Fila 14: ningún log, estado, auditoría ni la tabla de resultados contiene los secretos.
#   Va al final, cuando ya existen todos los ficheros de esta ejecución.
caso_secretos() {
  local fugas
  titulo "Secretos fuera de logs, estado y auditoría (fila 14)"
  # grep devuelve 1 cuando NO encuentra nada (el caso bueno): con pipefail y set -e eso
  # cortaría el script, así que se neutraliza solo ese código de salida.
  fugas="$( { grep -rlF -e "$CLAVE" -e "$TOKEN_G4" "$DIR_PRUEBAS" "$F_TABLA" 2>/dev/null || true; } | wc -l)"
  resultado "ficheros que contienen CLAVE o TOKEN_G4" "0" "$fugas"
}

# Riesgo R1: un mensaje que hace fallar /sync no debe dejar el bot parado para siempre.
#   Va al final porque, mientras el veneno siga en el histórico, todo /sync completo
#   falla (respuestas_de sin SINCE y el paso 1 de orden.sh): la orden legítima se
#   publica directamente y su respuesta se busca solo después del veneno.
caso_mensaje_envenenado() {
  local id_veneno saltos=0 vivo id j _
  titulo "Mensaje envenenado en /sync (R1)"
  arrancar_bot 1
  sleep 5                                  # que el bot trate lo pendiente: el veneno será cursor+1
  id_veneno="$(curl -s --max-time 5 -X POST "http://127.0.0.1:$PUERTO/_pruebas/envenenar/$TOKEN_G4" \
               | jq -r '._id // empty' 2>/dev/null || true)"
  for _ in $(seq 1 40); do                 # hasta 20 s: UMBRAL_SALTO ciclos de 2 s + margen
    saltos="$(aud_contar ".evento == \"salto\" and ._id == ${id_veneno:-0}")"
    (( saltos >= 1 )) && break
    sleep 0.5
  done
  resultado "el bot salta el mensaje envenenado (auditado)" "1" "$saltos"
  id="$(nuevo_id)"; j="$(firmar "$(orden_json "$id" c-veneno ayuda)")"
  publicar_crudo "$j"
  resultado "orden legítima tras el veneno" ok \
            "$(esperar_respuestas "$id" 1 15 "${id_veneno:-0}" | jq -r 'last.estado // "sin_respuesta"')"
  vivo="no"; bot_vivo && vivo="si"
  resultado "el bot sigue vivo tras el veneno" "si" "$vivo"
  parar_bot TERM || true
}

caso_servidor_caido() {
  local rc=0 vivo
  titulo "Servidor caído"
  arrancar_bot 1
  kill -TERM "$PID_SERVIDOR" 2>/dev/null || true
  wait "$PID_SERVIDOR" 2>/dev/null || true
  PID_SERVIDOR=""
  bash "$DIR_SCRIPT/orden.sh" --de c-caido ayuda > "$F_OUT" 2> "$F_ERR" || rc=$?
  resultado "orden.sh con servidor caído (rc)" "4" "$rc"
  sleep 5
  vivo="no"; bot_vivo && vivo="si"
  resultado "el bot sigue vivo con el servidor caído" "si" "$vivo"
  parar_bot TERM || true
}

# =============================================================================
# Principal
# =============================================================================

main() {
  comprobar_dependencias bash jq curl openssl python3 ss flock pgrep sha256sum awk sed grep \
                         env timeout
  DIR_PRUEBAS="$(mktemp -d "${TMPDIR:-/tmp}/pruebas_g4.XXXXXX")"
  trap limpiar EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Entorno SOLO de pruebas: nunca el servidor real ni secretos reales.
  TOKEN_G4="pruebas-$(openssl rand -hex 8)"
  CLAVE="$(openssl rand -hex 32)"
  export TOKEN_G4 CLAVE
  export RECEPTOR="profesor"
  export URL_WEBHOOK="http://127.0.0.1:$PUERTO/webhook"
  export URL_SYNC="http://127.0.0.1:$PUERTO/sync"
  export DIR_ESTADO="$DIR_PRUEBAS/estado"
  export NOMBRE_BOT
  F_AUD="$DIR_ESTADO/auditoria.jsonl"
  F_OUT="$DIR_PRUEBAS/orden.out"; F_ERR="$DIR_PRUEBAS/orden.err"
  TESTIGO="$DIR_PRUEBAS/testigo.txt"; PWNED="$DIR_PRUEBAS/pwned"
  F_TABLA="$DIR_SCRIPT/resultados_pruebas.md"
  {
    printf '# Resultados de pruebas.sh (servidor FALSO)\n\n'
    printf 'Fecha: %s · Máquina: %s\n\n' "$(ahora_iso)" "$(uname -srm)"
    printf '| Caso | Esperado | Obtenido | Resultado |\n|---|---|---|---|\n'
  } > "$F_TABLA"

  arrancar_servidor
  arrancar_bot 1

  casos_legitimos
  casos_invalidos
  casos_inyeccion
  casos_mal_formados
  casos_firma
  casos_repeticion
  casos_ignorados
  caso_salida_larga
  casos_reinicio
  caso_token_incorrecto
  caso_ctrl_c
  caso_sin_clave
  caso_timeout
  caso_fallo_publicacion
  caso_salida_con_escapes
  caso_mensaje_envenenado
  caso_servidor_caido
  caso_secretos

  printf '\nTotal: %d PASA · %d FALLA\n' "$PASA" "$FALLA" | tee -a "$F_TABLA"
  printf 'Tabla guardada en %s\n' "$F_TABLA"
  (( FALLA == 0 ))
}

main "$@"
