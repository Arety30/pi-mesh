# pi-mesh

pi-mesh is a single Bash script by Syed Abrar Ali that turns a Raspberry Pi 5 into a small mesh gateway for a Python web app: it runs the app under uvicorn as a systemd service on localhost, puts an Apache reverse proxy in front of it that only answers to Tailscale (and optionally WireGuard) peers, and, when a WireGuard interface exists, bridges WireGuard clients into the tailnet with IP forwarding, NAT and an advertised subnet route. It removes the repetitive steps of hosting an internal service on a Pi securely without opening any port to the Internet.

## Where it is used

Abrar uses the Pi 5 as an always-on node on his tailnet. `pi-mesh-setup.sh` is how a FastAPI/ASGI app from his other projects gets deployed on it so that his laptop and phone (tailnet members) can reach it at `http://<pi-tailnet-name>/`, and so devices that only speak plain WireGuard can be routed through the Pi onto the tailnet.

## How it works

Invocation: `sudo bash pi-mesh-setup.sh APP_DIR [module:app] [port]` with optional environment variables. Must run as root on the Pi (`set -euo pipefail`; refuses otherwise, refuses a missing app dir, and refuses a port already in use by something other than its own service).

| Input | Default | Meaning |
|-------|---------|---------|
| `APP_DIR` (arg 1) | required | Directory containing the ASGI app |
| `module:app` (arg 2) | `main:app` | uvicorn import string |
| `port` (arg 3) | `8000` | Local port uvicorn binds on 127.0.0.1 |
| `WORKERS` | `2` | uvicorn workers (the Pi has 4 GB RAM) |
| `RUN_AS` | the Pi user | Unix user the service runs as |
| `WG_SUBNET` | empty | e.g. `10.0.0.0/24`; enables step 4 |

Steps:

1. **uvicorn service** - if `APP_DIR/.venv/bin/uvicorn` is missing, create the venv as `RUN_AS`, `pip install uvicorn` and `requirements.txt` if present. Write `/etc/systemd/system/mesh-uvicorn.service` running `uvicorn <module:app> --host 127.0.0.1 --port <port> --workers <n> --proxy-headers --forwarded-allow-ips 127.0.0.1`, enable and restart it.
2. **Apache reverse proxy** - `a2enmod proxy proxy_http headers`; write `/etc/apache2/sites-available/mesh-uvicorn.conf`: a `*:80` vhost whose `ServerName` is the Pi's tailnet DNS name (read from `tailscale status --json`, with a hard-coded fallback) plus short aliases, `Require ip 127.0.0.1 TAILSCALE_IP/10 <WG_SUBNET>` (the `TAILSCALE_IP/10` block is the range Tailscale assigns), `ProxyPass`/`ProxyPassReverse` to the uvicorn port and `X-Forwarded-Proto: http`. Enable the site, `apache2ctl -t`, reload.
3. **Kernel forwarding** - `/etc/sysctl.d/99-mesh-router.conf` with `net.ipv4.ip_forward=1`.
4. **WireGuard <-> Tailscale bridge** (only if `WG_SUBNET` is set and `/etc/wireguard/wg0.conf` exists) - enable `wg-quick@wg0`, run `tailscale set --advertise-routes=<WG_SUBNET>` (not `tailscale up`, which would reset other flags), and install `mesh-forward.service`, a oneshot unit that adds iptables rules: `FORWARD wg0 -> tailscale0 ACCEPT`, the reverse for `RELATED,ESTABLISHED`, and `POSTROUTING MASQUERADE` for the WireGuard subnet leaving via `tailscale0`; `ExecStop` removes them. The script reminds you to approve the advertised route in the Tailscale admin console. Otherwise the step is skipped with a message.

Finally it curls the app directly and through Apache (with the tailnet `Host` header) and prints the URL to open.

Resulting data path: tailnet or WireGuard peer -> Apache `:80` (IP allow-list) -> `127.0.0.1:<port>` uvicorn -> the app.

## Setup

Requirements on the Pi: Debian/Raspberry Pi OS with `apache2`, `python3-venv`, `tailscale` (joined to the tailnet), `curl`, `iptables`, and, for step 4, `wireguard-tools` with a configured `/etc/wireguard/wg0.conf`.

```bash
sudo apt install apache2 python3-venv curl iptables wireguard-tools
git clone <repo-url> ~/pi-mesh
```

Before first use edit the two hard-coded names in the script: the `TS_NAME` fallback (set it to your Pi's tailnet name, e.g. `pi.example.ts.net`) and the `ServerAlias` list in the Apache vhost (e.g. `pi app.example.lan`).

## Usage

```bash
# deploy ~/myapp (FastAPI object `app` in main.py) on port 8000, 2 workers
sudo bash ~/pi-mesh/pi-mesh-setup.sh /home/USER/myapp

# a different module and port, more workers
sudo WORKERS=3 bash ~/pi-mesh/pi-mesh-setup.sh /home/USER/api server:app 8010

# also bridge a WireGuard subnet into the tailnet
sudo WG_SUBNET=10.0.0.0/24 bash ~/pi-mesh/pi-mesh-setup.sh /home/USER/myapp
```

Afterwards, from any tailnet device: `curl http://pi.example.ts.net/`. Useful checks on the Pi:

```bash
systemctl status mesh-uvicorn apache2 mesh-forward
journalctl -u mesh-uvicorn -f
tailscale serve status
```

## Project structure

```
pi-mesh/
└── pi-mesh-setup.sh    # the whole tool
```

## Limitations and notes

- HTTP only on port 80; there is no TLS. Confidentiality comes from the WireGuard/Tailscale tunnels, and the Apache allow-list is the access control.
- `TAILSCALE_IP/10` is the whole Carrier-Grade NAT range; it matches Tailscale addresses but would also match any other CGNAT source if the Pi were on such a network.
- Re-running the script overwrites the service and vhost files; it does not uninstall anything.
- The WireGuard side assumes the interface is named `wg0` and that `wg0.conf` already exists; the script does not generate keys or peers.
- Advertised routes still need manual approval in the Tailscale admin console before WireGuard clients can reach tailnet hosts.
- The venv is created only when `.venv/bin/uvicorn` is absent, so dependency updates in `requirements.txt` are not re-installed automatically.
