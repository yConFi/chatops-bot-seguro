# Checklist de requisitos y revisión de seguridad — Ejercicio 5 (Grupo 4)

**Autores:** Pol, Fran, Javi, Yeray, Ricardo — Máster de Ciberseguridad & IA (Evolve)

> **Estado de verificación** (detalle en `prompts.md` §5):
> - Kali, 2026-11-23: `bash -n` OK, **`shellcheck` sin avisos** y `pruebas.sh` 45 PASA ·
>   0 FALLA contra el servidor FALSO.
> - Kali, 2026-11-24, tras mitigar R1 y automatizar las revisiones manuales (filas 9, 14,
>   21, 24, 33 y 36): **`pruebas.sh`: 56 PASA · 0 FALLA contra el servidor FALSO**.
>   **Todas las filas de la columna "Prueba" tienen ya una prueba automática que pasa.**
> - Contra el **servidor real** (2026-11-23): `ping 8.8.8.8` → ok; `'8.8.8.8; id'`,
>   `'$(whoami)'` y `--firma-falsa` → rechazada; auditoría y Ctrl+C correctos.
> - Kali, 2026-11-24: `shellcheck` sin avisos. Contra el real,
>   `/sync?since=999999999999999` devolvió `last_id: 999999999999999`. Eso invalidaba la
>   forma de leer `last_id` de la mitigación de R1, que se corrigió (`prompts.md` §4.1).
> - Kali, 2026-11-24, **versión final** (con esa corrección): `shellcheck` sin avisos,
>   **`pruebas.sh`: 56 PASA · 0 FALLA** y, contra el **servidor real**, primer arranque
>   con `cursor = 21` (el `last_id` real), `ping 8.8.8.8` → ok (3139 ms) y
>   `'8.8.8.8; id'` → rechazada (95 ms).

## 1. Checklist: requisito → implementación → prueba

### Enunciado (fase 1)

| # | Requisito | Implementación | Prueba (`pruebas.sh`) |
|---|---|---|---|
| 1 | `bot.sh` consulta cada 2 s | `INTERVALO=2`, bucle de `main` y `esperar()` en `bot.sh` | todas las órdenes reciben respuesta |
| 2 | Cada orden nueva se procesa **una sola vez** | cursor `_id` en `ciclo()` y `guardar_cursor()`; id marcado antes de ejecutar en `marcar_visto()` | `casos_reinicio`: "ninguna orden ejecutada dos veces" |
| 3 | Acciones con `case`, sin `eval` ni `bash -c` | `ejecutar_accion()` y paso 9 de `procesar_mensaje()` | `casos_inyeccion` + fichero testigo |
| 4 | `ping` con 4 paquetes y objetivo validado por regex | `validar_objetivo()`, `RE_IPV4`, `RE_HOST`; `ping -c 4 -- "$objetivo"` | `casos_legitimos`, `casos_inyeccion` |
| 5 | `estado` como JSON | `trabajador_estado()` (con `jq --argjson`) | `casos_legitimos`: "estado (JSON válido)" |
| 6 | `puertos` con `ss -tuln` → array JSON | `trabajador_puertos()` | `casos_legitimos`, `caso_salida_larga` |
| 7 | `ayuda` con la lista de acciones | `trabajador_ayuda()` | `casos_legitimos` |
| 8 | Lo demás → `rechazada` con motivo | `rechazar()` | `casos_invalidos` |
| 9 | `timeout 10` en cada acción | `correr_con_timeout()` con `TIMEOUT_ACCION=10`; 124 → `error` | `caso_timeout` (`ping` falso que se cuelga → `error`/124) |
| 10 | Salida ≤ 2000 caracteres | `responder()`: `recortar` en jq y `head -c` en `correr_con_timeout()` | `caso_salida_larga` |
| 11 | `orden.sh` con id `openssl rand -hex 4` y espera ≤ 15 s | `construir_orden()`, `SECONDS=0` y `esperar_respuesta()` en `orden.sh` | todos los casos con `orden()` |

### Transporte y canales (§4 y §5)

| # | Requisito | Implementación | Prueba |
|---|---|---|---|
| 12 | HTTP aislado en `publicar()`/`consultar()` y `RECEPTOR` | `publicar()`, `consultar()`, `*_profesor()` y `*_webhooksite()` (TODO) | todas |
| 13 | `since`, `_id` entero, `--max-filesize`, N por ciclo, > 4 KB descartado | `consultar_profesor()`, filtro jq de `ciclo()`, `MAX_MSGS_CICLO`, `MAX_TAM_MSG` | `casos_mal_formados` (> 4 KB) |
| 14 | Secretos solo por entorno y nunca en logs | `comprobar_entorno()`; `peticion_http()` no registra la URL; `log_message` del servidor falso oculta el token | `caso_secretos` (busca `CLAVE` y `TOKEN_G4` en logs, estado y auditoría) |
| 15 | Ignorar `respuestas-g4`, el campo `bot` y otros canales | paso 2 de `procesar_mensaje()` | `casos_ignorados` |
| 16 | Responder siempre a una candidata con id válido; sin id válido solo auditar | pasos 3–9 llaman a `rechazar()`; paso 3 → `auditar ignorada` | `casos_mal_formados` (id no válido), `casos_invalidos` |

### Validación, acciones y HMAC (§6, §7 y §8)

| # | Requisito | Implementación | Prueba |
|---|---|---|---|
| 17 | Pipeline en el orden del §6 | `procesar_mensaje()`, pasos comentados del 1 al 10 | casos de cada paso |
| 18 | Claves permitidas | paso 4 (jq `IN(...)`) | `casos_invalidos`: clave extra |
| 19 | Tipos, sin usar ningún campo antes de validarlo | `leer_texto()` (cadena sin caracteres de control) y paso 5 | `casos_invalidos`: accion numérica, args cadena |
| 20 | Rechazar `-...`, espacios, `;`, `$()`, comillas, saltos de línea y controles | `validar_objetivo()` + `leer_texto()` | `casos_inyeccion` (13 ataques) |
| 21 | `duracion_ms` real | `ahora_ms()` (`date +%s%3N`) y `T_INICIO` | `caso_timeout` (entre 10 y 15 s con un timeout de 10 s) |
| 22 | `salida` siempre cadena, con JSON compacto en `estado`/`puertos` | `responder()` (`tojson`) | `casos_legitimos` |
| 23 | HMAC canónico `jq -cS`, mismas funciones en los dos scripts | `canonico()`, `firmar()`, `verificar()` (idénticas) | `casos_firma` |
| 24 | Sin clave por defecto | `comprobar_entorno()` | `caso_sin_clave` (`bot.sh` y `orden.sh`) |
| 25 | Las respuestas se firman y `orden.sh` las verifica | `responder()` → `firmar()`; `esperar_respuesta()` → `verificar()` | `casos_reinicio`: respuesta falsa |
| 26 | Formato de la firma: 64 hexadecimales | `verificar()` | `casos_firma` |
| 27 | `EXIGIR_FIRMA=0`: aviso grande y en la auditoría; firma falsa se sigue rechazando | `anunciar_arranque()`, `AVISO` en el paso 6 | `casos_reinicio` |

### Anti-repetición, estado, auditoría y cliente (§9 a §12)

| # | Requisito | Implementación | Prueba |
|---|---|---|---|
| 28 | `ts` ISO 8601 UTC real y a ±60 s | `validar_ts()` (regex + vuelta de `date`) | `--ts-viejo` |
| 29 | `id_orden` ya visto, y la lista persiste | `id_ya_visto()`, `marcar_visto()` → `ids_vistos.txt` | "misma orden dos veces" |
| 30 | 5 órdenes/min por `de`, ventana deslizante y persistente | `registrar_frecuencia()` → `frecuencia.json` | "6 órdenes en un minuto" |
| 31 | Directorio 700, `mktemp` + `mv`, `flock` | `preparar_estado()`, `escribir_atomico()` | `caso_ctrl_c` (bloqueo y temporales) |
| 32 | Primer arranque en `last_id`; reinicio desde el cursor | `inicializar_cursor()` | `casos_reinicio`: "continúa desde el cursor" |
| 33 | Si falla la publicación: auditar y seguir, sin volver a ejecutar | `publicada=false` en `procesar_mensaje()`/`rechazar()` | `caso_fallo_publicacion` (gancho que devuelve 500) |
| 34 | Auditoría JSONL completa, sin secretos y con textos limpios | `auditar()` (`limpio` en jq) | `casos_mal_formados`, `casos_reinicio` |
| 35 | `orden.sh` no valida el objetivo; opciones solo de pruebas | `leer_argumentos()` (opciones antes de la acción), `construir_orden()` | `casos_inyeccion`, `casos_firma` |
| 36 | `orden.sh` limpia los controles e intenta `fromjson` | `mostrar_respuesta()` | `caso_salida_con_escapes` (respuesta firmada con ESC y BEL) |
| 37 | Errores HTTP: 403, 5xx, timeout, DNS/conexión, JSON inválido | `peticion_http()`, `consultar_profesor()` | `caso_token_incorrecto`, `caso_servidor_caido`, `casos_mal_formados` |
| 38 | Un fallo temporal no detiene el bot | `if ! ciclo` en `main` | `caso_servidor_caido` |
| 39 | `trap` limpio y sin huérfanos | `limpiar()`, `esperar()`, `correr_con_timeout()` (segundo plano + `wait`) | `caso_ctrl_c` |

### Requisitos generales (§2)

| # | Requisito | Implementación | Prueba |
|---|---|---|---|
| 40 | Cabecera, `set -euo pipefail`, dependencias | inicio de cada `.sh` y `comprobar_dependencias()` | `bash -n` (✔ ejecutado); `shellcheck` (✔ sin avisos tras las correcciones de `prompts.md` §4) |

## 2. Revisión de seguridad

### 2.1 Qué protege y cómo

| Amenaza | Defensa |
|---|---|
| Inyección de comandos (`;`, `$()`, backticks, `&&`, `\|`) | Nunca se interpreta texto: `case` con 4 palabras fijas y el objetivo como **un** argumento entrecomillado |
| Inyección de argumentos (`-f`, `-c 100000`) | Se rechaza lo que empieza por `-` y se usa `--` antes del objetivo |
| Caracteres de control y escapes ANSI | `leer_texto()` los rechaza; log, auditoría y `orden.sh` los quitan antes de mostrar |
| Órdenes de otros grupos o falsas | HMAC-SHA256 sobre la forma canónica; formato comprobado antes de comparar |
| Respuestas falsas | Las respuestas van firmadas y `orden.sh` exige firma válida |
| Repetición de órdenes capturadas | Ventana de ±60 s y lista persistente de ids vistos |
| Abuso por volumen | 5/min por `de`, `MAX_MSGS_CICLO`, 4 KB por mensaje y `--max-filesize` |
| Comandos que se cuelgan o salidas enormes | `timeout 10`, `head -c` y recorte a 2000 caracteres en jq |
| Corrupción del estado o dos bots a la vez | `mktemp` + `mv` atómico, `flock` y permisos 700 / `umask 077` |
| Fuga de secretos | Solo variables de entorno; la URL con token no se registra; la clave nunca se escribe |

### 2.2 Vulnerabilidades residuales (conocidas y aceptadas)

| # | Riesgo | Impacto | Por qué se acepta / cómo mitigarlo |
|---|---|---|---|
| R1 | **Mensaje envenenado**: un mensaje que `jq` no puede procesar (JSON anidado más allá del límite de profundidad de jq) hace fallar `/sync` en cada ciclo y el cursor no avanza | Antes: el bot quedaba parado (DoS), **sin ejecutar nada**. Ahora un bot en marcha se recupera en unos 6 s; como mucho se pierden (sin ejecutar) los mensajes entre el cursor y el veneno. Sigue sin resolver: mientras el veneno esté en el histórico, `orden.sh` y el **primer** arranque del bot (leen `/sync` completo) no pueden empezar | **Mitigado en parte.** `tratar_fallo_ciclo()`: tras `UMBRAL_SALTO` (3) fallos de contenido seguidos (no de red), si `/sync?since=999999999999999` (sin mensajes) es JSON válido, se salta `cursor+1` con `evento: "salto"` en la auditoría. No se usa ese `since` para leer `last_id`: el real devuelve `last_id` = `since` (comprobado el 2026-11-24). Mejora posible para `orden.sh`: tomar el cursor del `_id` que devuelve el propio POST. Prueba: `caso_mensaje_envenenado` (PASA en Kali, 2026-11-24, versión final) |
| R2 | **Inundación** del canal con mensajes sin firma: el bot responde a cada uno (máx. `MAX_MSGS_CICLO` por ciclo); si `/sync` supera `MAX_BYTES_SYNC`, falla siempre | Retrasos (más de 15 s o 60 s) o bot parado | No hay paginación conocida en el servidor. Se pueden subir los límites; no hay solución completa sin cambios en el servidor |
| R3 | **Divulgación de información**: las respuestas de `estado` y `puertos` se publican en claro en un canal que leen los 9 grupos | Reconocimiento de la máquina | Es lo que pide el enunciado. Lo correcto sería cifrar la `salida` o limitar los datos |
| R4 | **HTTP sin TLS** | Cualquiera en la red ve órdenes, respuestas y el token | La integridad la cubre el HMAC; la confidencialidad no. Depende del servidor del profesor |
| R5 | **Clave compartida**: `de` no identifica a una persona concreta, y quien tiene la clave puede cambiar `de` para saltarse el límite | Suplantación entre quienes tienen la clave; límite eludible | Lo exige el diseño de clave simétrica. Una clave por persona o firmas asimétricas lo resolverían |
| R6 | `CLAVE` y `TOKEN_G4` aparecen en la línea de órdenes de `openssl` y `curl`, visibles con `ps`, y los heredan los procesos hijos | Otro usuario local podría leerlos | Kali de un solo usuario. Mitigación: pasar la clave por un fichero o descriptor (`-macopt hexkey:` sigue en argv; habría que usar `openssl mac` con fichero) y `env -u` en los hijos |
| R7 | Comparación de firmas no de tiempo constante (`==` de bash) | Ataque de temporización teórico | No es práctico por HTTP con sondeo cada 2 s |
| R8 | Las validaciones de claves y tipos (pasos 4–5) responden **antes** de verificar la firma | Un atacante sin clave aprende qué falla | Lo impone el orden del §6. No permite ejecutar nada |
| R9 | `ping` a un nombre de host provoca una consulta DNS al dominio que se elija | Canal lateral por DNS para quien tiene la clave | Es la funcionalidad pedida. Se podría limitar a IPv4 o a una lista de hosts |
| R10 | Dependencia del reloj (±60 s) | Con relojes desincronizados se rechazan las órdenes legítimas | Documentado: hay que activar NTP antes de la demo |
| R11 | Respuesta no publicada (fallo de red) → sin reintento | El cliente ve un timeout aunque la acción se ejecutó | Lo pide el enunciado (no repetir la acción); queda en la auditoría con `publicada:false` |
| R12 | `auditoria.jsonl` crece sin límite | Disco | Rotación con `logrotate` fuera del alcance de la práctica |
| R13 | Metadatos del servidor sin confirmar (¿sobrescribe `_id` si lo manda el cliente?) | Un `_id` falso podría desordenar el cursor | Se descartan los `_id` no enteros o mayores que `last_id`; nunca se usa `_recibido`/`_origen` |
| R14 | `webhooksite` es solo un esqueleto | Sin plan B operativo | Documentado con TODO; el arranque falla con un mensaje claro |

### 2.3 Preparación de la demo (en Kali)

Hecho el 2026-11-23 (resultados en `prompts.md` §5.2):

1. ✔ `shellcheck bot.sh orden.sh pruebas.sh`: 2 avisos corregidos, ahora sin avisos.
2. ✔ `./pruebas.sh`: 45 PASA · 0 FALLA contra el servidor falso (2026-11-23) y, con las
   pruebas nuevas, **56 PASA · 0 FALLA** (2026-11-24).
3. ✔ Prueba manual contra el **servidor real**: `ping 8.8.8.8` → ok;
   `'8.8.8.8; id'`, `'$(whoami)'` y `--firma-falsa` → rechazada.

El mismo día de la demo, justo antes de empezar:

4. Generar la `CLAVE` de la demo (`openssl rand -hex 32`) y dársela al profesor fuera del canal.
5. Comprobar la hora: `timedatectl status` → `System clock synchronized: yes`.
6. Arrancar `./bot.sh` **antes** de que el profesor envíe nada (el primer arranque salta el histórico).
