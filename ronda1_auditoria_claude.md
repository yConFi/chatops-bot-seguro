## RONDA 1 — AUDITOR (Claude)

### Acuerdos
- Transporte aislado (publicar/consultar) y datos del servidor del profesor correctos: `since`, metadatos `_id/_recibido/_origen`, 403 "token invalido".
- Validación del objetivo muy completa: guion inicial, IPv4 fuera de rango no aceptada como hostname, pruebas positivas y negativas.
- Prueba con fichero testigo para demostrar que la inyección NO se ejecutó: excelente.
- HMAC: reconstruir el objeto con lista de campos permitidos antes de verificar; no confiar en `_recibido`/`_origen`.
- Recorte en jq, limpieza de ANSI y `timeout` sin `bash -c` (modo trabajador).
- Prohibido fabricar resultados de pruebas.

### Objeciones

**B1 — BLOQUEANTE — Las órdenes del profesor no funcionarían.**
El criterio "hecho" dice que es el PROFESOR quien envía la orden. El contrato oficial no tiene `canal` ni `firma`. Con la Versión 1:
(a) una orden oficial sin `canal` se ignora en silencio: el profesor no recibe respuesta y parece que el bot no funciona;
(b) si no tiene la CLAVE, todas sus órdenes, también las legítimas, se rechazan por firma. Eso incumple "las órdenes legítimas devuelven su respuesta".
Cambios:
1. `canal` opcional en las órdenes. Todo mensaje que no sea una respuesta (`canal` = `respuestas-g4` o con campo `bot`) se trata como orden candidata.
2. No ignorar nunca en silencio una orden con `id_orden` válido: responder `rechazada` con el motivo (firma ausente, firma incorrecta, etc.).
3. El README debe explicar cómo dar al profesor `orden.sh` y la CLAVE por fuera del canal.
4. Ver la pregunta 1 para el grupo.

**B2 — BLOQUEANTE — Alcance incompatible con el plazo.**
La demo es hoy, en unas 1,5 h. Además choca con tu propia prioridad 4 y con "los alumnos pueden explicar cada función". Recortes:
- webhook.site: solo un esqueleto de `publicar`/`consultar` con TODO y sus límites documentados. Sin paginación ni persistencia de UUID.
- Eliminar la cola de respuestas pendientes. Si falla la publicación, se registra en auditoría y se sigue.
- Límite de frecuencia: un fichero con marcas de tiempo por remitente es suficiente.
- Mantener `flock` y la escritura atómica con `mktemp` + `mv`, que son pocas líneas.

**B3 — BLOQUEANTE — orden.sh no debe validar el objetivo.**
Solo debe codificarlo con `jq --arg`. Si lo valida o lo limpia, los ataques de la demo nunca llegan al bot y no se demuestra nada.
Para demostrar el rechazo por HMAC hacen falta opciones explícitas de prueba, por ejemplo `--sin-firma` y `--firma-falsa`, o un `pruebas.sh`. Documentar que son solo para pruebas.

**I1 — IMPORTANTE — Pedirlo todo en una sola respuesta.**
Las secciones A–G con 5 o más archivos completos en una respuesta acaban cortadas o con "resto igual". Dividirlo en 3 mensajes y esperar a que el grupo escriba "CONTINÚA" entre cada uno:
(1) bot.sh y orden.sh;
(2) servidor falso, pruebas.sh y README.md;
(3) prompts.md, checklist y revisión de seguridad.

**I2 — IMPORTANTE — Inundación o mensajes enormes en el canal.**
No conocemos la paginación del servidor, y cualquiera con el token puede publicar. Hay que:
- limitar el tamaño de lo que devuelve /sync (`curl --max-filesize`);
- limitar cuántos mensajes se procesan por ciclo;
- descartar los mensajes de más de N bytes antes de pasarlos por jq.

**I3 — IMPORTANTE — Política de arranque.**
Empezar desde el `last_id` actual es correcto. Pero si el bot arranca después de que el profesor envíe la orden, se la salta. El guion de la demo debe arrancar el bot antes de que el profesor envíe nada.

**M1 — MENOR — Python 3 no es un supuesto.** El propio enunciado usa `python3 -m http.server` en los ejercicios 2 y 4. Quitar la marca [SUPUESTO].

**M2 — MENOR — Cabecera "autores".** Usar un marcador `[NOMBRE_1..5]` si el grupo no da los nombres.

**M3 — MENOR — Formato.** No has seguido el formato R5 (Acuerdos, Objeciones, Cambios…). Respétalo en la ronda 2.

**M4 — MENOR — Firma de las respuestas.** Mantenerla: los tokens se vieron en clase y cualquiera puede publicar respuestas falsas. Pero reutilizando las mismas funciones `firmar()` y `verificar()`.

### PREGUNTAS PARA EL GRUPO
1. ¿Cómo enviará Carlos las órdenes en la demo? ¿Le pasáis `orden.sh` y la CLAVE, o usa su propia herramienta?
2. ¿Cómo se llaman los 5 autores, para las cabeceras?
3. En `estado` y `puertos`, ¿`salida` es una cadena con JSON dentro o un objeto/array? Si nadie lo sabe, se queda como cadena.
4. ¿Hace falta IPv6? Propuesta: no.

ESTADO: HAY OBJECIONES BLOQUEANTES

---

### RESPUESTAS DEL GRUPO A LAS PREGUNTAS
1. No sabemos cómo enviará Carlos las órdenes. Decisión del grupo:
   - Variable `EXIGIR_FIRMA` con valor 1 por defecto: las órdenes sin firma o con firma incorrecta se responden `rechazada` con el motivo, nunca se ignoran en silencio.
   - Si en la demo Carlos envía órdenes sin firmar con su propia herramienta, arrancamos el bot con `EXIGIR_FIRMA=0`. En ese caso la validación de acción y argumentos sigue protegiendo igual. El bot lo avisa al arrancar y lo registra en auditoría.
   - El README explica cómo darle `orden.sh` y la CLAVE fuera del canal, si las quiere usar.
2. Autores: Pol, Fran, Javi, Yeray y Ricardo (Grupo 4).
3. `salida` siempre como cadena, igual que en el ejemplo oficial de respuesta. En `estado` y `puertos`, esa cadena contiene JSON compacto y válido. `orden.sh` intenta `fromjson` para mostrarlo bonito y, si falla, lo enseña como texto limpio de caracteres de control. Motivo: un único tipo por campo, el mismo en todo el contrato.
4. IPv6: no. Solo IPv4 y nombres de host ASCII.

### INSTRUCCIÓN PARA EL REDACTOR
Entrega la RONDA 2 con el formato R5 y la Versión 2 COMPLETA del prompt, aplicando B1–B3, I1–I3 y M1–M4. Será la versión FINAL salvo que el auditor encuentre algo bloqueante.
