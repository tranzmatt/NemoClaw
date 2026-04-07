#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NemoClaw conda installer — installs OpenShell and NemoClaw entirely inside a
# conda environment.
#
# Usage:
#   bash install-conda.sh --conda-env <name> [--reprocess] [--non-interactive]
#
# The conda environment will be created with nodejs (22.x) and python (3.12.x)
# via conda-forge if it does not already exist.  All binaries (openshell,
# nemoclaw) are installed into the environment's prefix so nothing leaks into
# the system or the user's home PATH.

set -euo pipefail

# ---------------------------------------------------------------------------
# Global cleanup
# ---------------------------------------------------------------------------
_cleanup_pids=()
_cleanup_files=()
_global_cleanup() {
  for pid in "${_cleanup_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  for f in "${_cleanup_files[@]:-}"; do
    rm -f "$f" 2>/dev/null || true
  done
}
trap _global_cleanup EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEFAULT_NEMOCLAW_VERSION="0.1.0"
TOTAL_STEPS=4

resolve_installer_version() {
  local package_json="${SCRIPT_DIR}/package.json"
  local version=""
  if [[ -f "$package_json" ]]; then
    version="$(sed -nE 's/^[[:space:]]*"version":[[:space:]]*"([^"]+)".*/\1/p' "$package_json" | head -1)"
  fi
  printf "%s" "${version:-$DEFAULT_NEMOCLAW_VERSION}"
}

NEMOCLAW_VERSION="$(resolve_installer_version)"

resolve_release_tag() {
  printf "%s" "${NEMOCLAW_INSTALL_TAG:-latest}"
}

# ---------------------------------------------------------------------------
# Color / style
# ---------------------------------------------------------------------------
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
  if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
    C_GREEN=$'\033[38;2;118;185;0m'
  else
    C_GREEN=$'\033[38;5;148m'
  fi
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'
  C_YELLOW=$'\033[1;33m'
  C_CYAN=$'\033[1;36m'
  C_RESET=$'\033[0m'
else
  C_GREEN='' C_BOLD='' C_DIM='' C_RED='' C_YELLOW='' C_CYAN='' C_RESET=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { printf "${C_CYAN}[INFO]${C_RESET}  %s\n" "$*"; }
warn() { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*"; }
error() {
  printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2
  exit 1
}
ok() { printf "  ${C_GREEN}✓${C_RESET}  %s\n" "$*"; }

step() {
  local n=$1 msg=$2
  printf "\n${C_GREEN}[%s/%s]${C_RESET} ${C_BOLD}%s${C_RESET}\n" \
    "$n" "$TOTAL_STEPS" "$msg"
  printf "  ${C_DIM}──────────────────────────────────────────────────${C_RESET}\n"
}

print_banner() {
  printf "\n"
  printf "  ${C_GREEN}${C_BOLD} ███╗   ██╗███████╗███╗   ███╗ ██████╗  ██████╗██╗      █████╗ ██╗    ██╗${C_RESET}\n"
  printf "  ${C_GREEN}${C_BOLD} ████╗  ██║██╔════╝████╗ ████║██╔═══██╗██╔════╝██║     ██╔══██╗██║    ██║${C_RESET}\n"
  printf "  ${C_GREEN}${C_BOLD} ██╔██╗ ██║█████╗  ██╔████╔██║██║   ██║██║     ██║     ███████║██║ █╗ ██║${C_RESET}\n"
  printf "  ${C_GREEN}${C_BOLD} ██║╚██╗██║██╔══╝  ██║╚██╔╝██║██║   ██║██║     ██║     ██╔══██║██║███╗██║${C_RESET}\n"
  printf "  ${C_GREEN}${C_BOLD} ██║ ╚████║███████╗██║ ╚═╝ ██║╚██████╔╝╚██████╗███████╗██║  ██║╚███╔███╔╝${C_RESET}\n"
  printf "  ${C_GREEN}${C_BOLD} ╚═╝  ╚═══╝╚══════╝╚═╝     ╚═╝ ╚═════╝  ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝${C_RESET}\n"
  printf "\n"
  printf "  ${C_DIM}Conda environment installer.  v%s${C_RESET}\n" "$NEMOCLAW_VERSION"
  printf "\n"
}

# spin "label" cmd [args...]
spin() {
  local msg="$1"
  shift

  if [[ ! -t 1 ]]; then
    info "$msg"
    "$@"
    return
  fi

  local log
  log=$(mktemp)
  "$@" >"$log" 2>&1 &
  local pid=$! i=0
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

  _cleanup_pids+=("$pid")
  _cleanup_files+=("$log")
  trap 'kill "$pid" 2>/dev/null; rm -f "$log"; exit 130' INT TERM

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${C_GREEN}%s${C_RESET}  %s" "${frames[$((i++ % 10))]}" "$msg"
    sleep 0.08
  done

  trap - INT TERM

  local status=0
  wait "$pid" || status=$?

  if [[ $status -eq 0 ]]; then
    printf "\r  ${C_GREEN}✓${C_RESET}  %s\n" "$msg"
  else
    printf "\r  ${C_RED}✗${C_RESET}  %s\n\n" "$msg"
    cat "$log" >&2
    printf "\n"
  fi
  rm -f "$log"

  _cleanup_pids=("${_cleanup_pids[@]/$pid/}")
  _cleanup_files=("${_cleanup_files[@]/$log/}")
  return $status
}

command_exists() { command -v "$1" &>/dev/null; }

# Compare two semver strings. Returns 0 if $1 >= $2.
version_gte() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  [[ "$2" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  local -a a b
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for i in 0 1 2; do
    local ai=${a[$i]:-0} bi=${b[$i]:-0}
    if ((ai > bi)); then return 0; fi
    if ((ai < bi)); then return 1; fi
  done
  return 0
}

version_major() { printf '%s\n' "${1#v}" | cut -d. -f1; }

MIN_NODE_VERSION="22.16.0"
MIN_NPM_MAJOR=10

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  printf "\n"
  printf "  ${C_BOLD}NemoClaw Conda Installer${C_RESET}  ${C_DIM}v%s${C_RESET}\n\n" "$NEMOCLAW_VERSION"
  printf "  ${C_DIM}Usage:${C_RESET}\n"
  printf "    bash install-conda.sh --conda-env <name> [options]\n\n"
  printf "  ${C_DIM}Required:${C_RESET}\n"
  printf "    --conda-env <name>   Name of the conda environment to create or reuse\n\n"
  printf "  ${C_DIM}Options:${C_RESET}\n"
  printf "    --reprocess          Reinstall into an existing conda environment\n"
  printf "    --non-interactive    Skip prompts (uses env vars / defaults)\n"
  printf "    --version, -v        Print installer version and exit\n"
  printf "    --help, -h           Show this help message and exit\n\n"
  printf "  ${C_DIM}Environment:${C_RESET}\n"
  printf "    NVIDIA_API_KEY                API key (skips credential prompt)\n"
  printf "    NEMOCLAW_NON_INTERACTIVE=1    Same as --non-interactive\n"
  printf "    NEMOCLAW_SANDBOX_NAME         Sandbox name to create/use\n"
  printf "    NEMOCLAW_RECREATE_SANDBOX=1   Recreate an existing sandbox\n"
  printf "    NEMOCLAW_INSTALL_TAG          Branch or tag to install (default: latest release)\n"
  printf "    NEMOCLAW_PROVIDER             cloud | ollama | nim | vllm\n"
  printf "    NEMOCLAW_MODEL                Inference model to configure\n"
  printf "    NEMOCLAW_POLICY_MODE          suggested | custom | skip\n"
  printf "    NEMOCLAW_POLICY_PRESETS       Comma-separated policy presets\n"
  printf "\n"
}

# ---------------------------------------------------------------------------
# Step 1 — Conda environment
# ---------------------------------------------------------------------------

# Locate the conda base and source the init script so that `conda activate`
# works inside a non-interactive bash session.
activate_conda_init() {
  local conda_base
  conda_base="$(conda info --base 2>/dev/null)" || error "conda info --base failed"
  local init_script="${conda_base}/etc/profile.d/conda.sh"
  if [[ ! -f "$init_script" ]]; then
    error "conda init script not found at ${init_script}. Re-run 'conda init bash' and try again."
  fi
  # shellcheck source=/dev/null
  source "$init_script"
}

conda_env_exists() {
  local env_name="$1"
  conda env list 2>/dev/null \
    | awk '{print $1}' \
    | grep -Fxq -- "$env_name"
}

ensure_conda_env() {
  local env_name="$1"
  local reprocess="$2"

  if conda_env_exists "$env_name"; then
    if [[ "$reprocess" != "true" ]]; then
      warn "Conda environment '${env_name}' already exists."
      warn "Re-run with --reprocess to reinstall NemoClaw into the existing environment."
      exit 0
    fi
    warn "Conda environment '${env_name}' already exists — continuing (--reprocess)."
  else
    info "Creating conda environment '${env_name}' with Python 3.12 and Node.js 22…"
    spin "Creating conda env '${env_name}'" \
      conda create -y -n "$env_name" -c conda-forge \
        "python>=3.12,<3.13" \
        "nodejs>=22.16"
    ok "Conda environment '${env_name}' created."
  fi
}

# ---------------------------------------------------------------------------
# Step 2 — OpenShell
# ---------------------------------------------------------------------------
OPENSHELL_MIN_VERSION="0.0.7"

openshell_version_gte() {
  # Returns 0 (true) if $1 >= $2 — portable, no sort -V
  local IFS=.
  local -a a b
  read -r -a a <<<"$1"
  read -r -a b <<<"$2"
  for i in 0 1 2; do
    local ai=${a[$i]:-0} bi=${b[$i]:-0}
    if ((ai > bi)); then return 0; fi
    if ((ai < bi)); then return 1; fi
  done
  return 0
}

install_openshell_to_prefix() {
  local prefix="$1"  # e.g. /path/to/conda/envs/myenv
  local target_dir="${prefix}/bin"
  local openshell_bin="${target_dir}/openshell"

  # Check existing installation inside the prefix
  if [[ -x "$openshell_bin" ]]; then
    local installed_version
    installed_version="$("$openshell_bin" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo '0.0.0')"
    if openshell_version_gte "$installed_version" "$OPENSHELL_MIN_VERSION"; then
      info "openshell ${installed_version} already installed in conda env (>= ${OPENSHELL_MIN_VERSION})"
      return 0
    fi
    warn "openshell ${installed_version} is below minimum ${OPENSHELL_MIN_VERSION} — reinstalling…"
  fi

  local OS ARCH ASSET
  OS="$(uname -s)"
  ARCH="$(uname -m)"

  case "$OS" in
    Darwin)
      case "$ARCH" in
        x86_64 | amd64)   ASSET="openshell-x86_64-apple-darwin.tar.gz" ;;
        aarch64 | arm64)  ASSET="openshell-aarch64-apple-darwin.tar.gz" ;;
        *) error "Unsupported architecture for macOS: $ARCH" ;;
      esac
      ;;
    Linux)
      case "$ARCH" in
        x86_64 | amd64)   ASSET="openshell-x86_64-unknown-linux-musl.tar.gz" ;;
        aarch64 | arm64)  ASSET="openshell-aarch64-unknown-linux-musl.tar.gz" ;;
        *) error "Unsupported architecture for Linux: $ARCH" ;;
      esac
      ;;
    *) error "Unsupported OS: $OS" ;;
  esac

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  local CHECKSUM_FILE="openshell-checksums-sha256.txt"

  info "Downloading openshell ${ASSET}…"
  if command_exists gh; then
    GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" gh release download --repo NVIDIA/OpenShell \
      --pattern "$ASSET" --dir "$tmpdir"
    GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" gh release download --repo NVIDIA/OpenShell \
      --pattern "$CHECKSUM_FILE" --dir "$tmpdir"
  else
    curl -fsSL "https://github.com/NVIDIA/OpenShell/releases/latest/download/${ASSET}" \
      -o "${tmpdir}/${ASSET}"
    curl -fsSL "https://github.com/NVIDIA/OpenShell/releases/latest/download/${CHECKSUM_FILE}" \
      -o "${tmpdir}/${CHECKSUM_FILE}"
  fi

  info "Verifying SHA-256 checksum…"
  if command_exists shasum; then
    (cd "$tmpdir" && grep -F "$ASSET" "$CHECKSUM_FILE" | shasum -a 256 -c -) \
      || error "SHA-256 checksum verification failed for $ASSET"
  else
    (cd "$tmpdir" && grep -F "$ASSET" "$CHECKSUM_FILE" | sha256sum -c -) \
      || error "SHA-256 checksum verification failed for $ASSET"
  fi

  tar xzf "${tmpdir}/${ASSET}" -C "$tmpdir"
  install -m 755 "${tmpdir}/openshell" "${openshell_bin}"
  ok "openshell $("${openshell_bin}" --version 2>&1 || echo installed) → ${openshell_bin}"
}

# ---------------------------------------------------------------------------
# Step 3 — NemoClaw CLI
# ---------------------------------------------------------------------------

# Work around openclaw tarball missing directory entries (GH-503).
pre_extract_openclaw() {
  local install_dir="$1"
  local openclaw_version
  openclaw_version=$(node -e "console.log(require('${install_dir}/package.json').dependencies.openclaw)" 2>/dev/null || echo "")

  if [[ -z "$openclaw_version" ]]; then
    warn "Could not determine openclaw version — skipping pre-extraction"
    return 1
  fi

  info "Pre-extracting openclaw@${openclaw_version} with system tar (GH-503 workaround)…"
  local tmpdir
  tmpdir="$(mktemp -d)"
  if npm pack "openclaw@${openclaw_version}" --pack-destination "$tmpdir" >/dev/null 2>&1; then
    local tgz
    tgz="$(find "$tmpdir" -maxdepth 1 -name 'openclaw-*.tgz' -print -quit)"
    if [[ -n "$tgz" && -f "$tgz" ]]; then
      if mkdir -p "${install_dir}/node_modules/openclaw" \
        && tar xzf "$tgz" -C "${install_dir}/node_modules/openclaw" --strip-components=1; then
        info "openclaw pre-extracted successfully"
      else
        warn "Failed to extract openclaw tarball"
        rm -rf "$tmpdir"
        return 1
      fi
    else
      warn "npm pack succeeded but tarball not found"
      rm -rf "$tmpdir"
      return 1
    fi
  else
    warn "Failed to download openclaw tarball"
    rm -rf "$tmpdir"
    return 1
  fi
  rm -rf "$tmpdir"
}

install_nemoclaw() {
  command_exists git || error "git was not found on PATH."

  if [[ -f "./package.json" ]] && grep -q '"name": "nemoclaw"' ./package.json 2>/dev/null; then
    info "NemoClaw package.json found in current directory — installing from source…"
    spin "Preparing OpenClaw package" bash -c \
      "$(declare -f info warn pre_extract_openclaw); pre_extract_openclaw \"\$1\"" \
      _ "$(pwd)" \
      || warn "Pre-extraction failed — npm install may fail if openclaw tarball is broken"
    spin "Installing NemoClaw dependencies" npm install --ignore-scripts
    spin "Building NemoClaw plugin" bash -c 'cd nemoclaw && npm install --ignore-scripts && npm run build'
    spin "Linking NemoClaw CLI" npm link
  else
    info "Installing NemoClaw from GitHub…"
    local release_ref
    release_ref="$(resolve_release_tag)"
    info "Resolved install ref: ${release_ref}"
    local nemoclaw_src="${HOME}/.nemoclaw/source"
    rm -rf "$nemoclaw_src"
    mkdir -p "$(dirname "$nemoclaw_src")"
    spin "Cloning NemoClaw source" \
      git clone --depth 1 --branch "$release_ref" \
        https://github.com/NVIDIA/NemoClaw.git "$nemoclaw_src"
    spin "Preparing OpenClaw package" bash -c \
      "$(declare -f info warn pre_extract_openclaw); pre_extract_openclaw \"\$1\"" \
      _ "$nemoclaw_src" \
      || warn "Pre-extraction failed — npm install may fail if openclaw tarball is broken"
    spin "Installing NemoClaw dependencies" bash -c \
      "cd \"$nemoclaw_src\" && npm install --ignore-scripts"
    spin "Building NemoClaw plugin" bash -c \
      "cd \"$nemoclaw_src\"/nemoclaw && npm install --ignore-scripts && npm run build"
    spin "Linking NemoClaw CLI" bash -c \
      "cd \"$nemoclaw_src\" && npm link"
  fi
}

verify_nemoclaw() {
  if command_exists nemoclaw; then
    info "Verified: nemoclaw available at $(command -v nemoclaw)"
    return 0
  fi
  error "Installation failed: nemoclaw binary not found after npm link. Check npm link output above."
}

ensure_supported_runtime() {
  command_exists node || error "Node.js not found in conda env."
  command_exists npm  || error "npm not found in conda env."

  local node_version npm_version node_major npm_major
  node_version="$(node --version 2>/dev/null || true)"
  npm_version="$(npm --version 2>/dev/null || true)"
  node_major="$(version_major "$node_version")"
  npm_major="$(version_major "$npm_version")"

  [[ "$node_major" =~ ^[0-9]+$ ]] \
    || error "Could not determine Node.js version from '${node_version}'."
  [[ "$npm_major" =~ ^[0-9]+$ ]] \
    || error "Could not determine npm version from '${npm_version}'."

  if ! version_gte "${node_version#v}" "$MIN_NODE_VERSION" \
     || ((npm_major < MIN_NPM_MAJOR)); then
    error "Runtime check failed: Node.js ${node_version}, npm ${npm_version}." \
          "Conda env must provide Node.js >=${MIN_NODE_VERSION} and npm >=${MIN_NPM_MAJOR}."
  fi

  info "Runtime OK: Node.js ${node_version}, npm ${npm_version}"
}

# ---------------------------------------------------------------------------
# Step 4 — Onboarding
# ---------------------------------------------------------------------------
resolve_default_sandbox_name() {
  local registry_file="${HOME}/.nemoclaw/sandboxes.json"
  local sandbox_name="${NEMOCLAW_SANDBOX_NAME:-}"

  if [[ -z "$sandbox_name" && -f "$registry_file" ]] && command_exists node; then
    sandbox_name="$(
      node -e '
        const fs = require("fs");
        const file = process.argv[1];
        try {
          const data = JSON.parse(fs.readFileSync(file, "utf8"));
          const sandboxes = data.sandboxes || {};
          const preferred = data.defaultSandbox;
          const name = (preferred && sandboxes[preferred] && preferred) || Object.keys(sandboxes)[0] || "";
          process.stdout.write(name);
        } catch {}
      ' "$registry_file" 2>/dev/null || true
    )"
  fi

  printf "%s" "${sandbox_name:-my-assistant}"
}

run_onboard() {
  info "Running nemoclaw onboard…"
  local -a onboard_cmd=(onboard)
  if command_exists node && [[ -f "${HOME}/.nemoclaw/onboard-session.json" ]]; then
    if node -e '
      const fs = require("fs");
      const file = process.argv[1];
      try {
        const data = JSON.parse(fs.readFileSync(file, "utf8"));
        const resumable = data && data.resumable !== false;
        const status = data && data.status;
        process.exit(resumable && status && status !== "complete" ? 0 : 1);
      } catch {
        process.exit(1);
      }
    ' "${HOME}/.nemoclaw/onboard-session.json"; then
      info "Found an interrupted onboarding session — resuming it."
      onboard_cmd+=(--resume)
    fi
  fi
  if [[ "${NON_INTERACTIVE:-}" == "1" ]]; then
    onboard_cmd+=(--non-interactive)
    nemoclaw "${onboard_cmd[@]}"
  elif [[ -t 0 ]]; then
    nemoclaw "${onboard_cmd[@]}"
  elif exec 3</dev/tty; then
    info "Installer stdin is piped; attaching onboarding to /dev/tty…"
    local status=0
    nemoclaw "${onboard_cmd[@]}" <&3 || status=$?
    exec 3<&-
    return "$status"
  else
    error "Interactive onboarding requires a TTY. Re-run in a terminal or set NEMOCLAW_NON_INTERACTIVE=1."
  fi
}

print_done() {
  local elapsed=$((SECONDS - _INSTALL_START))
  info "=== Installation complete ==="
  printf "\n"
  printf "  ${C_GREEN}${C_BOLD}NemoClaw${C_RESET}  ${C_DIM}in conda env '${CONDA_ENV_NAME}' (%ss)${C_RESET}\n" "$elapsed"
  printf "\n"
  printf "  ${C_GREEN}To activate the environment:${C_RESET}\n"
  printf "  %s\$%s conda activate %s\n" "$C_GREEN" "$C_RESET" "$CONDA_ENV_NAME"
  printf "\n"
  if [[ "${ONBOARD_RAN:-false}" == true ]]; then
    local sandbox_name
    sandbox_name="$(resolve_default_sandbox_name)"
    printf "  ${C_GREEN}Your OpenClaw Sandbox is live.${C_RESET}\n"
    printf "\n"
    printf "  ${C_GREEN}Next:${C_RESET}\n"
    printf "  %s\$%s nemoclaw %s connect\n" "$C_GREEN" "$C_RESET" "$sandbox_name"
    printf "  %ssandbox@%s\$%s openclaw tui\n" "$C_GREEN" "$sandbox_name" "$C_RESET"
  else
    printf "  ${C_GREEN}Next:${C_RESET}\n"
    printf "  %s\$%s conda activate %s\n" "$C_GREEN" "$C_RESET" "$CONDA_ENV_NAME"
    printf "  %s\$%s nemoclaw onboard\n" "$C_GREEN" "$C_RESET"
  fi
  printf "\n"
  printf "  ${C_BOLD}GitHub${C_RESET}  ${C_DIM}https://github.com/nvidia/nemoclaw${C_RESET}\n"
  printf "  ${C_BOLD}Docs${C_RESET}    ${C_DIM}https://docs.nvidia.com/nemoclaw/latest/${C_RESET}\n"
  printf "\n"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  CONDA_ENV_NAME=""
  REPROCESS=false
  NON_INTERACTIVE=""
  ONBOARD_RAN=false

  # Parse flags
  local i=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --conda-env)
        [[ $# -ge 2 ]] || { usage; error "--conda-env requires a value"; }
        CONDA_ENV_NAME="$2"
        shift 2
        ;;
      --conda-env=*)
        CONDA_ENV_NAME="${1#--conda-env=}"
        shift
        ;;
      --reprocess)
        REPROCESS=true
        shift
        ;;
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      --version | -v)
        printf "nemoclaw-conda-installer v%s\n" "$NEMOCLAW_VERSION"
        exit 0
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        usage
        error "Unknown option: $1"
        ;;
    esac
    ((i++)) || true
  done

  if [[ -z "$CONDA_ENV_NAME" ]]; then
    usage
    error "--conda-env <name> is required."
  fi

  # Validate env name (no slashes or spaces)
  if [[ "$CONDA_ENV_NAME" =~ [[:space:]/] ]]; then
    error "Invalid conda env name '${CONDA_ENV_NAME}': must not contain spaces or slashes."
  fi

  NON_INTERACTIVE="${NON_INTERACTIVE:-${NEMOCLAW_NON_INTERACTIVE:-}}"
  export NEMOCLAW_NON_INTERACTIVE="${NON_INTERACTIVE}"

  _INSTALL_START=$SECONDS
  print_banner

  # ── Verify conda is available ─────────────────────────────────────────────
  if ! command_exists conda; then
    warn "conda not found on PATH."
    warn "Install Miniconda or Anaconda and ensure 'conda' is available, then re-run."
    exit 1
  fi
  info "conda found: $(conda --version 2>&1)"

  # Verify external tools used by OpenShell download and checksum verification.
  if ! command_exists gh && ! command_exists curl; then
    error "Missing required download tool: install 'gh' or 'curl' to download OpenShell releases."
  fi
  if ! command_exists shasum && ! command_exists sha256sum; then
    error "Missing required checksum tool: install 'shasum' or 'sha256sum' to verify OpenShell downloads."
  fi

  # ── Step 1: Conda environment ─────────────────────────────────────────────
  step 1 "Conda environment"
  ensure_conda_env "$CONDA_ENV_NAME" "$REPROCESS"

  # Activate the environment so all subsequent commands run inside it.
  info "Activating conda environment '${CONDA_ENV_NAME}'…"
  activate_conda_init
  conda activate "$CONDA_ENV_NAME"
  ok "Active environment: ${CONDA_PREFIX}"

  # The conda env's node/npm are now first on PATH (conda puts $CONDA_PREFIX/bin
  # at the front of PATH on activation).  Verify the runtime before proceeding.
  ensure_supported_runtime

  # Ensure npm global installs go into $CONDA_PREFIX for this run only.
  export NPM_CONFIG_PREFIX="$CONDA_PREFIX"

  # ── Step 2: OpenShell ─────────────────────────────────────────────────────
  step 2 "OpenShell"
  install_openshell_to_prefix "$CONDA_PREFIX"

  # ── Step 3: NemoClaw CLI ──────────────────────────────────────────────────
  step 3 "NemoClaw CLI"
  install_nemoclaw
  verify_nemoclaw

  # ── Step 4: Onboarding ────────────────────────────────────────────────────
  step 4 "Onboarding"
  if command_exists nemoclaw; then
    run_onboard
    ONBOARD_RAN=true
  else
    warn "Skipping onboarding — nemoclaw is not resolvable in this shell."
  fi

  print_done
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]] || { [[ -z "${BASH_SOURCE[0]:-}" ]] && { [[ "$0" == "bash" ]] || [[ "$0" == "-bash" ]]; }; }; then
  main "$@"
fi
