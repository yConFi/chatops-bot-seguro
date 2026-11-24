#!/usr/bin/env python3
"""
servidor_falso.py — Imitación LOCAL del servidor del profesor (SOLO PARA PRUEBAS)

Autores : Pol, Fran, Javi, Yeray, Ricardo — Grupo 4
          Máster de Ciberseguridad & IA (Evolve)

Imita únicamente lo verificado del servidor real:
  POST /webhook/<token>   403 {"ok":false,"error":"token invalido"} si el token no coincide;
                          si coincide, guarda el JSON añadiendo _id, _recibido y _origen
                          y responde 200 {"ok":true,"project":"pr4","received":{...}}.
  GET  /sync              {"project":"pr4","count":N,"last_id":N,"messages":[...]}
  GET  /sync?since=N      solo los mensajes con _id > N. Si N es mayor que el último _id,
                          last_id = N (observado en el real el 2026-11-24 con
                          since=999999999999999: devolvió last_id 999999999999999).
  Al arrancar existe un mensaje basura (_id 1, "canal":"prueba"), como en el real.

Diferencias con el servidor real (decisiones nuestras, NO comprobadas en el real):
  - Un solo puerto para /webhook y /sync (el real usa 9004 y 8084).
  - Escucha solo en 127.0.0.1 y guarda los mensajes en memoria: al reiniciarlo
    los _id vuelven a empezar.
  - JSON inválido o raíz que no es objeto → 400 {"ok":false,"error":"json invalido"}.
  - Cuerpo > 1 MB → 413. Sin paginación.
  - Sobrescribe siempre _id, _recibido y _origen (en el real es DESCONOCIDO).
  - "count" = número de mensajes devueltos en esa respuesta (en el real no se sabe).
  - Ganchos solo de pruebas (no existen en el real):
      POST /_pruebas/romper_sync/<token>  el siguiente GET /sync devuelve JSON roto.
      POST /_pruebas/envenenar/<token>    guarda un mensaje "envenenado": todo /sync
                                          que lo incluya sale con JSON inválido (simula
                                          un mensaje que jq no puede procesar). Los que
                                          no lo incluyen (since >= su _id) salen bien.
      POST /_pruebas/fallar_respuesta/<token>  el siguiente POST que sea una respuesta
                                          (lleva "bot") recibe 500 y no se guarda.

Uso:
  export TOKEN_G4='token-de-pruebas'
  python3 servidor_falso.py [--puerto 8099]
  export URL_WEBHOOK=http://127.0.0.1:8099/webhook
  export URL_SYNC=http://127.0.0.1:8099/sync
"""

import argparse
import hmac
import json
import os
import re
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

MAX_CUERPO = 1_000_000
MARCA_VENENO = "_veneno_pruebas"   # clave interna del gancho /_pruebas/envenenar
RE_SINCE = re.compile(r"[0-9]{1,15}")


def ahora_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Almacen:
    """Lista de mensajes en memoria, protegida con un cerrojo (servidor con hilos)."""

    def __init__(self) -> None:
        self._cerrojo = threading.Lock()
        self._mensajes: list[dict] = []
        self._ultimo_id = 0
        self.romper_proximo_sync = False
        self.fallar_proxima_respuesta = False

    def guardar(self, obj: dict, origen: str) -> dict:
        with self._cerrojo:
            self._ultimo_id += 1
            mensaje = dict(obj)
            mensaje["_id"] = self._ultimo_id
            mensaje["_recibido"] = ahora_utc()
            mensaje["_origen"] = origen
            self._mensajes.append(mensaje)
            return mensaje

    def desde(self, since: int) -> tuple[list[dict], int]:
        with self._cerrojo:
            return [m for m in self._mensajes if m["_id"] > since], self._ultimo_id


ALMACEN = Almacen()
TOKEN = ""


class Manejador(BaseHTTPRequestHandler):
    server_version = "ServidorFalsoG4/1.0"

    # --- utilidades -----------------------------------------------------------
    def _ruta_segura(self) -> str:
        """Ruta para el log SIN el token."""
        ruta = urlsplit(self.path).path
        if ruta.startswith("/webhook/"):
            return "/webhook/***"
        if ruta.startswith("/_pruebas/romper_sync/"):
            return "/_pruebas/romper_sync/***"
        if ruta.startswith("/_pruebas/envenenar/"):
            return "/_pruebas/envenenar/***"
        if ruta.startswith("/_pruebas/fallar_respuesta/"):
            return "/_pruebas/fallar_respuesta/***"
        return ruta

    def log_message(self, format: str, *args) -> None:  # noqa: A002 (firma de la clase base)
        # La línea por defecto incluye la URL completa (con el token): no se usa.
        sys.stderr.write(f"[falso] {ahora_utc()} {self.command} {self._ruta_segura()}\n")

    def _enviar(self, codigo: int, cuerpo) -> None:
        datos = cuerpo if isinstance(cuerpo, bytes) else json.dumps(cuerpo, ensure_ascii=False).encode()
        self.send_response(codigo)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(datos)))
        self.end_headers()
        self.wfile.write(datos)

    def _token_valido(self, recibido: str) -> bool:
        return hmac.compare_digest(recibido.encode(), TOKEN.encode())

    # --- POST -----------------------------------------------------------------
    def do_POST(self) -> None:  # noqa: N802 (nombre impuesto por http.server)
        ruta = urlsplit(self.path).path

        if ruta.startswith("/_pruebas/romper_sync/"):
            if not self._token_valido(ruta[len("/_pruebas/romper_sync/"):]):
                self._enviar(403, {"ok": False, "error": "token invalido"})
                return
            ALMACEN.romper_proximo_sync = True
            self._enviar(200, {"ok": True, "prueba": "el siguiente /sync devolverá JSON roto"})
            return

        if ruta.startswith("/_pruebas/envenenar/"):
            if not self._token_valido(ruta[len("/_pruebas/envenenar/"):]):
                self._enviar(403, {"ok": False, "error": "token invalido"})
                return
            mensaje = ALMACEN.guardar({"canal": "prueba", MARCA_VENENO: True}, self.client_address[0])
            self._enviar(200, {"ok": True, "_id": mensaje["_id"]})
            return

        if ruta.startswith("/_pruebas/fallar_respuesta/"):
            if not self._token_valido(ruta[len("/_pruebas/fallar_respuesta/"):]):
                self._enviar(403, {"ok": False, "error": "token invalido"})
                return
            ALMACEN.fallar_proxima_respuesta = True
            self._enviar(200, {"ok": True, "prueba": "la siguiente respuesta recibirá 500"})
            return

        if not ruta.startswith("/webhook/"):
            self._enviar(404, {"ok": False, "error": "no encontrado"})
            return
        if not self._token_valido(ruta[len("/webhook/"):]):
            self._enviar(403, {"ok": False, "error": "token invalido"})
            return

        try:
            longitud = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            longitud = -1
        if longitud < 0 or longitud > MAX_CUERPO:
            self._enviar(413, {"ok": False, "error": "cuerpo demasiado grande"})
            return

        cuerpo = self.rfile.read(longitud)
        try:
            obj = json.loads(cuerpo)
        except (ValueError, UnicodeDecodeError):
            obj = None
        if not isinstance(obj, dict):
            self._enviar(400, {"ok": False, "error": "json invalido"})
            return
        obj.pop(MARCA_VENENO, None)   # solo el gancho de pruebas puede envenenar
        if "bot" in obj and ALMACEN.fallar_proxima_respuesta:
            ALMACEN.fallar_proxima_respuesta = False
            self._enviar(500, {"ok": False, "error": "fallo simulado (gancho de pruebas)"})
            return

        mensaje = ALMACEN.guardar(obj, self.client_address[0])
        self._enviar(200, {"ok": True, "project": "pr4", "received": mensaje})

    # --- GET ------------------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        partes = urlsplit(self.path)
        if partes.path != "/sync":
            self._enviar(404, {"ok": False, "error": "no encontrado"})
            return

        since_txt = parse_qs(partes.query).get("since", ["0"])[0]
        if not RE_SINCE.fullmatch(since_txt):
            self._enviar(400, {"ok": False, "error": "since invalido"})
            return

        if ALMACEN.romper_proximo_sync:
            ALMACEN.romper_proximo_sync = False
            self._enviar(200, b'{"project":"pr4","messages":[{"esto no es json')
            return

        mensajes, ultimo = ALMACEN.desde(int(since_txt))
        ultimo = max(ultimo, int(since_txt))   # como el real: last_id nunca es menor que since
        cuerpo = json.dumps({"project": "pr4", "count": len(mensajes),
                             "last_id": ultimo, "messages": mensajes}, ensure_ascii=False).encode()
        if any(m.get(MARCA_VENENO) is True for m in mensajes):
            # Rompe el JSON justo en el mensaje envenenado: "true" → "tru".
            cuerpo = cuerpo.replace(b'"' + MARCA_VENENO.encode() + b'": true',
                                    b'"' + MARCA_VENENO.encode() + b'": tru')
        self._enviar(200, cuerpo)


def main() -> int:
    global TOKEN
    analizador = argparse.ArgumentParser(description="Servidor falso local (solo pruebas).")
    analizador.add_argument("--puerto", type=int, default=8099)
    args = analizador.parse_args()

    TOKEN = os.environ.get("TOKEN_G4", "")
    if not TOKEN:
        print("ERROR: define TOKEN_G4 en el entorno.", file=sys.stderr)
        return 1

    # Mensaje basura inicial, como en el servidor real.
    ALMACEN.guardar({"canal": "prueba", "texto": "mensaje basura inicial"}, "127.0.0.1")

    servidor = ThreadingHTTPServer(("127.0.0.1", args.puerto), Manejador)
    print(f"[falso] escuchando en http://127.0.0.1:{args.puerto} (/webhook/<token> y /sync). "
          "SOLO PRUEBAS.", file=sys.stderr)
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        servidor.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
