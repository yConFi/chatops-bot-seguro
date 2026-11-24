# Debate Claude ↔ ChatGPT — Ejercicio 5 (Bot ChatOps con lista blanca)

Grupo 4 · Máster Evolve Ciberseguridad & IA · Profesor: Carlos Gómez

**Objetivo del debate:** que ChatGPT y Claude, discutiendo entre sí, produzcan **un único prompt final**.
El grupo pegará ese prompt en Claude (claude.ai o Claude Code) para generar `bot.sh`, `orden.sh`, `README.md` y `prompts.md`.

**Reparto de papeles**
- **ChatGPT (Plus) = REDACTOR.** Escribe y mejora el prompt.
- **Claude = AUDITOR (red team).** Lo ataca: busca requisitos que faltan, vulnerabilidades y cosas inventadas.
- **El grupo** pasa los mensajes de uno a otro y decide cuando no se ponen de acuerdo.

---

## Cómo usarlo (pasos para el grupo)

1. Copiad **el bloque "PROMPT DE ARRANQUE"** entero y pegadlo en un chat nuevo de **ChatGPT**.
2. ChatGPT responde con la **Versión 1** del prompt. Copiad su respuesta completa y pegadla en el chat con Claude, empezando así:
   `RONDA 1 — respuesta de ChatGPT:` seguido del texto.
3. Claude responde con su auditoría. Copiadla entera en ChatGPT, empezando así:
   `RONDA 1 — auditoría de Claude:` seguido del texto.
4. Repetid hasta que **los dos** escriban `ESTADO: SIN OBJECIONES BLOQUEANTES`, o hasta un **máximo de 3 rondas**. Vais justos para la demo.
5. Si alguno hace **PREGUNTAS PARA EL GRUPO**, contestadlas vosotros. No dejéis que las IAs se las respondan entre ellas.
6. Guardad cada ronda: es material para `prompts.md`.

> Copiad siempre la respuesta **entera**, sin resumir. Si resumís, se pierden las objeciones.

---

## PROMPT DE ARRANQUE (pegar en ChatGPT; Claude ya lo tiene)

```text
Vas a participar en un debate entre dos IAs para redactar UN prompt de ingeniería
excelente. Tú (ChatGPT) eres el REDACTOR. La otra IA (Claude) es el AUDITOR:
atacará cada versión de tu prompt buscando huecos, vulnerabilidades e invenciones.
Un grupo de 5 alumnos de un máster de ciberseguridad hará de intermediario.

=== QUÉ HAY QUE PRODUCIR ===
Un prompt final que el grupo pegará en Claude para que genere, en Bash, la solución
completa del ejercicio de abajo: bot.sh, orden.sh, README.md y prompts.md, más un
plan de pruebas. El prompt debe hacer que el código generado:
  1) cumpla TODOS los requisitos de fase 1, sin excepción;
  2) implemente las ampliaciones de fase 2 elegidas;
  3) resista en la demo los ataques del profesor (inyección de comandos y de argumentos);
  4) sea entendible: el grupo debe poder explicarlo y corregirlo (es un objetivo evaluado).

=== REGLAS DEL DEBATE (obligatorias) ===
R1. No inventes. Todo requisito debe salir del enunciado de abajo. Si necesitas suponer
    algo, márcalo como [SUPUESTO] y añádelo a PREGUNTAS PARA EL GRUPO.
R2. No elimines ni suavices ningún requisito del enunciado. No añadas complejidad que no
    aporte nota ni seguridad.
R3. Cada objeción o cambio debe citar el requisito o el riesgo concreto que resuelve.
R4. Sé directo. Nada de cumplidos. Si la otra IA tiene razón, dilo en una línea y corrige.
R5. Responde SIEMPRE con este formato exacto:

    ## RONDA N — [REDACTOR | AUDITOR]
    ### Acuerdos
    ### Objeciones (cada una con severidad: BLOQUEANTE / IMPORTANTE / MENOR)
    ### Cambios aplicados respecto a la versión anterior
    ### PROMPT — Versión N   (solo el REDACTOR; texto completo, no un diff)
    ### PREGUNTAS PARA EL GRUPO   (solo lo que únicamente el grupo puede responder)
    ESTADO: [HAY OBJECIONES BLOQUEANTES | SIN OBJECIONES BLOQUEANTES]

R6. Máximo 3 rondas. En la ronda 3 el REDACTOR entrega la versión FINAL.

=== RESTRICCIONES DEL ENTORNO (datos reales, no inventar más) ===
- Kali Linux con bash, curl, jq, shellcheck y nmap.
- Hay que usar set -euo pipefail, funciones, trap, control de errores, curl para
  POST/GET y jq para construir y validar JSON (nunca concatenar JSON a mano).
- El código debe pasar shellcheck sin avisos.
- Cada .sh lleva cabecera: autores (Grupo 4), descripción y uso.
- RECEPTOR DE WEBHOOKS: hay dos opciones y el bot debe soportar ambas mediante una capa
  de transporte aislada (funciones publicar() y consultar(), elegidas con una variable
  de entorno, p. ej. RECEPTOR=webhooksite|profesor). El resto del código no debe saber
  qué receptor se usa.

  (A) Servidor del profesor (RECEPTOR PRINCIPAL). Datos publicados por el profesor y
      comprobados por el grupo:
      - Un webhook y un sync POR GRUPO (no por canal). Grupo 4:
          POST http://<IP_SERVIDOR_MASTER>:9004/webhook/<TOKEN_G4>   (token en variable de
               entorno, nunca escrito en el código ni en el repositorio)
          GET  http://<IP_SERVIDOR_MASTER>:8084/sync
      - Enviar: POST con JSON al webhook -> responde { "ok": true, ... }.
      - Recuperar: GET /sync -> { "project", "count", "last_id", "messages": [ ... ] }.
        Incremental con ?since=<last_id>  (OJO: "since", no "desde").
      - COMPROBADO con un mensaje de prueba real:
          POST {"canal":"prueba","nota":"test grupo 4"}
            -> HTTP 200 {"ok":true,"project":"pr4","received":{...el mismo JSON...}}
          GET /sync
            -> {"project":"pr4","count":1,"last_id":1,"messages":[
                 {"_id":1,"_recibido":"2026-11-23T18:16:09Z","_origen":"<IP pública>",
                  "canal":"prueba","nota":"test grupo 4"} ]}
          GET /sync?since=1 -> {"count":0,"last_id":1,"messages":[]}
        Es decir: NO hay envoltorio "datos"; el servidor mezcla en el mismo objeto
        nuestro JSON y tres campos suyos: _id (entero incremental), _recibido (hora del
        servidor, UTC) y _origen (IP del remitente). ?since=N devuelve solo _id > N.
      - YA HAY un mensaje basura en el canal (_id 1, "canal":"prueba"): el bot debe
        ignorarlo. Al arrancar, el bot debe decidir si procesa el histórico o empieza
        desde el last_id actual (el debate debe elegir y justificar).
      - [DESCONOCIDO] Si un cliente envía él mismo "_id", "_recibido" u "_origen", ¿los
        respeta o los sobrescribe el servidor? No se ha probado. Hasta saberlo, el bot no
        debe confiar en nada de lo que venga en el mensaje salvo _id para el orden.
      - _recibido sirve para la anti-repetición sin depender del reloj del cliente
        (si se confirma que el cliente no puede falsearlo).
      - No hay ruta de borrado: lo que se publica se queda. El bot debe ignorar con
        seguridad cualquier mensaje que no sea una orden válida.
      - CANALES: como solo hay un endpoint por grupo, "ordenes-g4" y "respuestas-g4" deben
        ser un campo del JSON (p. ej. "canal") y el bot filtrar por él. Además el bot debe
        ignorar sus propias respuestas para no entrar en bucle. El debate debe cerrar el
        nombre del campo y justificarlo.
      - El servidor valida el token: con un token incorrecto responde
          HTTP 403 {"ok":false,"error":"token invalido"}   (comprobado).
        El código debe distinguir este error (configuración) de un servidor caído.
      - Los tokens de los 9 grupos se mostraron en pantalla durante la clase en directo:
        hay que asumir que cualquier alumno puede publicar en nuestro canal. HMAC y
        anti-repetición son imprescindibles.

  (B) webhook.site (PLAN B si el servidor del profesor cae; datos verificados en
      docs.webhook.site, no inventar más):
      - Crear URL: POST https://webhook.site/token -> el campo "uuid" es el token.
        Límite gratis: 1 token por minuto. Caduca a la semana (expiry máx. 604800 s).
      - Enviar: cualquier método HTTP a https://webhook.site/<uuid> (captura también
        subrutas y query string).
      - Leer: GET https://webhook.site/token/<uuid>/requests con sorting=oldest|newest,
        per_page (máx. 100), page, date_from/date_to ("yyyy-MM-dd HH:mm:ss") y query
        (búsqueda, admite filtros tipo query.canal:ordenes-g4).
        Respuesta: array en .data; cada petición tiene uuid, method, query, content
        (el cuerpo como TEXTO: hay que parsearlo con fromjson), created_at...
      - NO existe "?desde=<id>": el "procesar una sola vez" debe resolverse guardando los
        uuid / id_orden ya procesados en un fichero de estado.
      - No hay canales: o un token por canal (ordenes-g4 y respuestas-g4) o un único
        token con ?canal=... en la URL. El debate debe elegir y justificar.
      - Límite de lectura: 120 consultas/min. Sondear cada 2 s = 30/min por proceso.
      - La documentación no aclara si leer un token anónimo exige clave: hay que asumir
        que CUALQUIERA que conozca la URL puede leer y ESCRIBIR órdenes. Esto hace que la
        firma HMAC y la anti-repetición sean imprescindibles, no decorativas.
- Entregables: scripts .sh con cabecera, README.md (cómo ejecutar y ejemplos del JSON
  enviado), prompts.md (prompts usados con la IA y qué se corrigió del código generado),
  y demo en vivo de 3–4 minutos.

=== ENUNCIADO OFICIAL (Ejercicio 5) ===
Bot ChatOps con lista blanca de órdenes.
Scripts: bot.sh (ejecuta) y orden.sh (cliente).
Canales: ordenes-gN y respuestas-gN (N = número de grupo; aquí N = 4).

Contexto: un bot escucha órdenes en JSON que llegan por webhook, ejecuta solo las
acciones permitidas y publica el resultado también en JSON. Es el patrón ChatOps y, a la
vez, un ejercicio de seguridad: un bot mal hecho es una puerta trasera que ejecuta
cualquier comando.

Contrato JSON de la orden:
{ "id_orden": "a1b2c3", "de": "profesor", "accion": "ping",
  "args": { "objetivo": "192.168.56.1" }, "ts": "2026-11-17T11:30:00Z" }

Contrato JSON de la respuesta:
{ "id_orden": "a1b2c3", "bot": "kali-g5", "estado": "ok", "codigo_salida": 0,
  "salida": "4 packets transmitted, 4 received...", "duracion_ms": 3021,
  "ts": "2026-11-17T11:30:03Z" }
estado puede ser ok, error o rechazada.

Requisitos mínimos (fase 1):
- bot.sh consulta ordenes-gN cada 2 segundos y procesa cada orden nueva una sola vez.
- Acciones permitidas, implementadas con case (nunca con eval ni pasando el texto
  recibido a bash -c):
  · ping: 4 paquetes a objetivo, que debe ser una IP o un nombre de host válido
    (validar con expresión regular).
  · estado: uptime, memoria y disco del equipo, devueltos como JSON.
  · puertos: puertos en escucha con ss -tuln, convertidos a array JSON.
  · ayuda: lista de acciones disponibles.
- Cualquier otra acción o argumento no válido se responde con "estado": "rechazada" y
  el motivo.
- Cada ejecución con timeout 10 y la salida recortada a 2000 caracteres.
- orden.sh <accion> [objetivo] genera un id_orden aleatorio, envía la orden y espera
  hasta 15 segundos la respuesta con ese mismo id.

Ampliaciones (fase 2, elegir al menos dos). El enunciado ofrece:
- Firma HMAC: campo firma = HMAC-SHA256 del JSON canónico sin ese campo
  (jq -cS 'del(.firma)' y openssl dgst -sha256 -hmac "$CLAVE"). El bot rechaza las
  órdenes sin firma o con firma incorrecta.
- Anti-repetición: rechazar órdenes con más de 60 s de antigüedad o con un id_orden
  ya visto.
- Límite de frecuencia: máximo 5 órdenes por minuto por remitente.
- Registro de auditoría en auditoria.jsonl (orden recibida, decisión y resultado).
- Nueva acción dns con dig +short, validando el dominio.
PROPUESTA INICIAL DEL GRUPO (debatible): HMAC + anti-repetición + límite de frecuencia
+ auditoría. dns solo si no añade riesgo de tiempo.

Pistas del profesor: revisar inyección de comandos; diferencia entre ping "$objetivo" y
ping $objetivo; ids con openssl rand -hex 4.

Criterio de "hecho": el profesor envía en la demo una orden con un objetivo como
8.8.8.8; id   o   $(whoami)   y el bot la rechaza sin ejecutar nada; las órdenes
legítimas devuelven su respuesta en menos de 15 segundos.

=== PUNTOS QUE EL DEBATE DEBE RESOLVER EXPLÍCITAMENTE ===
(No son requisitos nuevos: son riesgos que el prompt final debe cubrir.)
P1. Inyección de ARGUMENTOS, no solo de comandos: objetivos que empiezan por "-"
    (p. ej. "-f" o "-c 100000") deben rechazarse.
P2. Regex exacta para IP y nombre de host: qué se acepta, qué no, y casos de prueba.
P3. "Procesar cada orden una sola vez": dónde se guarda el estado (fichero), qué pasa
    si el bot se reinicia.
P4. HMAC: forma canónica idéntica en orden.sh y bot.sh; la clave por variable de
    entorno, nunca escrita en el código ni en el repositorio; qué pasa si CLAVE no está
    definida.
P5. Anti-repetición: tolerancia de reloj entre equipos y cómo se parsea "ts".
P6. Recorte a 2000 caracteres sin romper el JSON ni caracteres multibyte (hacerlo en jq).
P7. Todo JSON recibido es hostil: validarlo con jq antes de usar ningún campo; campos
    ausentes o de tipo incorrecto => "rechazada" con motivo.
P8. Cierre limpio con trap (Ctrl+C), sin procesos huérfanos.
P9. Webhook caído o lento: curl --max-time, aviso y seguir, sin romper el bot.
P10. Plan de pruebas reproducible: lista de órdenes maliciosas y legítimas con el
     resultado esperado de cada una, incluidas las del criterio "hecho".
P11. Guion de demo de 3–4 minutos.
P12. Inyección de secuencias de terminal: cualquier texto recibido (args, salida de
     comandos) que orden.sh o los logs vayan a imprimir debe limpiarse de caracteres de
     control (p. ej. con jq gsub sobre [\u0000-\u001f\u007f], respetando \n donde haga
     falta), para que nadie pueda borrar la pantalla ni falsear mensajes con ANSI.
P13. Pruebas sin depender del servidor real: un servidor falso local mínimo que imite
     POST /webhook/<token> y GET /sync?since=, con una variable para cambiar la URL
     base. Así se puede probar todo aunque el token o la red fallen.

=== TU PRIMERA TAREA ===
Entrega la RONDA 1 como REDACTOR con la Versión 1 completa del prompt final.
```

---

## Checklist final (para el grupo, antes de dar el prompt por bueno)

- [ ] Están los 4 requisitos de fase 1, cada uno con su forma de comprobarlo.
- [ ] Al menos 2 ampliaciones de fase 2, elegidas por vosotros.
- [ ] Prohíbe `eval`, `bash -c` y variables sin comillas, y exige `case`.
- [ ] La capa de transporte está aislada, sin endpoints inventados.
- [ ] Hay casos de prueba con `8.8.8.8; id`, `$(whoami)` y objetivos que empiezan por `-`.
- [ ] Exige pasar `shellcheck`, cabeceras, `README.md` y `prompts.md`.
- [ ] Ninguna IA ha respondido por vosotros a una PREGUNTA PARA EL GRUPO.
