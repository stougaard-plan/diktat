#!/usr/bin/env python3
"""Lille Ollama-lookalike til test af oprydningens fejlstier. Alt kører lokalt, ingen sprogmodel.
Stier: /ok (svarer), /hang (svarer aldrig inden for testens timeout), /err500, /empty (tomt svar), /garbage."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        self._send(200, {"models": [{"name": "test-model"}]})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n)
        mode = self.path_mode
        if mode == "hang": time.sleep(30); return
        if mode == "err500": return self._send(500, {"error": "boom"})
        if mode == "empty": return self._send(200, {"response": ""})
        if mode == "garbage": return self._send(200, b"ikke json")
        self._send(200, {"response": "Ryddet tekst."})
    @property
    def path_mode(self): return self.server.mode

mode, port = sys.argv[1], int(sys.argv[2])
s = ThreadingHTTPServer(("0.0.0.0", port), H); s.mode = mode
s.serve_forever()
