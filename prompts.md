# prompts.md — Uso de la IA en el Ejercicio 5 (Grupo 4)

**Autores:** Pol, Fran, Javi, Yeray, Ricardo — Máster de Ciberseguridad & IA (Evolve)

## 1. Objetivo del uso de la IA

- Usamos la IA como **redactor y revisor**, no como sustituto del criterio del grupo.
- **Proceso:**
  1. ChatGPT redactó una primera versión del prompt (Versión 1).
  2. Claude la auditó (Ronda 1).
  3. El grupo tomó las decisiones finales y escribió el **prompt final** (apartado 2).
  4. Con ese prompt, Claude (Claude Code) generó el código en 3 partes.
- **Qué queríamos conseguir:**
  - Cumplir íntegramente el enunciado con un diseño seguro frente a entradas hostiles.
  - Código que todos los miembros sepan explicar función a función.
  - Distinguir siempre lo **comprobado** de lo **supuesto** y de lo **no ejecutado**.
- **Regla del grupo:** ninguna prueba cuenta como superada hasta que la ejecutamos nosotros
  en Kali y pegamos aquí el resultado real.

## 2. Prompt final utilizado

<!-- Copia literal de prompt_final_ej5.md -->

````markdown
# PROMPT FINAL — Ejercicio 5: Bot ChatOps seguro (Grupo 4)

> Versión 1 de ChatGPT (redactor) + auditoría de Claude (Ronda 1) + decisiones del grupo.
> Cómo usarlo: pega TODO lo que hay debajo de la línea en un chat nuevo de Claude.
> Claude entregará la solución en 3 partes; escribe **CONTINÚA** para pedir la siguiente.

---

## 1. Rol, objetivo y prioridades

Actúa como ingeniero sénior de ciberseguridad especializado en Bash, automatización Linux y ChatOps, con experiencia docente.

Genera la solución completa del **Ejercicio 5 (Bot ChatOps con lista blanca de órdenes)** para el Grupo 4 del Máster de Ciberseguridad & IA de Evolve. Es una práctica académica con **demo en vivo de 3–4 minutos hoy mismo**. Los alumnos deben poder explicar cada función.

Prioridades, en este orden:
1. Cumplir íntegramente el enunciado.
2. Seguridad frente a entradas hostiles.
3. Funcionar con el servidor real documentado abajo.
4. Simplicidad y facilidad de explicación. **Nada de complejidad que no resuelva un requisito o una vulnerabilidad concreta.**

No inventes endpoints, respuestas HTTP ni resultados de pruebas. Si algo no está confirmado, márcalo como **[SUPUESTO]** y explica qué consecuencias tiene. No declares que una prueba ha pasado si no la has ejecutado.

## 2. Entorno

- Kali Linux con bash, curl, jq, shellcheck, nmap, openssl, timeout, ping, ss y python3. El propio enunciado usa `python3 -m http.server`.
- Comprueba las dependencias al inicio de cada script con un mensaje claro.
- Todos los scripts usan `set -euo pipefail`, funciones, `trap` (SIGINT, SIGTERM, EXIT) y control explícito de errores.
- Cabecera en cada `.sh` con autores (**Pol, Fran, Javi, Yeray, Ricardo — Grupo 4**), descripción y uso.
- Deben pasar `bash -n` y `shellcheck` sin avisos.

## 3. Enunciado oficial (no omitir nada)

**Scripts:** `bot.sh` (ejecuta) y `orden.sh` (cliente). **Canales lógicos:** `ordenes-g4` y `respuestas-g4`.

Contrato de la orden:
```json
{ "id_orden": "a1b2c3", "de": "profesor", "accion": "ping",
  "args": { "objetivo": "192.168.56.1" }, "ts": "2026-11-17T11:30:00Z" }
```
Contrato de la respuesta (`estado` ∈ `ok` | `error` | `rechazada`):
```json
{ "id_orden": "a1b2c3", "bot": "kali-g4", "estado": "ok", "codigo_salida": 0,
  "salida": "4 packets transmitted, 4 received...", "duracion_ms": 3021,
  "ts": "2026-11-17T11:30:03Z" }
```

**Fase 1:**
- `bot.sh` consulta las órdenes cada 2 s y procesa cada orden nueva **una sola vez**.
- Acciones permitidas, implementadas con `case` (**nunca** `eval` ni `bash -c` con texto recibido):
  - `ping`: 4 paquetes a `objetivo`, que debe ser una IP o un nombre de host válido (validado con regex).
  - `estado`: uptime, memoria y disco, devueltos como JSON.
  - `puertos`: puertos en escucha con `ss -tuln`, convertidos a array JSON.
  - `ayuda`: lista de acciones.
- Cualquier otra acción o argumento no válido → `"estado": "rechazada"` con el motivo.
- Cada ejecución con `timeout 10` y la salida recortada a 2000 caracteres.
- `orden.sh <accion> [objetivo]` genera un `id_orden` aleatorio (`openssl rand -hex 4`), envía la orden y espera **hasta 15 s** la respuesta con ese mismo id.

**Fase 2 elegida (4 ampliaciones):** firma HMAC, anti-repetición, límite de frecuencia y auditoría. No implementes `dns`.

**Criterio de "hecho":** el profesor envía en la demo una orden con un objetivo como `8.8.8.8; id` o `$(whoami)` y el bot la rechaza **sin ejecutar nada**. Las órdenes legítimas devuelven su respuesta en menos de 15 s.

## 4. Transporte: servidor del profesor (receptor principal, verificado)

Aísla todo el HTTP en dos funciones, `publicar()` y `consultar()`. El resto del código no debe saber qué receptor se usa. Se elige con `RECEPTOR=profesor` (por defecto) o `RECEPTOR=webhooksite`.

Datos **comprobados con peticiones reales**:
- `POST http://<IP_SERVIDOR_MASTER>:9004/webhook/$TOKEN_G4` con un JSON → HTTP 200 `{"ok":true,"project":"pr4","received":{...}}`.
- Token incorrecto → HTTP 403 `{"ok":false,"error":"token invalido"}`.
- `GET http://<IP_SERVIDOR_MASTER>:8084/sync` → `{"project":"pr4","count":N,"last_id":N,"messages":[...]}`.
- `GET .../sync?since=N` devuelve solo los mensajes con `_id > N`. El parámetro se llama **`since`**, no `desde`.
- Cada mensaje es **nuestro JSON plano más tres campos del servidor**: `_id` (entero incremental), `_recibido` (UTC del servidor) y `_origen` (IP del remitente). **No hay envoltorio `datos`.**
- Hay **un solo endpoint por grupo**. Órdenes y respuestas van mezcladas.
- No hay ruta de borrado. Ya existe un mensaje basura (`_id` 1, `"canal":"prueba"`) que debe ignorarse.
- `TOKEN_G4`, `CLAVE` y las URLs base se leen **solo de variables de entorno**. Las URLs tienen los valores de arriba por defecto y se pueden cambiar para el servidor falso. Nunca escribas secretos en el código, los ejemplos ni los logs.
- **[DESCONOCIDO]** Si un cliente envía él mismo `_id`, `_recibido` u `_origen`, no sabemos si el servidor lo sobrescribe. No uses `_recibido` ni `_origen` como prueba de nada. Usa `_id` solo como cursor, validando que es entero.
- **[DESCONOCIDO]** No conocemos la paginación de `/sync`. Protégete de inundaciones:
  - limita el tamaño de la respuesta (`curl --max-filesize`);
  - procesa como máximo N mensajes por ciclo;
  - descarta los mensajes de más de 4 KB antes de procesarlos.
- Los tokens de los 9 grupos se vieron en el directo: **cualquiera puede publicar en nuestro canal**.

**webhook.site:** solo un esqueleto de `publicar`/`consultar` con TODO claros (crear con `POST https://webhook.site/token` → `uuid`; leer con `GET https://webhook.site/token/<uuid>/requests`; el cuerpo viene como texto en `.data[].content`; no existe `since`). Sin paginación ni persistencia. Es solo un plan B documentado.

## 5. Distinguir órdenes y respuestas (compatibilidad con el profesor)

El profesor puede enviar órdenes con el **contrato oficial puro**, sin `canal` ni `firma`. Por eso:
- Las respuestas del bot llevan además `"canal":"respuestas-g4"` y `"firma"`.
- El bot **ignora** todo mensaje con `canal` = `respuestas-g4`, todo mensaje con campo `bot`, y todo mensaje con un `canal` distinto de `ordenes-g4`.
- Un mensaje **sin** `canal`, o con `canal` = `ordenes-g4`, es una **orden candidata**. `orden.sh` envía `canal: ordenes-g4`.
- **Nunca ignores en silencio una orden candidata con `id_orden` válido:** responde siempre, aunque sea `rechazada` con el motivo, para que el profesor vea que el bot está vivo.
- Si no hay un `id_orden` válido (de 1 a 32 caracteres `[A-Za-z0-9_-]`), no respondas. Solo regístralo en la auditoría.

## 6. Pipeline de validación (todo JSON recibido es hostil)

En este orden, y sin usar ningún campo antes de validarlo:
1. Tamaño ≤ 4 KB, JSON válido y la raíz es un objeto.
2. Clasificar: respuesta o ajeno → ignorar; orden candidata → seguir.
3. `id_orden` válido, o no hay respuesta posible.
4. Claves permitidas: las del contrato más `canal` y `firma`, más los metadatos `_id`, `_recibido` y `_origen` (que se apartan antes de verificar la firma). Cualquier otra clave → `rechazada`.
5. Tipos: `de`, `accion`, `ts` y `id_orden` son cadenas; `args` es un objeto (o está ausente) y `args.objetivo` es una cadena.
6. **Firma HMAC** (ver §8). Se controla con `EXIGIR_FIRMA`, que vale 1 por defecto.
7. Anti-repetición: antigüedad y `id_orden` ya visto.
8. Límite de frecuencia por `de`, solo después de verificar la firma.
9. Acción en la lista blanca y argumentos válidos.
10. Ejecutar.

## 7. Acciones

- **Selección con `case`.** Prohibido `eval`, `bash -c`, `source` y cualquier forma de interpretar texto recibido como código. Variables **siempre entre comillas**.
- **`ping`:**
  - Validar el objetivo contra:
    - IPv4 con octetos 0–255;
    - o hostname ASCII de hasta 253 caracteres, con etiquetas de 1 a 63 que no empiecen ni terminen por guion.
  - Una IPv4 fuera de rango (`999.999.999.999`) **no** se acepta como hostname. Solo IPv4, sin IPv6.
  - Rechazar los valores que empiezan por `-` (inyección de **argumentos**: `-f`, `-c 100000`), los espacios, `;`, `$()`, las comillas, los saltos de línea y los caracteres de control.
  - Ejecutar `ping -c 4 -- "$objetivo"`.
  - Documentar la regex con pruebas positivas y negativas.
- **`estado`:** uptime, memoria y disco → objeto JSON construido con `jq`.
- **`puertos`:** `ss -tuln` → array JSON construido con `jq`. Sin resultados → `[]`, sin inventar nada.
- **`ayuda`:** las 4 acciones y sus argumentos.
- **`timeout 10`** en cada acción, sin `bash -c`. Si una acción necesita varios comandos, usa un subcomando interno del propio script (p. ej. `bot.sh --trabajador estado`) ejecutado con `timeout`. Ese modo no consulta ni publica nada.
  - Si se agota el tiempo: `estado` = `error`, con el código de salida real (124) y registro en auditoría.
- **`duracion_ms`** medida de verdad (p. ej. con `date +%s%3N`).
- **`salida` es siempre una cadena**, como en el ejemplo oficial. En `estado` y `puertos` contiene JSON compacto válido. Recórtala a 2000 caracteres **dentro de jq** (`.[0:2000]`), nunca cortando bytes, y limita también lo capturado con `head -c`.

## 8. HMAC-SHA256

- La clave se lee de `CLAVE`. Si falta o está vacía, el bot y el cliente se detienen con un error claro. **No hay clave por defecto.**
- Firmar:
  1. construir el objeto completo (con `canal`) y quitar `firma` y los metadatos del servidor;
  2. aplicar `jq -cS 'del(.firma)'`;
  3. calcular `openssl dgst -sha256 -hmac "$CLAVE"` sobre esos bytes exactos;
  4. añadir `firma` en hexadecimal.
- Las mismas funciones `firmar()` y `verificar()` en los dos scripts.
- Las respuestas también se firman, y `orden.sh` las verifica: cualquiera puede publicar respuestas falsas con nuestro id.
- Validar el formato (64 caracteres hexadecimales) antes de comparar.
- **`EXIGIR_FIRMA=1` (por defecto):** sin firma → `rechazada: firma ausente`; firma inválida → `rechazada: firma incorrecta`.
- **`EXIGIR_FIRMA=0`:** se aceptan órdenes sin firmar, para el caso de que el profesor use su propia herramienta. El bot lo avisa en grande al arrancar y lo registra en auditoría. Una firma presente pero incorrecta se sigue rechazando. La validación de acción y argumentos protege igual.
- Nunca registres la clave.

## 9. Anti-repetición, límite de frecuencia y persistencia

- **Antigüedad:** `ts` debe ser una fecha ISO 8601 UTC real y estar a ±60 s del reloj del bot; sirve también para las fechas futuras. Documentar que hace falta sincronizar los relojes.
- **`id_orden` ya visto** → `rechazada`. La lista persiste tras reiniciar.
- **Límite de frecuencia:** máximo 5 órdenes por minuto por `de` autenticado, en ventana deslizante de 60 s. Se cuentan las órdenes con la firma ya verificada (o todas si `EXIGIR_FIRMA=0`). Persiste en un fichero sencillo. Documentar que una clave compartida no prueba qué persona concreta envió la orden.
- **Directorio de estado** con permisos 700:
  - cursor `_id`, ids vistos y marcas de tiempo de la frecuencia;
  - escrituras atómicas (`mktemp` + `mv`);
  - `flock` para impedir dos bots a la vez.
- **Arranque:** la primera vez, el cursor arranca en el `last_id` actual, sin ejecutar el histórico. En los reinicios, continúa desde el cursor guardado. El cursor se avanza **después** de tratar cada mensaje.
- Si falla la publicación de una respuesta: registrar en auditoría y seguir, **sin volver a ejecutar la acción**. No hay cola de reintentos.

## 10. Auditoría

`auditoria.jsonl`, con una línea JSON construida con `jq` por cada orden candidata. Campos:
- `ts`, `_id`, `id_orden` (si es válido), `de`, `accion`;
- `decision` (`ejecutada` / `rechazada` / `ignorada`) y `motivo`;
- `estado`, `codigo_salida` y `duracion_ms`.

Sin secretos. Los textos se recortan y se limpian de caracteres de control.

## 11. orden.sh

- Uso:
  - `./orden.sh ping 8.8.8.8`
  - `./orden.sh estado`
  - `./orden.sh puertos`
  - `./orden.sh ayuda`
- **No valida ni limpia el objetivo antes de enviarlo**, solo lo codifica con `jq --arg`. La defensa está en el bot, y la demo debe poder enviarle ataques reales.
- **Opciones solo para pruebas** (documentadas como tales):
  - `--sin-firma` y `--firma-falsa`, para demostrar el rechazo por HMAC;
  - `--de NOMBRE` (por defecto, el usuario local);
  - `--ts-viejo`, para demostrar la anti-repetición.
- Espera como máximo 15 s **en total**:
  - consulta con `since` desde el `last_id` que había antes de enviar;
  - acepta solo una respuesta de `respuestas-g4` con su `id_orden` y una firma válida;
  - ignora todo lo demás.
- Muestra la respuesta limpiando antes los caracteres de control (ESC incluido) e intentando `fromjson` en `salida`.
- Si se agota el tiempo: error claro y código de salida distinto de 0.

## 12. Errores HTTP y cierre limpio

- `curl` con `--connect-timeout` y `--max-time`. Comprobar el código HTTP y el JSON.
- Distinguir:
  - 403 (token o configuración: error permanente, mensaje claro);
  - 5xx;
  - timeout;
  - fallo de DNS o de conexión;
  - JSON inválido o respuesta vacía.
- Un fallo temporal **no detiene** el bucle del bot.
- `trap` para SIGINT y SIGTERM: limpia los temporales, libera el bloqueo y no deja procesos huérfanos (comprobable con `ps`).

## 13. Servidor falso local (`servidor_falso.py`, solo para pruebas)

Python 3 con la biblioteca estándar. Imita **solo** lo verificado:
- `POST /webhook/<token>`: 403 si el token no coincide con `TOKEN_G4`; si coincide, guarda el mensaje añadiendo `_id`, `_recibido` y `_origen`.
- `GET /sync` y `GET /sync?since=N`.

Las URLs de los scripts se pueden cambiar por variables de entorno para apuntar a él. Hay que documentar sus diferencias con el servidor real. Nunca digas que algo se ha probado contra el servidor real si solo se ha probado contra el falso.

## 14. Pruebas (`pruebas.sh` + tabla en el README)

Pruebas reproducibles contra el servidor falso, cada una con su resultado esperado:

| Caso | Resultado esperado |
|---|---|
| `ping 8.8.8.8` / `ping localhost` | ok |
| `estado`, `puertos`, `ayuda` | ok (JSON válido en `salida`) |
| acción `borrar`, `accion` numérica, `args` de tipo incorrecto, clave extra | rechazada |
| `'8.8.8.8; id'`, `'$(whoami)'`, `'-f'`, `'-c 100000'`, `999.999.999.999`, espacios, salto de línea, ESC | rechazada **y fichero testigo intacto** |
| JSON mal formado, mensaje > 4 KB | ignorado sin ejecutar nada |
| `--sin-firma` / `--firma-falsa` / orden alterada tras firmar | rechazada (con `EXIGIR_FIRMA=1`) |
| orden sin firmar con `EXIGIR_FIRMA=0` | ok, con aviso en auditoría |
| id repetido / `--ts-viejo` / sexta orden en un minuto | rechazada |
| mensaje de `canal` `prueba` o `respuestas-g4` | ignorado |
| respuesta falsa con nuestro id | `orden.sh` no la acepta |
| reiniciar el bot | no repite órdenes |
| servidor caído / token incorrecto (403) | error controlado / error de configuración claro |
| salida > 2000 caracteres | recortada, JSON válido |
| Ctrl+C | cierre limpio, sin procesos huérfanos |

- Explica que los ataques se escriben **entre comillas simples** para que no los ejecute el propio shell del alumno.
- La prueba del **fichero testigo** demuestra que la inyección no tuvo efecto. No basta con ver "rechazada".

## 15. README.md y prompts.md

**README.md:**
1. Objetivo.
2. Arquitectura en sencillo.
3. Dependencias.
4. Variables de entorno (`TOKEN_G4`, `CLAVE`, `RECEPTOR`, `EXIGIR_FIRMA` y URLs).
5. Arranque.
6. Ejemplos de uso y de JSON.
7. HMAC, anti-repetición, límite de frecuencia y auditoría explicados.
8. Cómo darle al profesor `orden.sh` y la CLAVE fuera del canal.
9. Servidor falso y pruebas.
10. Limitaciones y supuestos.
11. Por qué se ponen comillas en las variables y por qué nunca se ejecuta texto recibido.
12. **Guion de demo de 3–4 minutos:**
    - arrancar el bot **antes** de que el profesor envíe nada;
    - orden legítima;
    - `8.8.8.8; id`;
    - `$(whoami)`;
    - `--firma-falsa`;
    - enseñar `auditoria.jsonl`.

**prompts.md:**
- objetivo del uso de la IA;
- este prompt;
- apartados **vacíos** para la Ronda 1 (Versión 1 de ChatGPT y auditoría de Claude), las correcciones del grupo sobre el código generado y las pruebas **realmente ejecutadas**.

No fabriques contenido: distingue las pruebas propuestas de las ejecutadas.

## 16. Formato de entrega (3 partes; espera "CONTINÚA" entre ellas)

- **Parte 1:** decisiones de diseño (breves), `bot.sh` y `orden.sh` completos.
- **Parte 2:** `servidor_falso.py`, `pruebas.sh` y `README.md` completos.
- **Parte 3:** `prompts.md`, checklist que relaciona cada requisito con su implementación y su prueba, y revisión de seguridad con las vulnerabilidades residuales.

Archivos **completos**, sin pseudocódigo ni "resto igual". Antes de cada parte, revisa que se cumple todo lo de arriba. Si puedes ejecutar `shellcheck` y las pruebas, muestra los resultados reales; si no, dilo expresamente.
````

## 3. Ronda 1

### 3.1 Versión 1 (ChatGPT, redactor)

El texto íntegro de la Versión 1 no se conservó. Su contenido se puede reconstruir a partir
de la auditoría de Claude (§3.2 y `ronda1_auditoria_claude.md`), que cita los puntos
concretos que se cambiaron, y del prompt de arranque del debate (`prompt_debate_ej5.md`).

### 3.2 Auditoría de Claude (Ronda 1)

La auditoría completa, con las respuestas del grupo a sus preguntas, está en
`ronda1_auditoria_claude.md`. Resumen de lo que cambió el prompt:

- **B1 (bloqueante):** las órdenes del profesor sin `canal` ni `firma` no tendrían respuesta.
  → `canal` opcional, nunca ignorar en silencio una orden con id válido y `EXIGIR_FIRMA`.
- **B2 (bloqueante):** alcance excesivo para el plazo. → webhook.site solo como esqueleto,
  sin cola de respuestas pendientes.
- **B3 (bloqueante):** `orden.sh` no debe validar el objetivo, o los ataques no llegan al
  bot. → opciones de prueba `--sin-firma` y `--firma-falsa`.
- **I1–I3 y M1–M4:** entrega en 3 partes, defensa contra inundación (`--max-filesize`,
  N mensajes por ciclo, 4 KB), arrancar el bot antes que el profesor, firma de las
  respuestas y detalles de formato.

## 4. Correcciones del grupo sobre el código generado

Cambios hechos a mano por el grupo en Kali sobre el código generado, tras la primera
ejecución de `shellcheck`:

| Fichero / función | Cambio | Motivo |
|---|---|---|
| `orden.sh`, `bot.sh`, `pruebas.sh` / `limpiar()` | Directiva `# shellcheck disable=SC2317` → `SC2317,SC2329` | `shellcheck` en Kali avisó SC2329 ("función nunca invocada"). Es un falso positivo: se invoca desde `trap limpiar EXIT` |
| `pruebas.sh` / `orden()` | Eliminada la variable `ORDEN_RC` (`\|\| ORDEN_RC=$?` → `\|\| true`) | `shellcheck` avisó SC2034: se asignaba pero ningún caso la usaba |
| `*.sh`, `*.py` | Conversión a finales de línea LF (`sed -i 's/\r$//'`) | Ficheros generados en Windows; en Kali el CRLF rompería los scripts |

### 4.1 Mejoras posteriores (con Claude Code, 2026-11-24)

Después de las pruebas en Kali del 2026-11-23, el grupo pidió a Claude Code mitigar el riesgo R1 (mensaje
envenenado) y automatizar las revisiones manuales. Resultado en Kali: **56 PASA · 0 FALLA**
(ver §5.2). Después, una comprobación contra el servidor real obligó a corregir parte de la
mitigación (fila "Vuelven a leer `last_id`…"). Con la corrección, todo se volvió a probar
en Kali y contra el real (§5.2, últimas filas).

| Fichero / función | Cambio | Motivo |
|---|---|---|
| `bot.sh` / `consultar_profesor()`, `ciclo()` | Devuelven 3 si `/sync` llega pero no se puede interpretar (antes, 1 para todo) | Distinguir un fallo de red de un mensaje envenenado |
| `bot.sh` / `tratar_fallo_ciclo()`, `saltar_mensaje()` | Nuevas: tras 3 fallos de contenido seguidos se salta `cursor+1` si existe, con `evento: "salto"` en la auditoría | Que un mensaje envenenado no pare el bot para siempre (R1) |
| `bot.sh` / `leer_last_id()`; `orden.sh` / paso 1 de `main` | `last_id` con `since=999999999999999` en vez de `/sync` completo. **Revertido** (ver fila siguiente) | Al revisar R1 se vio que `orden.sh` no podría enviar nada con un veneno en el histórico |
| `bot.sh` / `leer_last_id()`, `tratar_fallo_ciclo()`; `orden.sh` / paso 1; `servidor_falso.py` | Vuelven a leer `last_id` con `/sync` completo. El `since` enorme solo sirve ya de "prueba de salud" antes de saltar. El servidor falso devuelve `last_id` = `since` cuando `since` es mayor que el último `_id` | **Comprobado contra el real:** `since=999999999999999` devolvió `last_id: 999999999999999`. Con la versión anterior, `orden.sh` no habría visto nunca la respuesta y el bot habría ignorado todo en su primer arranque. El servidor falso no lo detectaba porque devolvía el `last_id` real |
| `servidor_falso.py` | Gancho `/_pruebas/envenenar/<token>` | Poder probar R1 |
| `pruebas.sh` / `caso_mensaje_envenenado()` | Caso nuevo (3 comprobaciones) | Prueba de R1 |
| `pruebas.sh` / `caso_sin_clave()`, `caso_timeout()`, `caso_fallo_publicacion()`, `caso_salida_con_escapes()`, `caso_secretos()` | Casos nuevos (8 comprobaciones); `arrancar_bot` admite un directorio extra en el `PATH` y `esperar_respuestas` un tiempo máximo | Automatizar las "revisiones manuales" de `revision.md` (filas 9, 14, 21, 24, 33 y 36) |
| `servidor_falso.py` | Gancho `/_pruebas/fallar_respuesta/<token>` | Poder probar la fila 33 (fallo al publicar) |
| `pruebas.sh` / `caso_secretos()` | `grep … \| wc -l` → `{ grep … \|\| true; } \| wc -l` | En la 1.ª ejecución en Kali el script se cortó en esta prueba sin imprimir el total: `grep` devuelve 1 cuando **no** hay fugas (el caso bueno) y, con `set -e` + `pipefail`, eso terminaba el script |

## 5. Pruebas realmente ejecutadas

### 5.1 Ejecutadas por la IA durante la generación (NO en Kali)

Entorno: Windows 11, Git Bash (GNU bash 5.2.37) y WSL Ubuntu. Allí **no** había `jq` ni
`shellcheck`, así que solo se pudo comprobar esto:

| Prueba | Resultado real |
|---|---|
| `bash -n bot.sh` | OK, sin errores de sintaxis |
| `bash -n orden.sh` | OK, sin errores de sintaxis |
| `bash -n pruebas.sh` | OK, sin errores de sintaxis |
| `python3 -m py_compile servidor_falso.py` (WSL Ubuntu) | OK |
| `validar_objetivo` de `bot.sh` con 23 casos (bash 5.2, `LC_ALL=C`) | Coinciden con lo esperado. **Acepta:** `8.8.8.8`, `localhost`, `192.168.56.1`, `kali-g4`, `google.com`, `0.0.0.0`, `255.255.255.255`, `xn--bcher-kva.example`. **Rechaza:** `8.8.8.8; id`, `$(whoami)`, `-f`, `-c 100000`, `999.999.999.999`, `8.8.8.8 ` (espacio), `8.8.8.8\n`, `\e[31m`, `010.0.0.1`, `1.2.3`, `-host`, `host-`, cadena vacía, `a..b`, `0x7f.1` |

**No se ejecutó en esta fase** (el grupo lo ejecutó después en Kali: ver §5.2):

- `shellcheck`.
- `pruebas.sh` ni ninguna ruta que dependa de `jq`: firma, pipeline de validación,
  respuestas, auditoría y bucle del bot.
- Ninguna prueba contra el **servidor real**.

### 5.2 Ejecutadas por el grupo en Kali

Salida real de los comandos ejecutados en Kali el 2026-11-23. Cada prueba indica si fue
contra el servidor **falso** o contra el **real**.

```text
$ for f in bot.sh orden.sh pruebas.sh; do bash -n "$f" && echo "$f OK"; done; shellcheck bot.sh orden.sh pruebas.sh
bot.sh OK
orden.sh OK
pruebas.sh OK
In orden.sh line 328:   SC2329 (info): This function is never invoked.   (limpiar)
In pruebas.sh line 126: SC2034 (warning): ORDEN_RC appears unused.

# tras las correcciones del apartado 4:
$ sed -i 's/\r$//' *.sh *.py && shellcheck bot.sh orden.sh pruebas.sh && echo "shellcheck sin avisos"
shellcheck sin avisos

$ chmod +x *.sh && ./pruebas.sh        # (zsh: permission denied sin el chmod)
== Órdenes legítimas            5/5 PASA  (ping 8.8.8.8, ping localhost, estado, puertos, ayuda)
== Acciones no válidas          4/4 PASA
== Inyección + testigo         15/15 PASA (13 ataques rechazados, testigo intacto, pwned no existe)
== JSON mal formado / > 4 KB    3/3 PASA
== Firma HMAC                   3/3 PASA
== Anti-repetición/frecuencia   3/3 PASA
== Mensajes que no son órdenes  2/2 PASA
== Salida > 2000 caracteres     1/1 PASA  (puertos con 81 líneas en ss)
== Bot parado/reinicio/EXIGIR_FIRMA=0  5/5 PASA
== Token incorrecto (403)       1/1 PASA
== Ctrl+C durante una acción    1/1 PASA  (SIGINT: cierre limpio sin huérfanos)
== Servidor caído               2/2 PASA
Total: 45 PASA · 0 FALLA
Tabla guardada en /home/kali/Desktop/Ejercicio Grupo 4/resultados_pruebas.md
```

La tabla completa, caso a caso, está en `resultados_pruebas.md`. Ese fichero se sobrescribe en
cada ejecución: el que se entrega corresponde a la del 2026-11-24 (56 casos).

| Prueba | Servidor (falso / real) | Fecha | Resultado real |
|---|---|---|---|
| `bash -n` de los 3 scripts | — (no usa red) | 2026-11-23 | OK |
| `shellcheck` (1.ª ejecución) | — | 2026-11-23 | 2 avisos: SC2329 en `orden.sh` y SC2034 en `pruebas.sh` |
| `shellcheck` (tras corregir) | — | 2026-11-23 | **Sin avisos** |
| `./pruebas.sh` (45 casos) | **falso** (127.0.0.1:8099) | 2026-11-23 | **45 PASA · 0 FALLA** |
| Arranque de `./bot.sh` | **real** (<IP_SERVIDOR_MASTER>) | 2026-11-23 | OK: "primer arranque: se ignora el histórico (cursor = 3)" |
| `./orden.sh ping 8.8.8.8` | **real** | 2026-11-23 | **ok**, código 0, 3125 ms, 4/4 paquetes |
| `./orden.sh ping '8.8.8.8; id'` | **real** | 2026-11-23 | **rechazada**: objetivo no válido para ping (99 ms) |
| `./orden.sh ping '$(whoami)'` | **real** | 2026-11-23 | **rechazada**: objetivo no válido para ping (94 ms) |
| `./orden.sh --firma-falsa estado` | **real** | 2026-11-23 | **rechazada**: firma incorrecta (63 ms) |
| `jq ... auditoria.jsonl \| tail -n 6` | **real** | 2026-11-23 | 1 evento de arranque + 1 `ejecutada` + 3 `rechazada`, con su motivo |
| Ctrl+C en el bot | **real** | 2026-11-23 | "bot detenido (código 130)" |
| Respuestas propias ignoradas | **real** | 2026-11-23 | El bot registra "mensaje 5/7/9/11 ignorado (respuesta)": no procesa sus propias respuestas |
| `./pruebas.sh` (56 casos, 1.ª ejecución tras las mejoras de §4.1) | **falso** | 2026-11-24 | 55 PASA y el script se cortó en `caso_secretos` sin imprimir el total (fallo de la propia prueba, corregido: ver §4.1) |
| `./pruebas.sh` (56 casos, tras la corrección) | **falso** | 2026-11-24 | **56 PASA · 0 FALLA** |
| `shellcheck bot.sh orden.sh pruebas.sh` | — | 2026-11-24 | **Sin avisos** |
| `curl "…/sync?since=999999999999999" \| jq .` | **real** | 2026-11-24 | `{"project":"pr4","count":0,"last_id":999999999999999,"messages":[]}`: con un `since` mayor que el último `_id`, el real devuelve `last_id` = `since`. Invalidó la lectura de `last_id` de §4.1, que se corrigió |
| `shellcheck` (versión final) | — | 2026-11-24 | **Sin avisos** |
| `./pruebas.sh` (versión final, 56 casos) | **falso** | 2026-11-24 | **56 PASA · 0 FALLA** |
| Arranque de `./bot.sh` (versión final) | **real** | 2026-11-24 | OK: "primer arranque: se ignora el histórico (cursor = 21)", el `last_id` real |
| `./orden.sh ping 8.8.8.8` (versión final) | **real** | 2026-11-24 | **ok**, código 0, 3139 ms, 4/4 paquetes |
| `./orden.sh ping '8.8.8.8; id'` (versión final) | **real** | 2026-11-24 | **rechazada**: objetivo no válido para ping (95 ms) |
| Respuestas propias ignoradas (versión final) | **real** | 2026-11-24 | "mensaje 23 / 25 ignorado (respuesta)" |

**Observación de la prueba real:** una orden enviada **antes** de arrancar el bot acabó en
"sin respuesta válida en 15 s". Es lo esperado: en el primer arranque el bot salta el
histórico. Confirma el punto del guion de demo: arrancar el bot **antes** de que el
profesor envíe nada.

**Comprobado contra el real**, y que antes estaba sin confirmar:
- `since` y `last_id` funcionan como se documentó.
- Los mensajes llegan con `_id` incremental: cada orden y su respuesta ocupan dos `_id`
  seguidos.
- `TOKEN_G4` es alfanumérico, así que el supuesto sobre sus caracteres se cumple.
