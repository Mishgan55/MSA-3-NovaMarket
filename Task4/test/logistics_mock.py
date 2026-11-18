"""Мок логистического провайдера для проверки circuit breaker.

Порт 80 — API провайдера, порт 9000 — управление: GET /mode/ok | /mode/slow | /mode/error.
Каждый запрос к API пишется в лог, чтобы было видно, какие вызовы реально дошли до провайдера.
"""
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = {"mode": "ok"}
SLOW_SECONDS = 5


class ApiHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        mode = state["mode"]
        print(f"logistics: {self.path} mode={mode}", flush=True)

        if mode == "slow":
            time.sleep(SLOW_SECONDS)

        if mode == "error":
            self.reply(500, '{"error":"internal"}')
            return

        self.reply(200, '{"trackingNumber":"NM-0001","status":"IN_TRANSIT"}')

    def reply(self, status, body):
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body.encode())
        except BrokenPipeError:
            # nginx уже закрыл соединение по таймауту — отвечать некому
            pass

    def log_message(self, *args):
        pass


class ControlHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        state["mode"] = self.path.rsplit("/", 1)[-1]
        print(f"control: mode -> {state['mode']}", flush=True)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


threading.Thread(target=ThreadingHTTPServer(("", 9000), ControlHandler).serve_forever, daemon=True).start()
ThreadingHTTPServer(("", 80), ApiHandler).serve_forever()
