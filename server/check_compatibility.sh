#!/usr/bin/env bash
# ComfyUI compatibility check for a cloud GPU server (e.g. Vast.ai).
# Inspects GPU, CUDA, Python, RAM, disk, and OS, then reports whether
# the box can run ComfyUI and what model classes it can realistically
# handle. Read-only: makes no changes to the system.
#
# Usage:
#   bash server/check_compatibility.sh
#   ssh vastai 'bash -s' < server/check_compatibility.sh
#
# Exit codes:
#   0 = compatible (no blocking issues)
#   1 = incompatible (one or more blocking issues)
#   2 = compatible with warnings

set -uo pipefail

# ---- pretty printing -------------------------------------------------------

if [[ -t 1 ]]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
	C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
	C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

FAILS=0
WARNS=0

section() { printf '\n%s== %s ==%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET"; }
ok()      { printf '  %s[OK]%s    %s\n'   "$C_GREEN"  "$C_RESET" "$1"; }
warn()    { printf '  %s[WARN]%s  %s\n'   "$C_YELLOW" "$C_RESET" "$1"; WARNS=$((WARNS+1)); }
fail()    { printf '  %s[FAIL]%s  %s\n'   "$C_RED"    "$C_RESET" "$1"; FAILS=$((FAILS+1)); }
info()    { printf '         %s\n' "$1"; }

# ---- helpers ---------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Compare two dotted versions: returns 0 if $1 >= $2.
ver_ge() {
	# shellcheck disable=SC2046
	[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# ---- OS --------------------------------------------------------------------

section "Operating system"
if [[ -r /etc/os-release ]]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	info "${PRETTY_NAME:-$NAME $VERSION_ID} ($(uname -m), kernel $(uname -r))"
	case "${ID:-}" in
		ubuntu|debian) ok "Debian-family Linux — supported by setup_comfyui.sh" ;;
		*) warn "Distro '${ID:-unknown}' is untested; setup_comfyui.sh assumes apt" ;;
	esac
else
	warn "Cannot read /etc/os-release"
fi

# ---- CPU / RAM / disk ------------------------------------------------------

section "CPU / RAM / disk"
cpu_model="$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ *//')"
cpu_cores="$(nproc 2>/dev/null || echo '?')"
info "CPU: ${cpu_model:-unknown} (${cpu_cores} threads)"

if have free; then
	ram_gb="$(free -g | awk '/^Mem:/ {print $2}')"
	info "RAM: ${ram_gb} GiB"
	if [[ "$ram_gb" =~ ^[0-9]+$ ]]; then
		if (( ram_gb >= 16 )); then
			ok "RAM >= 16 GiB"
		elif (( ram_gb >= 8 )); then
			warn "RAM ${ram_gb} GiB — works for SD1.5, tight for SDXL/Flux"
		else
			fail "RAM ${ram_gb} GiB — below 8 GiB minimum, expect OOMs"
		fi
	fi
fi

# Disk where ComfyUI lives (or will live).
comfy_dir="${COMFYUI_DIR:-/workspace/ComfyUI}"
disk_target="$comfy_dir"
[[ -d "$disk_target" ]] || disk_target="$(dirname "$comfy_dir")"
[[ -d "$disk_target" ]] || disk_target="/"
free_gb="$(df -BG --output=avail "$disk_target" 2>/dev/null | tail -n1 | tr -dc '0-9')"
if [[ -n "$free_gb" ]]; then
	info "Free disk on $disk_target: ${free_gb} GiB"
	if (( free_gb >= 50 )); then
		ok "Free disk >= 50 GiB"
	elif (( free_gb >= 20 )); then
		warn "Free disk ${free_gb} GiB — fits one or two checkpoints, no headroom"
	else
		fail "Free disk ${free_gb} GiB — too small for typical model sets"
	fi
fi

# ---- GPU / driver / CUDA ---------------------------------------------------

section "GPU / driver / CUDA"
if have nvidia-smi; then
	smi="$(nvidia-smi 2>/dev/null || true)"
	driver="$(printf '%s' "$smi" | grep -oE 'Driver Version: [0-9.]+' | awk '{print $3}' | head -n1)"
	cuda_runtime="$(printf '%s' "$smi" | grep -oE 'CUDA Version: [0-9.]+' | awk '{print $3}' | head -n1)"
	info "NVIDIA driver: ${driver:-unknown}"
	info "CUDA runtime reported by driver: ${cuda_runtime:-unknown}"

	# Driver: 525+ supports CUDA 12.x; ComfyUI/PyTorch wheels assume CUDA 11.8 or 12.x.
	if [[ -n "$driver" ]]; then
		if ver_ge "$driver" "525.60"; then
			ok "Driver supports CUDA 12.x (cu124 wheels)"
		elif ver_ge "$driver" "450.80"; then
			warn "Driver only supports CUDA 11.x — setup will fall back to cu118 wheels"
		else
			fail "Driver too old; upgrade to >= 525 for CUDA 12.x"
		fi
	fi

	# Per-GPU details.
	mapfile -t gpus < <(nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader,nounits 2>/dev/null || true)
	if (( ${#gpus[@]} == 0 )); then
		fail "nvidia-smi returned no GPUs"
	else
		for line in "${gpus[@]}"; do
			IFS=',' read -r gname gmem gcap <<<"$line"
			gname="$(echo "$gname" | sed 's/^ *//;s/ *$//')"
			gmem="$(echo "$gmem"  | tr -dc '0-9')"
			gcap="$(echo "$gcap"  | sed 's/^ *//;s/ *$//')"
			info "GPU: $gname — ${gmem} MiB VRAM, compute capability ${gcap:-?}"

			# VRAM tiering for ComfyUI workloads.
			if   (( gmem >= 24000 )); then ok   "VRAM >= 24 GiB — SDXL, Flux, video, large LoRA training"
			elif (( gmem >= 16000 )); then ok   "VRAM >= 16 GiB — SDXL/Flux comfortable, Flux-dev with offload"
			elif (( gmem >= 12000 )); then ok   "VRAM >= 12 GiB — SDXL fine, Flux needs --lowvram or fp8"
			elif (( gmem >=  8000 )); then warn "VRAM ${gmem} MiB — SD1.5 fine, SDXL needs --medvram, Flux unlikely"
			elif (( gmem >=  4000 )); then warn "VRAM ${gmem} MiB — SD1.5 only, use --lowvram"
			else                            fail "VRAM ${gmem} MiB — below ComfyUI's practical floor (4 GiB)"
			fi

			# Compute capability: PyTorch cu124 wheels need >= 5.0 (Maxwell+); fp16/bf16 best on 7.0+; fp8 needs 8.9+ (Ada).
			if [[ "$gcap" =~ ^[0-9]+\.[0-9]+$ ]]; then
				if ver_ge "$gcap" "8.9";   then ok   "Compute cap $gcap — fp8 supported (Ada/Hopper)"
				elif ver_ge "$gcap" "7.0"; then ok   "Compute cap $gcap — fp16/bf16 fast"
				elif ver_ge "$gcap" "5.0"; then warn "Compute cap $gcap — works but no fast fp16; expect slow generation"
				else                            fail "Compute cap $gcap — unsupported by recent PyTorch builds"
				fi
			fi
		done
	fi
elif have rocminfo; then
	warn "AMD ROCm GPU detected — ComfyUI works but setup_comfyui.sh installs CUDA wheels"
	info "Use: pip install --index-url https://download.pytorch.org/whl/rocm6.0 torch torchvision torchaudio"
elif [[ "$(uname -s)" == "Darwin" ]]; then
	warn "Apple Silicon — ComfyUI runs via MPS, not relevant on a cloud GPU box"
else
	fail "No NVIDIA GPU detected (nvidia-smi missing). ComfyUI will run CPU-only and be unusably slow."
fi

# ---- Python ----------------------------------------------------------------

section "Python"
if have python3; then
	pyv="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)"
	info "python3: $pyv ($(command -v python3))"
	pymaj="${pyv%%.*}"; pyrest="${pyv#*.}"; pymin="${pyrest%%.*}"
	if [[ "$pymaj" == "3" ]] && (( pymin >= 10 && pymin <= 12 )); then
		ok "Python $pyv is in the 3.10–3.12 sweet spot for ComfyUI"
	elif [[ "$pymaj" == "3" ]] && (( pymin == 13 )); then
		warn "Python 3.13 — some custom nodes still lag behind, expect a few wheels to fail"
	elif [[ "$pymaj" == "3" ]] && (( pymin == 9 )); then
		warn "Python 3.9 — works but newer nodes assume 3.10+"
	else
		fail "Python $pyv unsupported; install 3.10–3.12"
	fi
else
	fail "python3 not installed"
fi

if ! have pip && ! python3 -m pip --version >/dev/null 2>&1; then
	warn "pip not available — apt_install_base in setup_comfyui.sh installs it"
fi
if ! python3 -c 'import venv' >/dev/null 2>&1; then
	warn "python3-venv missing — setup_comfyui.sh installs it via apt"
fi

# ---- Existing ComfyUI / PyTorch (if already installed) ---------------------

section "Existing ComfyUI install"
if [[ -d "$comfy_dir/.git" ]]; then
	commit="$(git -C "$comfy_dir" rev-parse --short HEAD 2>/dev/null || echo '?')"
	ok "ComfyUI present at $comfy_dir (commit $commit)"
	if [[ -x "$comfy_dir/.venv/bin/python" ]]; then
		torch_info="$("$comfy_dir/.venv/bin/python" - <<'PY' 2>/dev/null || true
try:
    import torch
    print(f"torch={torch.__version__} cuda={torch.version.cuda} cuda_available={torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"device0={torch.cuda.get_device_name(0)} cap={torch.cuda.get_device_capability(0)}")
except Exception as e:
    print(f"ERR: {e}")
PY
)"
		if [[ "$torch_info" == ERR:* || -z "$torch_info" ]]; then
			warn "venv exists but torch import failed: ${torch_info:-no output}"
		else
			info "$torch_info"
			if [[ "$torch_info" == *cuda_available=True* ]]; then
				ok "PyTorch sees the GPU"
			else
				fail "PyTorch installed but cuda_available=False — wrong wheel for this driver"
			fi
		fi
	else
		warn "No venv at $comfy_dir/.venv — run setup_comfyui.sh"
	fi
else
	info "ComfyUI not installed at $comfy_dir yet (run setup_comfyui.sh)"
fi

# ---- Summary ---------------------------------------------------------------

section "Summary"
if (( FAILS > 0 )); then
	printf '%s%d blocking issue(s)%s, %d warning(s). This box is %sNOT ready%s for ComfyUI as-is.\n' \
		"$C_RED" "$FAILS" "$C_RESET" "$WARNS" "$C_RED$C_BOLD" "$C_RESET"
	exit 1
elif (( WARNS > 0 )); then
	printf '%s%d warning(s)%s, no blockers. ComfyUI should run; review warnings above.\n' \
		"$C_YELLOW" "$WARNS" "$C_RESET"
	exit 2
else
	printf '%sAll checks passed.%s This box is ready for ComfyUI.\n' "$C_GREEN$C_BOLD" "$C_RESET"
	exit 0
fi
