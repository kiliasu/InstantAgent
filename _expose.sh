
# ---- Public exposure (EXPOSE=1) ----
# Cloudflare tunnel + bearer-token proxy
if [ "${EXPOSE:-0}" = 1 ]; then
  step tunnel

  if ! command -v cloudflared >/dev/null 2>&1; then
    curl -fsSL -o /usr/local/bin/cloudflared \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x /usr/local/bin/cloudflared
  fi

  if [ ! -f /root/.codex/api_token ]; then
    head -c 24 /dev/urandom | base64 | tr -d '/+=' > /root/.codex/api_token
  fi
  PROXY_TOKEN="$(cat /root/.codex/api_token)"

  cat > /root/auth_proxy.py <<'PYEOF'
import http.server, os, socketserver, urllib.error, urllib.request

TOKEN    = os.environ["PROXY_TOKEN"]
UPSTREAM = "http://127.0.0.1:" + os.environ.get("UPSTREAM_PORT", "11434")
BLOCKED  = ("/api/delete", "/api/create", "/api/pull", "/api/push", "/api/copy")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def _relay(self, method):
        if self.headers.get("Authorization", "") != "Bearer " + TOKEN:
            self.send_response(401); self.end_headers()
            self.wfile.write(b'{"error":"unauthorized"}'); return
        if any(self.path.startswith(p) for p in BLOCKED):
            self.send_response(403); self.end_headers()
            self.wfile.write(b'{"error":"endpoint disabled"}'); return

        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        req = urllib.request.Request(UPSTREAM + self.path, data=body, method=method)
        for k, v in self.headers.items():
            if k.lower() not in ("host", "authorization", "content-length", "connection"):
                req.add_header(k, v)
        try:
            resp = urllib.request.urlopen(req, timeout=3600)
        except urllib.error.HTTPError as e:
            resp = e
        except Exception as e:
            self.send_response(502); self.end_headers()
            self.wfile.write(str(e).encode()); return

        self.send_response(resp.status)
        for k, v in resp.headers.items():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.end_headers()
        try:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):  self._relay("GET")
    def do_POST(self): self._relay("POST")
    def do_HEAD(self): self._relay("HEAD")

    def log_message(self, *a):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


Server(("127.0.0.1", 11500), Handler).serve_forever()
PYEOF

  if ! pgrep -f auth_proxy.py >/dev/null 2>&1; then
    PROXY_TOKEN="$PROXY_TOKEN" UPSTREAM_PORT="$PORT" \
      nohup python3 /root/auth_proxy.py >/var/log/auth_proxy.log 2>&1 &
    sleep 2
  fi

  # Reuse a live tunnel
  PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' \
    /var/log/cloudflared.log 2>/dev/null | head -1 || true)"
  if pgrep -x cloudflared >/dev/null 2>&1 && [ -n "$PUBLIC_URL" ]; then
    step tunnel_reuse
  else
    pkill -x cloudflared 2>/dev/null || true
    sleep 1
    rm -f /var/log/cloudflared.log
    nohup cloudflared tunnel --url http://127.0.0.1:11500 --no-autoupdate \
      >/var/log/cloudflared.log 2>&1 &

    PUBLIC_URL=""
    for _ in $(seq 1 60); do
      PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' \
        /var/log/cloudflared.log 2>/dev/null | head -1 || true)"
      [ -n "$PUBLIC_URL" ] && break
      sleep 1
    done
  fi

  if [ -n "$PUBLIC_URL" ]; then
    ok tunnel_ok
  else
    fail tunnel_fail
    tail -3 /var/log/cloudflared.log
  fi
fi
