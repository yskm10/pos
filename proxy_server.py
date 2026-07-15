#!/usr/bin/env python3
"""
POSプロキシサーバー
- pos.htmlを配信（ポート8080）
- /printer/ へのリクエストをプリンターに中継（CORSを回避）
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import urllib.request
import urllib.error
import os

PRINTER_IP   = "192.168.10.168"
PRINTER_PORT = 9100
HTML_DIR     = os.path.dirname(os.path.abspath(__file__))

class ProxyHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{self.address_string()}] {format % args}")

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors()
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/" or path == "/pos.html":
            self._serve_file("pos.html")
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path.startswith("/printer"):
            self._proxy_printer()
        else:
            self.send_error(404)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin",  "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, SOAPAction")

    def _serve_file(self, filename):
        filepath = os.path.join(HTML_DIR, filename)
        try:
            with open(filepath, "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self._cors()
            self.end_headers()
            self.wfile.write(data)
        except FileNotFoundError:
            self.send_error(404, f"{filename} not found")

    def _proxy_printer(self):
        length = int(self.headers.get("Content-Length", 0))
        body   = self.rfile.read(length) if length > 0 else b""
        url    = f"http://{PRINTER_IP}:{PRINTER_PORT}/cgi-bin/epos/service.cgi?devid=local_printer&timeout=5000"
        req = urllib.request.Request(
            url, data=body, method="POST",
            headers={
                "Content-Type": "text/xml; charset=utf-8",
                "SOAPAction":   '""',
            }
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                resp_body = resp.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/xml; charset=utf-8")
            self.send_header("Content-Length", str(len(resp_body)))
            self._cors()
            self.end_headers()
            self.wfile.write(resp_body)
        except Exception as e:
            print(f"Printer error: {e}")
            self.send_response(502)
            self._cors()
            self.end_headers()

if __name__ == "__main__":
    server = HTTPServer(("", 8080), ProxyHandler)
    print("=" * 40)
    print(" POSプロキシサーバー起動中")
    print(" ポート: 8080")
    print(f" プリンター: {PRINTER_IP}:{PRINTER_PORT}")
    print(" ブラウザで開く:")
    print("   http://192.168.10.171:8080/pos.html")
    print("=" * 40)
    server.serve_forever()
