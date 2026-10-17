#!/usr/bin/env bash
# Mesh gateway setup for the Pi 5 (HOST):
#   tailnet / WireGuard peers -> Apache :80 -> uvicorn 127.0.0.1:PORT
# Run ON THE PI as root:
#   sudo bash pi-mesh-setup.sh ~/myapp [main:app] [port]
# Optional env:
#   WG_SUBNET=10.0.0.0/24   subnet of /etc/wireguard/wg0.conf; enables the
#                           wg0 <-> tailscale0 bridge + Tailscale subnet route
#   WORKERS=2               uvicorn workers (the Pi has 4 GB, keep it low)
#   RUN_AS=abrar            user the app runs as
set -euo pipefail

APP_DIR=${1:?usage: sudo bash pi-mesh-setup.sh APP_DIR [module:app] [port]}
APP=${2:-main:app}
PORT=${3:-8000}
WORKERS=${WORKERS:-2}
RUN_AS=${RUN_AS:-abrar}
WG_SUBNET=${WG_SUBNET:-}
TS_NAME=$(tailscale status --json 2>/dev/null | sed -n 's/.*"DNSName": *"\([^"]*\)\.".*/\1/p' | head -1)
TS_NAME=${TS_NAME:-HOST.ts.net}

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -d "$APP_DIR" ] || { echo "no such app dir: $APP_DIR" >&2; exit 1; }
if ss -ltn "sport = :$PORT" | grep -q LISTEN && ! systemctl is-active -q mesh-uvicorn; then
  echo "port $PORT is already in use; pass another port as the 3rd argument" >&2; exit 1
fi

echo "== 1/4 uvicorn service (127.0.0.1:$PORT)"
if [ ! -x "$APP_DIR/.venv/bin/uvicorn" ]; then
  sudo -u "$RUN_AS" python3 -m venv "$APP_DIR/.venv"
  sudo -u "$RUN_AS" "$APP_DIR/.venv/bin/pip" install -q uvicorn
  [ -f "$APP_DIR/requirements.txt" ] &&
    sudo -u "$RUN_AS" "$APP_DIR/.venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"
fi
cat > /etc/systemd/system/mesh-uvicorn.service <<EOF
[Unit]
Description=Uvicorn app behind the mesh Apache proxy
After=network-online.target

[Service]
User=$RUN_AS
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/uvicorn $APP --host 127.0.0.1 --port $PORT --workers $WORKERS --proxy-headers --forwarded-allow-ips 127.0.0.1
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q mesh-uvicorn
systemctl restart mesh-uvicorn

echo "== 2/4 Apache reverse proxy ($TS_NAME -> 127.0.0.1:$PORT)"
a2enmod -q proxy proxy_http headers >/dev/null
cat > /etc/apache2/sites-available/mesh-uvicorn.conf <<EOF
<VirtualHost *:80>
    ServerName $TS_NAME
    ServerAlias HOST example.lan

    # tailnet (and WireGuard peers, if any) only
    <Location "/">
        Require ip 127.0.0.1 TAILSCALE_IP/10 $WG_SUBNET
    </Location>

    ProxyPreserveHost On
    ProxyPass        "/" "http://127.0.0.1:$PORT/"
    ProxyPassReverse "/" "http://127.0.0.1:$PORT/"
    RequestHeader set X-Forwarded-Proto "http"
</VirtualHost>
EOF
a2ensite -q mesh-uvicorn >/dev/null
apache2ctl -t
systemctl reload apache2 || systemctl restart apache2

echo "== 3/4 kernel forwarding"
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-mesh-router.conf
sysctl -q -p /etc/sysctl.d/99-mesh-router.conf

echo "== 4/4 WireGuard <-> Tailscale bridge"
if [ -n "$WG_SUBNET" ] && [ -f /etc/wireguard/wg0.conf ]; then
  systemctl enable -q --now wg-quick@wg0
  # 'tailscale set' changes one setting; 'tailscale up' would demand every other flag again
  tailscale set --advertise-routes="$WG_SUBNET"
  cat > /etc/systemd/system/mesh-forward.service <<EOF
[Unit]
Description=Forward WireGuard peers into the tailnet
After=wg-quick@wg0.service tailscaled.service
Requires=wg-quick@wg0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iptables -I FORWARD -i wg0 -o tailscale0 -j ACCEPT
ExecStart=/usr/sbin/iptables -I FORWARD -i tailscale0 -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ExecStart=/usr/sbin/iptables -t nat -A POSTROUTING -s $WG_SUBNET -o tailscale0 -j MASQUERADE
ExecStop=/usr/sbin/iptables -D FORWARD -i wg0 -o tailscale0 -j ACCEPT
ExecStop=/usr/sbin/iptables -D FORWARD -i tailscale0 -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ExecStop=/usr/sbin/iptables -t nat -D POSTROUTING -s $WG_SUBNET -o tailscale0 -j MASQUERADE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable -q --now mesh-forward
  echo "   approve the $WG_SUBNET route: https://login.tailscale.com/admin/machines -> HOST -> Edit route settings"
else
  echo "   skipped: needs WG_SUBNET=... and /etc/wireguard/wg0.conf (no WireGuard peer configured yet)"
fi

echo
sleep 2
printf 'uvicorn direct : '; curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$PORT/" || true
printf 'through Apache : '; curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $TS_NAME" http://127.0.0.1/ || true
echo "open from any tailnet device: http://$TS_NAME/"
