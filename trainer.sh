#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"

# ------------------------------
# Usage
# ------------------------------
usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --destination PATH         Base workspace directory (overrides BASE_DIR).
  --base-dir PATH            Alias for --destination.
  --runs-dir PATH            Overrides RUNS_DIR.
  --logs-dir PATH            Overrides LOGS_DIR.
  --venv-dir PATH            Overrides VENV_DIR.
  --oww-repo-dir PATH         Overrides OWW_REPO_DIR.
  --custom-models-dir PATH    Overrides CUSTOM_MODELS_DIR.
  --min-free-disk-gb NUMBER  Overrides MIN_FREE_DISK_GB.
  --allow-low-disk           Proceed even if free disk is below the minimum.
  --install-optional-apt 0|1 Overrides INSTALL_OPTIONAL_APT.
  --wake-phrase TEXT         Overrides WAKE_PHRASE.
  --train-profile NAME       Overrides TRAIN_PROFILE (tiny|medium|large).
  --train-threads NUMBER     Overrides TRAIN_THREADS.
  --wyoming-piper-host HOST  Overrides WYOMING_PIPER_HOST.
  --wyoming-piper-port PORT  Overrides WYOMING_PIPER_PORT.
  --wyoming-oww-host HOST    Overrides WYOMING_OPENWAKEWORD_HOST.
  --wyoming-oww-port PORT    Overrides WYOMING_OPENWAKEWORD_PORT.
  --umask MASK               Overrides UMASK (e.g., 022).
  --help, -h                 Show this help and exit.

Environment overrides (if no flags provided):
  BASE_DIR, ALLOW_LOW_DISK, MIN_FREE_DISK_GB, RUNS_DIR, LOGS_DIR, VENV_DIR,
  OWW_REPO_DIR, CUSTOM_MODELS_DIR, TRAIN_PROFILE, TRAIN_THREADS, WAKE_PHRASE,
  INSTALL_OPTIONAL_APT, WYOMING_PIPER_HOST, WYOMING_PIPER_PORT,
  WYOMING_OPENWAKEWORD_HOST, WYOMING_OPENWAKEWORD_PORT, UMASK.
EOF
}

# Parsed CLI values (empty means "not provided")
CLI_BASE_DIR=""
CLI_RUNS_DIR=""
CLI_LOGS_DIR=""
CLI_VENV_DIR=""
CLI_OWW_REPO_DIR=""
CLI_CUSTOM_MODELS_DIR=""
CLI_MIN_FREE_DISK_GB=""
CLI_ALLOW_LOW_DISK=0
CLI_INSTALL_OPTIONAL_APT=""
CLI_WAKE_PHRASE=""
CLI_TRAIN_PROFILE=""
CLI_TRAIN_THREADS=""
CLI_WYOMING_PIPER_HOST=""
CLI_WYOMING_PIPER_PORT=""
CLI_WYOMING_OWW_HOST=""
CLI_WYOMING_OWW_PORT=""
CLI_UMASK=""

# ------------------------------
# Logging / Error handling
# ------------------------------
timestamp_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
  local msg="${1:?}"
  echo "[$(timestamp_utc)] [$SCRIPT_NAME] $msg" >&2
}

die() {
  local msg="${1:?}"
  echo "[$(timestamp_utc)] [$SCRIPT_NAME] FATAL: $msg" >&2
  exit 1
}

on_err() {
  local exit_code=$?
  local line_no=${1:-"?"}
  die "Unhandled error at line $line_no (exit=$exit_code). See logs above."
}
trap 'on_err $LINENO' ERR

# ------------------------------
# Platform checks
# ------------------------------
require_cmd() {
  local c="${1:?}"
  command -v "$c" >/dev/null 2>&1 || die "Missing required command: $c"
}

is_raspberry_pi() {
  [[ -r /proc/device-tree/model ]] && grep -qi "raspberry pi" /proc/device-tree/model
}

arch() { uname -m; }

os_id() {
  [[ -r /etc/os-release ]] || echo "unknown"
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  echo "${ID:-unknown}"
}

have_internet_dns() {
  # Very lightweight sanity check (does not guarantee full connectivity)
  getent hosts github.com >/dev/null 2>&1
}

# Bash /dev/tcp port probe (no netcat dependency).
port_open() {
  local host="${1:?}"
  local port="${2:?}"
  local timeout_s="${3:-1}"
  require_cmd timeout
  timeout "${timeout_s}" bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
}

# ------------------------------
# APT helpers
# ------------------------------
have_sudo() {
  command -v sudo >/dev/null 2>&1
}

sudo_maybe() {
  if [[ ${EUID:-999} -eq 0 ]]; then
    "$@"
  else
    have_sudo || die "Not root and sudo not found. Install sudo or run as root."
    sudo -n true >/dev/null 2>&1 || sudo -v || die "sudo authentication failed."
    sudo "$@"
  fi
}

apt_pkg_installed() {
  local pkg="${1:?}"
  dpkg -s "$pkg" >/dev/null 2>&1
}

apt_pkg_available() {
  local pkg="${1:?}"
  apt-cache show "$pkg" >/dev/null 2>&1
}

apt_install_many() {
  local -a pkgs=("$@")
  [[ ${#pkgs[@]} -gt 0 ]] || return 0
  sudo_maybe apt-get install -y --no-install-recommends "${pkgs[@]}"
}

apt_update_once() {
  local stamp="${1:?}"
  if [[ ! -f "$stamp" ]]; then
    log "Running apt-get update ..."
    sudo_maybe apt-get update -y
    touch "$stamp"
  fi
}

# ------------------------------
# Input helpers
# ------------------------------
prompt_nonempty() {
  local var_name="${1:?}"
  local prompt_text="${2:?}"
  local default_value="${3:?}"

  local value=""
  if [[ -n "${!var_name:-}" ]]; then
    value="${!var_name}"
  else
    if [[ -t 0 ]]; then
      read -r -p "${prompt_text} [${default_value}]: " value || true
      value="${value:-$default_value}"
    else
      value="$default_value"
    fi
  fi

  value="$(echo -n "$value" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
  [[ -n "$value" ]] || die "Input for ${var_name} must not be empty."
  printf -v "$var_name" '%s' "$value"
}

prompt_choice() {
  local var_name="${1:?}"
  local prompt_text="${2:?}"
  local default_value="${3:?}"
  shift 3
  local -a choices=("$@")
  [[ ${#choices[@]} -gt 0 ]] || die "prompt_choice requires at least one choice."

  local value=""
  if [[ -n "${!var_name:-}" ]]; then
    value="${!var_name}"
  else
    if [[ -t 0 ]]; then
      read -r -p "${prompt_text} [${default_value}] (choices: ${choices[*]}): " value || true
      value="${value:-$default_value}"
    else
      value="$default_value"
    fi
  fi

  local ok=0
  for c in "${choices[@]}"; do
    if [[ "$value" == "$c" ]]; then ok=1; break; fi
  done
  [[ $ok -eq 1 ]] || die "Invalid choice for ${var_name}: '${value}'. Allowed: ${choices[*]}"
  printf -v "$var_name" '%s' "$value"
}

validate_base_dir() {
  local dir="${1:?}"
  [[ -n "$dir" ]] || die "Base directory must not be empty."
  if [[ "$dir" == "/" ]]; then
    die "Base directory must not be '/'. Set BASE_DIR to a safe path."
  fi
}

expand_tilde() {
  local path="${1:?}"
  if [[ "$path" == "~" ]]; then
    echo "$HOME"
  elif [[ "$path" == "~/"* ]]; then
    echo "${HOME}${path:1}"
  else
    echo "$path"
  fi
}

slugify() {
  # Lowercase, keep alnum, convert spaces/dashes to underscore, collapse repeats.
  echo -n "${1:?}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//; s/_+/_/g'
}

require_free_disk_gb() {
  local path="${1:?}"
  local min_gb="${2:?}"
  require_cmd df
  local avail_kb
  avail_kb="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
  [[ "$avail_kb" =~ ^[0-9]+$ ]] || die "Could not determine free disk space at $path"
  local avail_gb=$(( avail_kb / 1024 / 1024 ))
  if (( avail_gb < min_gb )); then
    if [[ "${ALLOW_LOW_DISK:-0}" == "1" ]]; then
      log "WARNING: Free disk at $path is ${avail_gb}GB (<${min_gb}GB). Continuing due to ALLOW_LOW_DISK=1."
    else
      die "Insufficient free disk at $path: ${avail_gb}GB available, need >= ${min_gb}GB. (Override: ALLOW_LOW_DISK=1)"
    fi
  fi
}

# ------------------------------
# Pip helpers
# ------------------------------
pip_install() {
  # First try prefer-binary to avoid source builds on Pi.
  local -a pkgs=("$@")
  PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 \
    python -m pip install --prefer-binary --no-input --disable-pip-version-check "${pkgs[@]}" || {
    log "pip prefer-binary failed for: ${pkgs[*]} — retrying without prefer-binary."
    PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 \
      python -m pip install --no-input --disable-pip-version-check "${pkgs[@]}"
  }
}

python_import_check() {
  local mod="${1:?}"
  python - <<PY
import importlib, sys
m = "${mod}"
try:
    importlib.import_module(m)
except Exception as e:
    print(f"IMPORT_FAIL {m}: {e}", file=sys.stderr)
    sys.exit(2)
print(f"IMPORT_OK {m}")
PY
}

install_tflite_runtime_if_available() {
  log "Checking availability of tflite-runtime..."

  # Case 1: Already importable (someone installed it earlier)
  if python - <<'EOF' >/dev/null 2>&1
import tflite_runtime.interpreter
EOF
  then
    log "tflite-runtime already importable; skipping install."
    return 0
  fi

  # Case 2: Available via APT (preferred on Raspberry Pi)
  if command -v apt-cache >/dev/null 2>&1 && apt-cache show python3-tflite-runtime >/dev/null 2>&1; then
    if ! dpkg -s python3-tflite-runtime >/dev/null 2>&1; then
      log "Installing tflite-runtime via APT (python3-tflite-runtime)..."
      sudo_maybe apt-get install -y --no-install-recommends python3-tflite-runtime
    else
      log "python3-tflite-runtime already installed via APT."
    fi

    # Verify
    if python - <<'EOF' >/dev/null 2>&1
import tflite_runtime.interpreter
EOF
    then
      log "tflite-runtime usable after APT install."
      return 0
    else
      log "WARNING: python3-tflite-runtime installed but not importable."
      return 1
    fi
  fi

  # Case 3: Not available → explicitly skip
  log "tflite-runtime not available for this OS/Python/arch; skipping (OK for training)."
  return 0
}

# ------------------------------
# Main
# ------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --allow-low-disk)
        CLI_ALLOW_LOW_DISK=1
        shift
        ;;
      --base-dir|--destination)
        [[ -n "${2:-}" ]] || die "--destination requires a path."
        CLI_BASE_DIR="$2"
        shift 2
        ;;
      --base-dir=*)
        CLI_BASE_DIR="${1#*=}"
        shift
        ;;
      --destination=*)
        CLI_BASE_DIR="${1#*=}"
        shift
        ;;
      --runs-dir)
        [[ -n "${2:-}" ]] || die "--runs-dir requires a path."
        CLI_RUNS_DIR="$2"
        shift 2
        ;;
      --runs-dir=*)
        CLI_RUNS_DIR="${1#*=}"
        shift
        ;;
      --logs-dir)
        [[ -n "${2:-}" ]] || die "--logs-dir requires a path."
        CLI_LOGS_DIR="$2"
        shift 2
        ;;
      --logs-dir=*)
        CLI_LOGS_DIR="${1#*=}"
        shift
        ;;
      --venv-dir)
        [[ -n "${2:-}" ]] || die "--venv-dir requires a path."
        CLI_VENV_DIR="$2"
        shift 2
        ;;
      --venv-dir=*)
        CLI_VENV_DIR="${1#*=}"
        shift
        ;;
      --oww-repo-dir)
        [[ -n "${2:-}" ]] || die "--oww-repo-dir requires a path."
        CLI_OWW_REPO_DIR="$2"
        shift 2
        ;;
      --oww-repo-dir=*)
        CLI_OWW_REPO_DIR="${1#*=}"
        shift
        ;;
      --custom-models-dir)
        [[ -n "${2:-}" ]] || die "--custom-models-dir requires a path."
        CLI_CUSTOM_MODELS_DIR="$2"
        shift 2
        ;;
      --custom-models-dir=*)
        CLI_CUSTOM_MODELS_DIR="${1#*=}"
        shift
        ;;
      --min-free-disk-gb)
        [[ -n "${2:-}" ]] || die "--min-free-disk-gb requires a number."
        CLI_MIN_FREE_DISK_GB="$2"
        shift 2
        ;;
      --min-free-disk-gb=*)
        CLI_MIN_FREE_DISK_GB="${1#*=}"
        shift
        ;;
      --install-optional-apt)
        [[ -n "${2:-}" ]] || die "--install-optional-apt requires 0 or 1."
        CLI_INSTALL_OPTIONAL_APT="$2"
        shift 2
        ;;
      --install-optional-apt=*)
        CLI_INSTALL_OPTIONAL_APT="${1#*=}"
        shift
        ;;
      --wake-phrase)
        [[ -n "${2:-}" ]] || die "--wake-phrase requires text."
        CLI_WAKE_PHRASE="$2"
        shift 2
        ;;
      --wake-phrase=*)
        CLI_WAKE_PHRASE="${1#*=}"
        shift
        ;;
      --train-profile)
        [[ -n "${2:-}" ]] || die "--train-profile requires a value."
        CLI_TRAIN_PROFILE="$2"
        shift 2
        ;;
      --train-profile=*)
        CLI_TRAIN_PROFILE="${1#*=}"
        shift
        ;;
      --train-threads)
        [[ -n "${2:-}" ]] || die "--train-threads requires a number."
        CLI_TRAIN_THREADS="$2"
        shift 2
        ;;
      --train-threads=*)
        CLI_TRAIN_THREADS="${1#*=}"
        shift
        ;;
      --wyoming-piper-host)
        [[ -n "${2:-}" ]] || die "--wyoming-piper-host requires a host."
        CLI_WYOMING_PIPER_HOST="$2"
        shift 2
        ;;
      --wyoming-piper-host=*)
        CLI_WYOMING_PIPER_HOST="${1#*=}"
        shift
        ;;
      --wyoming-piper-port)
        [[ -n "${2:-}" ]] || die "--wyoming-piper-port requires a port."
        CLI_WYOMING_PIPER_PORT="$2"
        shift 2
        ;;
      --wyoming-piper-port=*)
        CLI_WYOMING_PIPER_PORT="${1#*=}"
        shift
        ;;
      --wyoming-oww-host)
        [[ -n "${2:-}" ]] || die "--wyoming-oww-host requires a host."
        CLI_WYOMING_OWW_HOST="$2"
        shift 2
        ;;
      --wyoming-oww-host=*)
        CLI_WYOMING_OWW_HOST="${1#*=}"
        shift
        ;;
      --wyoming-oww-port)
        [[ -n "${2:-}" ]] || die "--wyoming-oww-port requires a port."
        CLI_WYOMING_OWW_PORT="$2"
        shift 2
        ;;
      --wyoming-oww-port=*)
        CLI_WYOMING_OWW_PORT="${1#*=}"
        shift
        ;;
      --umask)
        [[ -n "${2:-}" ]] || die "--umask requires a value."
        CLI_UMASK="$2"
        shift 2
        ;;
      --umask=*)
        CLI_UMASK="${1#*=}"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        die "Unknown argument: $1. Use --help for usage."
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if [[ -n "$CLI_BASE_DIR" ]]; then
    BASE_DIR="$CLI_BASE_DIR"
  fi
  if [[ "$CLI_ALLOW_LOW_DISK" == "1" ]]; then
    ALLOW_LOW_DISK=1
  fi
  if [[ -n "$CLI_MIN_FREE_DISK_GB" ]]; then
    MIN_FREE_DISK_GB="$CLI_MIN_FREE_DISK_GB"
  fi
  if [[ -n "$CLI_RUNS_DIR" ]]; then
    RUNS_DIR="$CLI_RUNS_DIR"
  fi
  if [[ -n "$CLI_LOGS_DIR" ]]; then
    LOGS_DIR="$CLI_LOGS_DIR"
  fi
  if [[ -n "$CLI_VENV_DIR" ]]; then
    VENV_DIR="$CLI_VENV_DIR"
  fi
  if [[ -n "$CLI_OWW_REPO_DIR" ]]; then
    OWW_REPO_DIR="$CLI_OWW_REPO_DIR"
  fi
  if [[ -n "$CLI_CUSTOM_MODELS_DIR" ]]; then
    CUSTOM_MODELS_DIR="$CLI_CUSTOM_MODELS_DIR"
  fi
  if [[ -n "$CLI_INSTALL_OPTIONAL_APT" ]]; then
    INSTALL_OPTIONAL_APT="$CLI_INSTALL_OPTIONAL_APT"
  fi
  if [[ -n "$CLI_WAKE_PHRASE" ]]; then
    WAKE_PHRASE="$CLI_WAKE_PHRASE"
  fi
  if [[ -n "$CLI_TRAIN_PROFILE" ]]; then
    TRAIN_PROFILE="$CLI_TRAIN_PROFILE"
  fi
  if [[ -n "$CLI_TRAIN_THREADS" ]]; then
    TRAIN_THREADS="$CLI_TRAIN_THREADS"
  fi
  if [[ -n "$CLI_WYOMING_PIPER_HOST" ]]; then
    WYOMING_PIPER_HOST="$CLI_WYOMING_PIPER_HOST"
  fi
  if [[ -n "$CLI_WYOMING_PIPER_PORT" ]]; then
    WYOMING_PIPER_PORT="$CLI_WYOMING_PIPER_PORT"
  fi
  if [[ -n "$CLI_WYOMING_OWW_HOST" ]]; then
    WYOMING_OPENWAKEWORD_HOST="$CLI_WYOMING_OWW_HOST"
  fi
  if [[ -n "$CLI_WYOMING_OWW_PORT" ]]; then
    WYOMING_OPENWAKEWORD_PORT="$CLI_WYOMING_OWW_PORT"
  fi
  if [[ -n "$CLI_UMASK" ]]; then
    UMASK="$CLI_UMASK"
  fi

  umask "${UMASK:-022}"

  require_cmd bash
  require_cmd python3
  require_cmd timeout

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

  local host_piper="${WYOMING_PIPER_HOST:-127.0.0.1}"
  local port_piper="${WYOMING_PIPER_PORT:-10200}"   # common wyoming-piper port :contentReference[oaicite:3]{index=3}
  local host_oww="${WYOMING_OPENWAKEWORD_HOST:-127.0.0.1}"
  local port_oww="${WYOMING_OPENWAKEWORD_PORT:-10400}" # wyoming-openwakeword default :contentReference[oaicite:4]{index=4}

  local have_wyoming_piper=0
  local have_wyoming_oww=0
  local have_local_wyoming_piper=0
  local have_local_wyoming_oww=0
  if port_open "$host_piper" "$port_piper" 1; then have_wyoming_piper=1; fi
  if port_open "$host_oww" "$port_oww" 1; then have_wyoming_oww=1; fi
  if port_open "127.0.0.1" "$port_piper" 1; then have_local_wyoming_piper=1; fi
  if port_open "127.0.0.1" "$port_oww" 1; then have_local_wyoming_oww=1; fi

  log "Detected: wyoming-piper on ${host_piper}:${port_piper} => ${have_wyoming_piper}"
  log "Detected: wyoming-openwakeword on ${host_oww}:${port_oww} => ${have_wyoming_oww}"
  log "Detected: wyoming-piper on localhost:${port_piper} => ${have_local_wyoming_piper}"
  log "Detected: wyoming-openwakeword on localhost:${port_oww} => ${have_local_wyoming_oww}"

  if is_raspberry_pi; then
    log "Platform: Raspberry Pi detected."
  else
    log "Platform: not positively identified as Raspberry Pi (continuing)."
  fi
  log "Arch: $(arch); OS: $(os_id)"

  # Workspace layout
  local base_dir="${BASE_DIR:-$HOME/wakeword_lab}"
  base_dir="$(expand_tilde "$base_dir")"
  local repo_dir="${OWW_REPO_DIR:-$base_dir/openWakeWord}"
  local venv_dir="${VENV_DIR:-$base_dir/venv}"
  local runs_dir="${RUNS_DIR:-$base_dir/training_runs}"
  local logs_dir="${LOGS_DIR:-$base_dir/logs}"
  local custom_models_dir="${CUSTOM_MODELS_DIR:-$base_dir/custom_models}"
  local data_dir="${DATA_DIR:-$base_dir/data}"
  repo_dir="$(expand_tilde "$repo_dir")"
  venv_dir="$(expand_tilde "$venv_dir")"
  runs_dir="$(expand_tilde "$runs_dir")"
  logs_dir="$(expand_tilde "$logs_dir")"
  custom_models_dir="$(expand_tilde "$custom_models_dir")"
  data_dir="$(expand_tilde "$data_dir")"

  validate_base_dir "$base_dir"
  mkdir -p "$base_dir" "$runs_dir" "$logs_dir" "$custom_models_dir" "$data_dir"
  require_free_disk_gb "$base_dir" "${MIN_FREE_DISK_GB:-8}"

  local apt_stamp="$logs_dir/.apt_updated"
  if command -v apt-get >/dev/null 2>&1; then
    # Core tooling
    local -a req_pkgs=(
      ca-certificates
      curl
      git
      tmux
      build-essential
      pkg-config
      python3-venv
      python3-pip
      python3-dev
      ffmpeg
      sox
      libsndfile1
      libsndfile1-dev
      libasound2-dev
      libffi-dev
      libssl-dev
      jq
    )

    # "As many python packages as possible" via apt (optional if available)
    local -a opt_py_pkgs=(
      python3-numpy
      python3-scipy
      python3-yaml
      python3-soundfile
    )

    # Optional, may or may not exist on your distro/repo:
    local -a maybe_pkgs=(
      libspeexdsp-dev
      python3-torch
      python3-torchaudio
      python3-onnxruntime
    )

    local -a to_install=()
    for p in "${req_pkgs[@]}"; do
      if ! apt_pkg_installed "$p"; then to_install+=("$p"); fi
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
      apt_update_once "$apt_stamp"
    fi
    if [[ ${#to_install[@]} -gt 0 ]]; then
      log "Installing required apt packages..."
      apt_install_many "${to_install[@]}"
    else
      log "Required apt packages already installed."
    fi

    if [[ "${INSTALL_OPTIONAL_APT:-1}" == "1" ]]; then
      apt_update_once "$apt_stamp"
      to_install=()
      for p in "${opt_py_pkgs[@]}"; do
        if apt_pkg_available "$p" && ! apt_pkg_installed "$p"; then to_install+=("$p"); fi
      done
      if [[ ${#to_install[@]} -gt 0 ]]; then
        log "Installing optional python-related apt packages (speed/compat on Pi)..."
        apt_install_many "${to_install[@]}"
      fi

      to_install=()
      for p in "${maybe_pkgs[@]}"; do
        if apt_pkg_available "$p" && ! apt_pkg_installed "$p"; then to_install+=("$p"); fi
      done
      if [[ ${#to_install[@]} -gt 0 ]]; then
        log "Installing additional optional apt packages that are available on this OS..."
        apt_install_many "${to_install[@]}"
      fi
    else
      log "Skipping optional apt packages (INSTALL_OPTIONAL_APT=0)."
    fi
  else
    die "apt-get not found. This script currently targets Debian/Raspberry Pi OS/Ubuntu."
  fi

  require_cmd git
  require_cmd tmux
  require_cmd python3

  # Clone or update openWakeWord repo
  if [[ -d "$repo_dir/.git" ]]; then
    log "openWakeWord repo already present: $repo_dir"
    if have_internet_dns; then
      log "Attempting fast-forward update (git pull --ff-only)..."
      (cd "$repo_dir" && git pull --ff-only) || log "WARNING: git pull failed (continuing with existing checkout)."
    else
      log "No DNS resolution detected; skipping repo update."
    fi
  else
    have_internet_dns || die "No DNS resolution detected; cannot clone repos. Fix networking or pre-clone openWakeWord into $repo_dir."
    log "Cloning openWakeWord into $repo_dir ..."
    git clone --depth 1 https://github.com/dscripka/openWakeWord.git "$repo_dir" \
      || die "git clone failed."
  fi

  # Create venv (use system site packages to leverage apt-installed numpy/scipy on Pi)
  if [[ -d "$venv_dir" ]]; then
    log "Venv already exists: $venv_dir"
  else
    log "Creating venv: $venv_dir"
    python3 -m venv --system-site-packages "$venv_dir" || die "venv creation failed."
  fi

  # shellcheck disable=SC1091
  source "$venv_dir/bin/activate"
  PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 \
    python -m pip install -U --no-input --disable-pip-version-check pip setuptools wheel \
    || die "pip bootstrap/upgrade failed."

  # Install baseline Python deps (best-effort superset for training flows)
  log "Installing Python packages (best-effort superset for openWakeWord training + Piper dataset gen)..."
  install_tflite_runtime_if_available || log "WARNING: tflite-runtime setup failed; continuing without it."
  local -a pip_pkgs=(
    pyyaml
    numpy
    scipy
    soundfile
    resampy
    tqdm
    matplotlib
    scikit-learn
    onnx
    onnxruntime
    datasets
    speechbrain
  )
  if [[ "$have_wyoming_piper" -eq 1 || "$have_local_wyoming_piper" -eq 1 ]]; then
    log "Wyoming piper detected; skipping piper-tts install."
  else
    pip_pkgs+=(piper-tts)
  fi
  pip_install "${pip_pkgs[@]}"

  # Try to ensure torch exists (training often needs it; if your distro provided python3-torch, this may already pass)
  if ! python_import_check torch >/dev/null 2>&1; then
    log "torch not importable yet; attempting pip install torch + torchaudio (may fail on some Pi OS/arches)."
    if ! (pip_install torch torchaudio); then
      log "WARNING: torch install failed. If training requires torch, you must resolve torch installation for your Pi (64-bit strongly recommended)."
    fi
  fi

  # Install openWakeWord from the repo (editable)
  local skip_openwakeword_install=0
  if [[ "$have_wyoming_oww" -eq 1 || "$have_local_wyoming_oww" -eq 1 ]] \
    && python_import_check openwakeword >/dev/null 2>&1; then
    skip_openwakeword_install=1
    log "Wyoming openwakeword detected and openwakeword importable; skipping editable install."
  fi

  if [[ "$skip_openwakeword_install" -eq 0 ]]; then
    log "Installing openWakeWord from local repo (editable)..."
    if ! python -m pip install -e "$repo_dir" ; then
      log "WARNING: Editable install failed. Retrying without dependency resolution (pip --no-deps)."
      if ! python -m pip install -e "$repo_dir" --no-deps ; then
        die "Failed to install openWakeWord from $repo_dir"
      fi
    fi
    python_import_check openwakeword >/dev/null 2>&1 || die "openwakeword import check failed after install."
  fi

  # User inputs
  local wake_phrase="${WAKE_PHRASE:-}"
  prompt_nonempty wake_phrase "Wake phrase to train" "hey assistant"
  local model_slug
  model_slug="$(slugify "$wake_phrase")"
  [[ -n "$model_slug" ]] || die "Derived model slug is empty (unexpected)."

  local train_profile="${TRAIN_PROFILE:-}"
  prompt_choice train_profile "Training profile" "medium" "tiny" "medium" "large"

  local train_threads="${TRAIN_THREADS:-}"
  local default_threads
  default_threads="$(python - <<'PY'
import os
try:
  import multiprocessing as mp
  print(max(1, mp.cpu_count()))
except Exception:
  print(1)
PY
)"
  prompt_nonempty train_threads "CPU threads to use" "$default_threads"
  [[ "$train_threads" =~ ^[0-9]+$ ]] || die "TRAIN_THREADS must be an integer."

  local run_id
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  local run_dir="$runs_dir/${model_slug}_${run_id}"
  local dataset_dir="$run_dir/dataset"
  local dataset_json="$dataset_dir/dataset.json"
  mkdir -p "$run_dir"

  # Choose epochs as a simple mapping (best-effort; will only apply if YAML has an epoch key we recognize)
  local epochs=25
  case "$train_profile" in
    tiny)   epochs=10 ;;
    medium) epochs=25 ;;
    large)  epochs=50 ;;
  esac

  # Prepare training config
  local example_cfg="$repo_dir/examples/custom_model.yml"
  [[ -f "$example_cfg" ]] || die "Expected example config not found: $example_cfg"
  local cfg_in="$example_cfg"
  local cfg_out="$run_dir/training_config.yml"
  cp -f "$cfg_in" "$cfg_out"

  # Patch YAML (best-effort; only touches known key names if present)
  log "Patching training config (best-effort) -> $cfg_out"
  RUN_DIR="$run_dir" DATASET_JSON="$dataset_json" python - <<PY
import os, sys
import yaml

cfg_path = "${cfg_out}"
wake_phrase = "${wake_phrase}"
model_slug = "${model_slug}"
epochs = int("${epochs}")
run_dir = os.environ.get("RUN_DIR", "")
dataset_json = os.environ.get("DATASET_JSON", "")

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f)

updated = []

def set_key_recursive(obj, key, value):
    if isinstance(obj, dict):
        for k in list(obj.keys()):
            if k == key:
                obj[k] = value
                updated.append(key)
            else:
                set_key_recursive(obj[k], key, value)
    elif isinstance(obj, list):
        for it in obj:
            set_key_recursive(it, key, value)

# Common keys observed in openWakeWord training flows (best-effort)
for k in ("target_phrase", "target_phrases", "wake_phrase", "wake_phrases"):
    set_key_recursive(cfg, k, [wake_phrase] if k.endswith("s") or k.startswith("target_") else wake_phrase)

for k in ("model_name", "wakeword_name", "wake_word_name"):
    set_key_recursive(cfg, k, model_slug)

for k in ("output_dir", "model_output_dir", "export_dir"):
    if run_dir:
        set_key_recursive(cfg, k, run_dir)

for k in ("dataset_path", "dataset_json", "custom_dataset_path", "custom_dataset"):
    if dataset_json:
        set_key_recursive(cfg, k, dataset_json)

for k in ("epochs", "n_epochs", "num_epochs", "max_epochs"):
    set_key_recursive(cfg, k, epochs)

with open(cfg_path, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)

print("Updated YAML keys:", sorted(set(updated)))
PY

  # Create a deterministic training script that tmux will run
  local train_sh="$run_dir/run_training.sh"
  cat >"$train_sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\\n\\t'

log() { echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] [train] \$*" >&2; }
die() { echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] [train] FATAL: \$*" >&2; exit 1; }
trap 'die "Unhandled error at line \$LINENO."' ERR

VENV_DIR="${venv_dir}"
REPO_DIR="${repo_dir}"
RUN_DIR="${run_dir}"
CFG_PATH="${cfg_out}"
CUSTOM_MODELS_DIR="${custom_models_dir}"
TRAIN_THREADS="${train_threads}"
DATA_DIR="${data_dir}"
DATASET_DIR="${dataset_dir}"
DATASET_JSON="${dataset_json}"
GENERATE_DATASET="${script_dir}/generate_dataset.py"
POSITIVE_SOURCES="${POSITIVE_SOURCES:-}"
NEGATIVE_SOURCES="${NEGATIVE_SOURCES:-}"
MAX_POSITIVE_SAMPLES="${MAX_POSITIVE_SAMPLES:-}"
MAX_NEGATIVE_SAMPLES="${MAX_NEGATIVE_SAMPLES:-}"
MIN_PER_SOURCE="${MIN_PER_SOURCE:-}"
DATASET_SEED="${DATASET_SEED:-42}"

[[ -f "\$VENV_DIR/bin/activate" ]] || die "Missing venv activate script: \$VENV_DIR/bin/activate"
# shellcheck disable=SC1091
source "\$VENV_DIR/bin/activate"

python -c "import openwakeword" >/dev/null 2>&1 || die "openwakeword not importable inside venv."

export OMP_NUM_THREADS="\$TRAIN_THREADS"
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

mkdir -p "\$RUN_DIR" "\$CUSTOM_MODELS_DIR"
cd "\$REPO_DIR" || die "Cannot cd to repo dir: \$REPO_DIR"

touch "\$RUN_DIR/.start_time"

log "Training start"
log "Config: \$CFG_PATH"
log "Run dir: \$RUN_DIR"
log "Threads: \$TRAIN_THREADS"

# Ensure a diverse dataset manifest before training.
if [[ -f "\$GENERATE_DATASET" ]]; then
  log "Generating diversified dataset manifest..."
  python "\$GENERATE_DATASET" \\
    --output-dir "\$DATASET_DIR" \\
    --wake-phrase "${wake_phrase}" \\
    --positive-sources "\${POSITIVE_SOURCES:-\$DATA_DIR/positives}" \\
    --negative-sources "\${NEGATIVE_SOURCES:-\$DATA_DIR/negatives}" \\
    --max-positives "\${MAX_POSITIVE_SAMPLES}" \\
    --max-negatives "\${MAX_NEGATIVE_SAMPLES}" \\
    --min-per-source "\${MIN_PER_SOURCE}" \\
    --seed "\${DATASET_SEED}"
else
  log "WARNING: generate_dataset.py not found at \$GENERATE_DATASET; skipping dataset manifest generation."
fi

# openWakeWord training script is driven by a YAML config and supports step flags in typical flows. :contentReference[oaicite:5]{index=5}
# NOTE: If upstream flags change, this will fail loudly and you must adjust the command.
python openwakeword/train.py --training_config "\$CFG_PATH" --generate_clips 2>&1 | tee -a "\$RUN_DIR/training.log"
python openwakeword/train.py --training_config "\$CFG_PATH" --augment_clips 2>&1 | tee -a "\$RUN_DIR/training.log"
python openwakeword/train.py --training_config "\$CFG_PATH" --train_model 2>&1 | tee -a "\$RUN_DIR/training.log"

log "Training finished; searching for newly produced model artifacts..."
mapfile -t tflites < <(find "\$RUN_DIR" "\$REPO_DIR" -type f -name "*.tflite" -newer "\$RUN_DIR/.start_time" 2>/dev/null | sort || true)
mapfile -t onnxes  < <(find "\$RUN_DIR" "\$REPO_DIR" -type f -name "*.onnx"  -newer "\$RUN_DIR/.start_time" 2>/dev/null | sort || true)

if [[ \${#tflites[@]} -eq 0 && \${#onnxes[@]} -eq 0 ]]; then
  log "WARNING: No new .tflite/.onnx files found. Check \$RUN_DIR/training.log for where outputs were written."
else
  if [[ \${#tflites[@]} -gt 0 ]]; then
    for f in "\${tflites[@]}"; do
      log "Copying: \$f -> \$CUSTOM_MODELS_DIR/"
      cp -f "\$f" "\$CUSTOM_MODELS_DIR/" || die "Failed to copy \$f"
    done
  fi
  if [[ \${#onnxes[@]} -gt 0 ]]; then
    for f in "\${onnxes[@]}"; do
      log "Copying: \$f -> \$CUSTOM_MODELS_DIR/"
      cp -f "\$f" "\$CUSTOM_MODELS_DIR/" || die "Failed to copy \$f"
    done
  fi
fi

log "Artifacts directory: \$CUSTOM_MODELS_DIR"
log "Done."
EOF
  chmod +x "$train_sh"

  # Start tmux session
  local session="wakeword_${model_slug}_${run_id}"
  if tmux has-session -t "$session" >/dev/null 2>&1; then
    die "tmux session already exists: $session"
  fi

  log "Launching training in tmux session: $session"
  tmux new-session -d -s "$session" "bash -lc '$train_sh'"

  # Post-flight info (tell it like it is)
  log "tmux session started."
  echo
  echo "=== STARTED ==="
  echo "Wake phrase      : $wake_phrase"
  echo "Model slug       : $model_slug"
  echo "Run dir          : $run_dir"
  echo "Log file         : $run_dir/training.log"
  echo "Custom models dir: $custom_models_dir"
  echo
  echo "Attach to training:"
  echo "  tmux attach -t $session"
  echo
  echo "If you already run Wyoming services:"
  echo "  wyoming-openwakeword detected on ${host_oww}:${port_oww} => ${have_wyoming_oww}"
  echo "  wyoming-piper        detected on ${host_piper}:${port_piper} => ${have_wyoming_piper}"
  echo "  localhost openwakeword detected on ${port_oww} => ${have_local_wyoming_oww}"
  echo "  localhost piper       detected on ${port_piper} => ${have_local_wyoming_piper}"
  echo
  echo "To serve a trained .tflite via Wyoming openWakeWord, the server commonly listens on 10400 and supports --custom-model-dir. :contentReference[oaicite:6]{index=6}"
  echo "=== END ==="
}

main "$@"
