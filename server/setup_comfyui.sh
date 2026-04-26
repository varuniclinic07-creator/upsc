#!/usr/bin/env bash
# One-shot installer for ComfyUI + Caddy + cloudflared on a Vast.ai box.
# Idempotent: re-running skips work that's already done.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
LOG_DIR="${LOG_DIR:-/workspace/logs}"

log() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }

require_root() {
	if [[ $EUID -ne 0 ]]; then
		echo "This script must be run as root (Vast.ai default user is root)." >&2
		exit 1
	fi
}

apt_install_base() {
	log "Installing apt base packages"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -y
	apt-get install -y --no-install-recommends \
		git curl ca-certificates gnupg lsb-release \
		python3 python3-venv python3-pip \
		debian-keyring debian-archive-keyring apt-transport-https
}

install_caddy() {
	if command -v caddy >/dev/null 2>&1; then
		log "Caddy already installed: $(caddy version | head -n1)"
		return
	fi
	log "Installing Caddy"
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
		| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
		| tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
	apt-get update -y
	apt-get install -y caddy
	systemctl disable --now caddy 2>/dev/null || true
}

install_cloudflared() {
	if command -v cloudflared >/dev/null 2>&1; then
		log "cloudflared already installed: $(cloudflared --version | head -n1)"
		return
	fi
	log "Installing cloudflared"
	mkdir -p --mode=0755 /usr/share/keyrings
	curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
		| tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
	echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
		| tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
	apt-get update -y
	apt-get install -y cloudflared
}

clone_comfyui() {
	if [[ -d "$COMFYUI_DIR/.git" ]]; then
		log "ComfyUI already cloned at $COMFYUI_DIR — pulling"
		git -C "$COMFYUI_DIR" pull --ff-only || true
	else
		log "Cloning ComfyUI to $COMFYUI_DIR"
		mkdir -p "$(dirname "$COMFYUI_DIR")"
		git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
	fi
}

install_python_deps() {
	log "Setting up ComfyUI Python venv"
	python3 -m venv "$COMFYUI_DIR/.venv"
	# shellcheck disable=SC1091
	source "$COMFYUI_DIR/.venv/bin/activate"
	pip install --upgrade pip wheel

	# Pick a PyTorch wheel that ships kernels for this GPU's compute
	# capability. Compute capability — not CUDA version — is what determines
	# whether torch's prebuilt kernels run; the cu1XX index only controls
	# which CUDA runtime is bundled in the wheel and is forward-compatible
	# with newer host drivers. RTX 50-series (Blackwell, sm_120) needs cu128.
	local cuda_idx_url=""
	if ! command -v nvidia-smi >/dev/null 2>&1; then
		log "nvidia-smi not found — installing CPU-only torch (ComfyUI will be slow!)"
		cuda_idx_url="https://download.pytorch.org/whl/cpu"
	else
		local compute_cap cap_major cap_minor cap_int
		compute_cap="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
		cap_major="${compute_cap%%.*}"
		cap_minor="${compute_cap##*.}"
		if [[ "$cap_major" =~ ^[0-9]+$ && "$cap_minor" =~ ^[0-9]+$ ]]; then
			cap_int=$(( cap_major * 10 + cap_minor ))
			if   (( cap_int >= 120 )); then cuda_idx_url="https://download.pytorch.org/whl/cu128"   # Blackwell (RTX 50xx)
			elif (( cap_int >= 80  )); then cuda_idx_url="https://download.pytorch.org/whl/cu124"   # Ampere/Ada/Hopper
			elif (( cap_int >= 70  )); then cuda_idx_url="https://download.pytorch.org/whl/cu121"   # Volta/Turing
			elif (( cap_int >= 60  )); then cuda_idx_url="https://download.pytorch.org/whl/cu118"   # Pascal
			else                            cuda_idx_url="https://download.pytorch.org/whl/cpu"     # too old for modern torch
			fi
			log "Detected GPU compute capability ${compute_cap}; using $cuda_idx_url"
		else
			# Fallback: parse CUDA version from nvidia-smi banner.
			local cuda_ver
			cuda_ver="$(nvidia-smi | grep -oE 'CUDA Version: [0-9]+\.[0-9]+' | awk '{print $3}' | head -n1 || true)"
			case "${cuda_ver%%.*}" in
				13) cuda_idx_url="https://download.pytorch.org/whl/cu128" ;;
				12) cuda_idx_url="https://download.pytorch.org/whl/cu124" ;;
				11) cuda_idx_url="https://download.pytorch.org/whl/cu118" ;;
				*)  cuda_idx_url="https://download.pytorch.org/whl/cu124" ;;
			esac
			log "Could not read compute_cap; falling back to CUDA ${cuda_ver:-unknown} → $cuda_idx_url"
		fi
	fi

	pip install --index-url "$cuda_idx_url" torch torchvision torchaudio
	pip install -r "$COMFYUI_DIR/requirements.txt"

	# Sanity check: confirm torch can see the GPU and built-in kernels match.
	# Non-fatal — we only warn, since CPU installs will legitimately fail this.
	if [[ "$cuda_idx_url" != *"/cpu" ]]; then
		if ! python - <<-'PY'
			import sys, torch
			if not torch.cuda.is_available():
			    print("torch built but CUDA not available; check driver", file=sys.stderr)
			    sys.exit(1)
			cap = torch.cuda.get_device_capability(0)
			x = torch.randn(64, 64, device="cuda")
			(x @ x).sum().item()  # forces a kernel launch
			print(f"torch {torch.__version__} OK on sm_{cap[0]}{cap[1]}")
		PY
		then
			log "WARNING: torch GPU smoke test failed. The wheel ($cuda_idx_url) may not match this GPU."
			log "         Try: pip install --force-reinstall --index-url https://download.pytorch.org/whl/cu128 torch torchvision torchaudio"
		fi
	fi

	deactivate
}

install_manager() {
	local mgr_dir="$COMFYUI_DIR/custom_nodes/ComfyUI-Manager"
	if [[ -d "$mgr_dir/.git" ]]; then
		log "ComfyUI-Manager already installed — pulling"
		git -C "$mgr_dir" pull --ff-only || true
	else
		log "Installing ComfyUI-Manager"
		git clone https://github.com/ltdrdata/ComfyUI-Manager.git "$mgr_dir"
	fi
	# shellcheck disable=SC1091
	source "$COMFYUI_DIR/.venv/bin/activate"
	if [[ -f "$mgr_dir/requirements.txt" ]]; then
		pip install -r "$mgr_dir/requirements.txt"
	fi
	deactivate
}

write_caddy_config() {
	log "Installing Caddyfile to /etc/caddy/Caddyfile"
	mkdir -p /etc/caddy
	cp "$REPO_DIR/Caddyfile" /etc/caddy/Caddyfile
}

prepare_log_dir() {
	mkdir -p "$LOG_DIR"
}

print_next_steps() {
	cat <<EOF

\033[1;32mSetup complete.\033[0m

Next steps:
  1) Generate a bcrypt hash for your ComfyUI password:
       caddy hash-password
     (paste the hash starting with \$2a\$ — keep the dollar signs intact)

  2) Configure env vars:
       cp $REPO_DIR/.env.example $REPO_DIR/.env
       \$EDITOR $REPO_DIR/.env
     Set COMFY_USER and COMFY_PASS_HASH. Leave TUNNEL_NAME blank for now
     (Phase A — quick tunnel, random URL).

  3) Start everything:
       bash $REPO_DIR/onstart.sh
     Wait ~30 s, then read the public URL from:
       tail -f $LOG_DIR/tunnel.log
     Look for a line like: https://<random-words>.trycloudflare.com

  4) Open the URL in a browser. You'll get a basic-auth prompt.
     Log in with COMFY_USER / your password.

  5) To make it auto-start on instance reboot, paste this into the
     Vast.ai instance's "On-start script" field (web UI):
         bash $REPO_DIR/onstart.sh

  6) Phase B (later, after moving your domain to Cloudflare):
         cloudflared tunnel login
         cloudflared tunnel create comfy
         cloudflared tunnel route dns comfy comfy.<your-domain>
     Then set TUNNEL_NAME=comfy in .env and re-run onstart.sh.

Repairing an existing install (e.g. RTX 50-series box installed with the
old script and now hitting "no kernel image is available"):
       cd \$COMFYUI_DIR && source .venv/bin/activate
       pip uninstall -y torch torchvision torchaudio
       pip install --index-url https://download.pytorch.org/whl/cu128 torch torchvision torchaudio
       python -c "import torch; print(torch.cuda.get_device_capability(), torch.__version__)"
EOF
}

main() {
	require_root
	apt_install_base
	install_caddy
	install_cloudflared
	clone_comfyui
	install_python_deps
	install_manager
	write_caddy_config
	prepare_log_dir
	print_next_steps
}

main "$@"
