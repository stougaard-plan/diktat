#!/usr/bin/env python3
"""Falsk Ollama til test af mødetitlen. Ingen sprogmodel. Lytter kun på 127.0.0.1.
Brug: title_fake_ollama.py <mode> <port> <logfil>
Modes: ok, notdone, think, nothink, hang, err500, garbage, empty, redirect:<port>.
nothink: svarer 400, hvis forespørgslen har think-feltet, ellers ok (til at prøve andet forsøg uden think).
Hver forespørgsel skrives som én JSON-linje til logfilen (sti, vært-header, krop)."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode, port, logfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, headers=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); raw = self.rfile.read(n)
        with open(logfile, "a") as f:
            f.write(json.dumps({"path": self.path, "host": self.headers.get("Host"), "body": json.loads(raw or b"{}")}) + "\n")
        if mode == "hang": time.sleep(60); return
        if mode == "nothink" and "think" in json.loads(raw or b"{}"): return self._send(400, {"error": "think understøttes ikke"})
        if mode == "err500": return self._send(500, {"error": "boom"})
        if mode == "garbage": return self._send(200, b"ikke json")
        if mode == "empty": return self._send(200, {"response": ""})
        if mode.startswith("redirect:"):
            return self._send(302, {}, {"Location": "http://127.0.0.1:%s/api/generate" % mode.split(":")[1]})
        if mode == "notdone": return self._send(200, {"response": "Planlægning af næste møde", "done": False})
        if mode == "think": return self._send(200, {"response": "<think>\nlad mig tænke\n</think>\nFrist for høringssvar til lokalplan"})
        self._send(200, {"response": "Frist for høringssvar til lokalplan"})

s = ThreadingHTTPServer(("127.0.0.1", port), H)
s.serve_forever()
