#!/usr/bin/env bash
# Vast.ai on-start script. Launches ComfyUI, Caddy, and cloudflared,
# restarting any of them if they crash. Logs go to $LOG_DIR.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-/workspace/logs}"
ENV_FILE="$REPO_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
	echo "Missing $ENV_FILE — copy .env.example to .env and fill it in." >&2
	exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${COMFY_USER:?COMFY_USER not set in .env}"
: "${COMFY_PASS_HASH:?COMFY_PASS_HASH not set in .env}"
: "${COMFYUI_DIR:=/workspace/ComfyUI}"

mkdir -p "$LOG_DIR"

# Restart-loop wrapper: keeps a process alive, logging to $LOG_DIR/<name>.log.
run_forever() {
	local name="$1"
	shift
	local logfile="$LOG_DIR/$name.log"
	(
		while true; do
			echo "[$(date -Is)] starting $name: $*" >>"$logfile"
			"$@" >>"$logfile" 2>&1 || true
			echo "[$(date -Is)] $name exited; restarting in 2s" >>"$logfile"
			sleep 2
		done
	) &
}

# 1) ComfyUI — bound to localhost only.
run_forever comfyui bash -c "
	cd '$COMFYUI_DIR' && \
	source .venv/bin/activate && \
	exec python main.py --listen 127.0.0.1 --port 8188
"

# 2) Caddy reverse proxy with basic auth on :8080.
run_forever caddy caddy run --config /etc/caddy/Caddyfile --adapter caddyfile

# 3) Cloudflare tunnel. Three modes:
#    - If a systemd cloudflared service is already active (i.e. installed via
#      `cloudflared service install <token>` from the Cloudflare dashboard),
#      let it run and don't launch a second instance.
#    - Else if TUNNEL_NAME is set, run the named tunnel.
#    - Else fall back to a quick tunnel (random *.trycloudflare.com URL).
if systemctl is-active --quiet cloudflared 2>/dev/null; then
	echo "[$(date -Is)] cloudflared systemd service is active; skipping tunnel launch" \
		>>"$LOG_DIR/tunnel.log"
elif [[ -n "${TUNNEL_NAME:-}" ]]; then
	run_forever tunnel cloudflared tunnel --no-autoupdate run "$TUNNEL_NAME"
else
	run_forever tunnel cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8080
	# Pull the trycloudflare URL out of the log once it appears.
	(
		for _ in $(seq 1 60); do
			url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/tunnel.log" 2>/dev/null | head -n1 || true)"
			if [[ -n "$url" ]]; then
				echo "[$(date -Is)] public URL: $url" | tee -a "$LOG_DIR/tunnel.log"
				break
			fi
			sleep 2
		done
	) &
fi

wait
