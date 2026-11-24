# Resultados de pruebas.sh (servidor FALSO)

Fecha: 2026-11-24T20:58:34Z · Máquina: Linux 6.6.87.2-microsoft-standard-WSL2 x86_64

| Caso | Esperado | Obtenido | Resultado |
|---|---|---|---|
| ping 8.8.8.8 (necesita Internet) | ok | ok | PASA |
| ping localhost | ok | ok | PASA |
| estado (JSON válido en salida) | ok+json | ok+json | PASA |
| puertos (JSON válido en salida) | ok+json | ok+json | PASA |
| ayuda (JSON válido en salida) | ok+json | ok+json | PASA |
| acción 'borrar' | rechazada | rechazada | PASA |
| accion numérica (firmada) | rechazada | rechazada | PASA |
| args de tipo cadena (firmada) | rechazada | rechazada | PASA |
| clave extra (firmada) | rechazada | rechazada | PASA |
| ping 8.8.8.8\;\ id | rechazada | rechazada | PASA |
| ping \$\(whoami\) | rechazada | rechazada | PASA |
| ping -f | rechazada | rechazada | PASA |
| ping -c\ 100000 | rechazada | rechazada | PASA |
| ping 999.999.999.999 | rechazada | rechazada | PASA |
| ping 8.8.8.8\ 8.8.4.4 | rechazada | rechazada | PASA |
| ping $'8.8.8.8\nid' | rechazada | rechazada | PASA |
| ping $'\E[31m8.8.8.8' | rechazada | rechazada | PASA |
| ping 8.8.8.8\;\ echo\ pwned\ \>\ /tmp/pruebas_g4.8kf7hT/testigo.txt | rechazada | rechazada | PASA |
| ping \$\(touch\ /tmp/pruebas_g4.8kf7hT/pwned\) | rechazada | rechazada | PASA |
| ping \`touch\ /tmp/pruebas_g4.8kf7hT/pwned\` | rechazada | rechazada | PASA |
| ping 8.8.8.8\ \&\&\ touch\ /tmp/pruebas_g4.8kf7hT/pwned | rechazada | rechazada | PASA |
| ping 8.8.8.8\ \\|\ touch\ /tmp/pruebas_g4.8kf7hT/pwned | rechazada | rechazada | PASA |
| fichero testigo tras los ataques | intacto | intacto | PASA |
| fichero pwned tras los ataques | no_existe | no_existe | PASA |
| /sync con JSON mal formado | ignorado+vivo | ignorado+vivo | PASA |
| mensaje > 4 KB (respuestas, auditoría +1) | 0,+1 | 0,+1 | PASA |
| id_orden no válido (sin respuesta, auditado) | 0,+1 | 0,+1 | PASA |
| --sin-firma | rechazada | rechazada | PASA |
| --firma-falsa | rechazada | rechazada | PASA |
| orden alterada tras firmar | rechazada | rechazada | PASA |
| misma orden enviada dos veces | ok,rechazada | ok,rechazada | PASA |
| --ts-viejo | rechazada | rechazada | PASA |
| 6 órdenes en un minuto (mismo 'de') | ok,ok,ok,ok,ok,rechazada | ok,ok,ok,ok,ok,rechazada | PASA |
| canal 'prueba' (respuestas, auditoría) | 0,0 | 0,0 | PASA |
| canal 'respuestas-g4' (respuestas del bot) | 0 | 0 | PASA |
| puertos con 90 líneas en ss | recortada+json | recortada+json | PASA |
| respuesta falsa con nuestro id | no_aceptada | no_aceptada | PASA |
| reinicio: continúa desde el cursor | si | si | PASA |
| sin firma con EXIGIR_FIRMA=0 (+aviso) | ok+1 | ok+1 | PASA |
| firma falsa con EXIGIR_FIRMA=0 | rechazada | rechazada | PASA |
| ninguna orden ejecutada dos veces | 0 | 0 | PASA |
| token incorrecto (rc, mensaje 403) | 2+403 | 2+403 | PASA |
| SIGINT: cierre limpio sin huérfanos | si | si | PASA |
| bot.sh sin CLAVE (rc, mensaje) | 1+falta_clave | 1+falta_clave | PASA |
| orden.sh sin CLAVE (rc, mensaje) | 2+falta_clave | 2+falta_clave | PASA |
| ping colgado → timeout | error+124 | error+124 | PASA |
| duracion_ms real (entre 10 y 15 s) | si | si | PASA |
| auditoría (líneas, decisión, publicada) y respuestas | 1+ejecutada+false;0 | 1+ejecutada+false;0 | PASA |
| orden siguiente tras el fallo | ok | ok | PASA |
| salida con ESC y BEL mostrada sin controles | limpia | limpia | PASA |
| el bot salta el mensaje envenenado (auditado) | 1 | 1 | PASA |
| orden legítima tras el veneno | ok | ok | PASA |
| el bot sigue vivo tras el veneno | si | si | PASA |
| orden.sh con servidor caído (rc) | 4 | 4 | PASA |
| el bot sigue vivo con el servidor caído | si | si | PASA |
| ficheros que contienen CLAVE o TOKEN_G4 | 0 | 0 | PASA |

Total: 56 PASA · 0 FALLA
