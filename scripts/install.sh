#!/usr/bin/env bash
set -euo pipefail

GITHUB_REPO="ViveportSoftware/ai-token-meter"
INSTALL_DIR="${HOME}/.local/bin"
PROXY_URL="http://localhost:40080"
# Installer release channel/tag. CI can stamp this to a fixed tag for immutable installs.
DEFAULT_RELEASE_TAG="latest"

DRY_RUN=false
UNINSTALL=false
COPILOT=false
CLI_COPILOT=false
NON_INTERACTIVE=false
UPSTREAM_URL_CLI=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    --copilot)
      COPILOT=true
      CLI_COPILOT=true
      shift
      ;;
    --yes|--non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --upstream-url)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --upstream-url requires a value" >&2
        exit 1
      fi
      UPSTREAM_URL_CLI="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--dry-run] [--uninstall] [--copilot] [--yes] [--upstream-url <url>]"
      echo "  --copilot             Enable MITM forward proxy for GitHub Copilot tracking"
      echo "  --yes                 Non-interactive install (skip Q&A, use flag values / defaults)"
      echo "  --upstream-url <url>  LLM upstream URL (default: https://api.openai.com)"
      exit 1
      ;;
  esac
done

detect_shell_profile() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if [[ -f "$HOME/.zshrc" ]]; then
      echo "$HOME/.zshrc"
    elif [[ -f "$HOME/.zprofile" ]]; then
      echo "$HOME/.zprofile"
    else
      echo "$HOME/.zshrc"
    fi
  else
    echo "$HOME/.bashrc"
  fi
}

detect_platform() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$os" in
    darwin) os="darwin" ;;
    linux)  os="linux"  ;;
    *)      echo "Unsupported OS: ${os}" >&2; exit 1 ;;
  esac
  case "$arch" in
    x86_64)        arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)             echo "Unsupported architecture: ${arch}" >&2; exit 1 ;;
  esac
  echo "${os}-${arch}"
}

generate_user_id() {
  local hostname_part email_part
  hostname_part=$(hostname)
  email_part=$(git config user.email 2>/dev/null | cut -d@ -f1 || echo "unknown")
  echo "${hostname_part}-${email_part}"
}

# ask <prompt> <default>  → reads from /dev/tty so curl|bash works
ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    printf "%s [%s]: " "$prompt" "$default" > /dev/tty
  else
    printf "%s: " "$prompt" > /dev/tty
  fi
  read -r answer < /dev/tty
  echo "${answer:-$default}"
}

# ask_yn <prompt> <default y|n>  → returns 0 (yes) or 1 (no)
ask_yn() {
  local prompt="$1"
  local default="${2:-n}"
  local hint
  if [[ "$default" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
  local answer
  printf "%s [%s]: " "$prompt" "$hint" > /dev/tty
  read -r answer < /dev/tty
  answer="${answer:-$default}"
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

interactive_setup() {
  # Sets globals: UPSTREAM_URL ENABLE_COPILOT CONFIGURE_VSCODE
  echo ""
  echo "┌─────────────────────────────────────────────┐"
  echo "│        AI Token Meter (ATM) Setup           │"
  echo "└─────────────────────────────────────────────┘"
  echo ""

  # 1. Upstream URL
  UPSTREAM_URL=$(ask "LLM upstream URL" "https://api.openai.com")

  # 2. Copilot
  echo ""
  if [[ "$CLI_COPILOT" == true ]]; then
    echo "  [--copilot] GitHub Copilot tracking enabled via CLI flag."
    ENABLE_COPILOT=true
  else
    echo "GitHub Copilot tracking requires MITM forward proxy mode."
    echo "ATM will intercept HTTPS traffic and its CA cert must be trusted system-wide."
    if ask_yn "Enable GitHub Copilot tracking (forward proxy + CA cert trust)?" "n"; then
      ENABLE_COPILOT=true
      COPILOT=true
    else
      ENABLE_COPILOT=false
    fi
  fi

  # 3. VS Code (only ask if settings file exists)
  local vscode_settings
  if [[ "$OSTYPE" == "darwin"* ]]; then
    vscode_settings="$HOME/Library/Application Support/Code/User/settings.json"
  else
    vscode_settings="$HOME/.config/Code/User/settings.json"
  fi

  CONFIGURE_VSCODE=false
  if [[ -f "$vscode_settings" ]]; then
    echo ""
    if ask_yn "Configure VS Code to route traffic through ATM (sets http.proxy)?" "y"; then
      CONFIGURE_VSCODE=true
    fi
  fi

  echo ""
}

add_line_to_profile() {
  local profile="$1"
  local line="$2"
  if [[ -f "$profile" ]] && grep -qF "$line" "$profile" 2>/dev/null; then
    echo "  [skip] already in ${profile}: ${line}"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] Would add to ${profile}: ${line}"
  else
    echo "$line" >> "$profile"
    echo "  [set] ${line}"
  fi
}

remove_from_profile() {
   local profile="$1"
   if [[ ! -f "$profile" ]]; then
     echo "  [skip] ${profile} does not exist"
     return 0
   fi
   if [[ "$DRY_RUN" == true ]]; then
     echo "  [dry-run] Would remove OPENAI_API_BASE, ANTHROPIC_BASE_URL and ATM PATH entry from ${profile}"
   else
     local temp_file
     temp_file=$(mktemp)
     grep -vE '^export OPENAI_API_BASE=|^export ANTHROPIC_BASE_URL=|^export PATH="\$\{HOME\}/\.local/bin:\$\{PATH\}"$' "$profile" > "$temp_file" || true
     mv "$temp_file" "$profile"
     echo "  [removed] OPENAI_API_BASE, ANTHROPIC_BASE_URL and ATM PATH entry from ${profile}"
   fi
}

download_binary() {
  local platform="$1"
  local binary_name="atm-${platform}"
  local dest="${INSTALL_DIR}/atm"

  local requested_tag resolved_tag
  requested_tag="${ATM_RELEASE_TAG:-$DEFAULT_RELEASE_TAG}"

  if [[ "$requested_tag" == "latest" ]]; then
    resolved_tag=$(curl -sf --connect-timeout 10 --max-time 30 \
      "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["tag_name"])' 2>/dev/null || true)
  else
    resolved_tag="$requested_tag"
  fi

  if [[ -z "$resolved_tag" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "  [dry-run] Would download latest release (tag unavailable in dry-run)"
      return 0
    fi
    echo "  [error] Could not fetch latest release from GitHub. Is ${GITHUB_REPO} reachable?" >&2
    exit 1
  fi

  local url="https://github.com/${GITHUB_REPO}/releases/download/${resolved_tag}/${binary_name}"
  local checksums_url="https://github.com/${GITHUB_REPO}/releases/download/${resolved_tag}/checksums.txt"

  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] Would download ${url}"
    echo "  [dry-run] Would verify checksum from ${checksums_url}"
    echo "  [dry-run] Would install to ${dest}"
    return 0
  fi

  if ! command -v shasum &>/dev/null; then
    echo "  [error] shasum is required for checksum verification" >&2
    exit 1
  fi

  mkdir -p "${INSTALL_DIR}"
  echo "  Downloading atm ${resolved_tag} (${platform})..."

  local tmp_bin tmp_checksums expected actual
  tmp_bin=$(mktemp)
  tmp_checksums=$(mktemp)

  curl -fL --connect-timeout 10 --max-time 120 "$url" -o "$tmp_bin"
  curl -fL --connect-timeout 10 --max-time 60 "$checksums_url" -o "$tmp_checksums"

  expected=$(grep "  ${binary_name}$" "$tmp_checksums" | awk '{print $1}' || true)
  if [[ -z "$expected" ]]; then
    rm -f "$tmp_bin" "$tmp_checksums"
    echo "  [error] Could not find checksum entry for ${binary_name}" >&2
    exit 1
  fi

  actual=$(shasum -a 256 "$tmp_bin" | awk '{print $1}')
  if [[ "$expected" != "$actual" ]]; then
    rm -f "$tmp_bin" "$tmp_checksums"
    echo "  [error] Checksum verification failed for ${binary_name}" >&2
    echo "          expected=${expected}" >&2
    echo "          actual=${actual}" >&2
    exit 1
  fi

  mv "$tmp_bin" "$dest"
  rm -f "$tmp_checksums"
  chmod +x "$dest"
  echo "  [installed] ${dest}"
}

write_config() {
  local config_dir="$HOME/.atm"
  local config_file="$config_dir/config.yaml"
  local upstream_url="$1"
  local user_id="$2"
  local enable_forward_proxy="$3"

  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] Would write ${config_file}"
    echo "            openai_upstream_url=${upstream_url}"
    echo "            identity.default_user_id=${user_id}"
    echo "            forward_proxy.enabled=${enable_forward_proxy}"
    return 0
  fi

  # Do not overwrite an existing config — user may have customised it
  if [[ -f "$config_file" ]]; then
    echo "  [skip] ${config_file} already exists (not overwritten)"
    return 0
  fi

  mkdir -p "$config_dir"

  local forward_proxy_block="forward_proxy:
  enabled: false
  ca_cert_path: ~/.atm/ca.crt
  ca_key_path: ~/.atm/ca.key"

  if [[ "$enable_forward_proxy" == true ]]; then
    forward_proxy_block="forward_proxy:
  enabled: true
  ca_cert_path: ~/.atm/ca.crt
  ca_key_path: ~/.atm/ca.key"
  fi

  cat > "$config_file" <<YAML
listen_addr: ":40080"
openai_upstream_url: "${upstream_url}"
anthropic_upstream_url: "https://api.anthropic.com"
metrics_path: "/metrics"
log_format: "json"
log_level: "info"

identity:
  default_user_id: "${user_id}"
  header_name: "X-ATM-User-ID"
  tool_header_name: "X-ATM-Tool-ID"
  tools:
    - name: "aider"
      user_agent_contains: ["aider"]
    - name: "opencode"
      user_agent_contains: ["opencode"]
    - name: "continue"
      user_agent_contains: ["continue"]
    - name: "cursor"
      user_agent_contains: ["cursor"]
    - name: "cursor"
      headers:
        x-cursor-client-version: "*"
    - name: "claude"
      user_agent_contains: ["claude"]
    - name: "cline"
      headers:
        x-title: "Cline"
    - name: "codex"
      user_agent_contains: ["codex"]
    - name: "copilot"
      user_agent_contains: ["githubcopilotchat", "copilot"]

audit:
  enabled: true
  db_path: ~/.atm/audit.db
  retention_days: 30
  buffer_size: 1000
  flush_interval_seconds: 5

${forward_proxy_block}
YAML

  echo "  [written] ${config_file}"
}

trust_ca_cert() {
  local ca_cert="$HOME/.atm/ca.crt"

  if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "  [skip] CA cert trust automation is macOS-only"
    echo "         On Linux, manually add ${ca_cert} to your system trust store"
    return 0
  fi

  if [[ ! -f "$ca_cert" ]]; then
    echo "  [skip] CA cert not found at ${ca_cert} — start atm once to generate it, then run:"
    echo "         sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${ca_cert}"
    return 0
  fi

  if security find-certificate -c "ATM" /Library/Keychains/System.keychain &>/dev/null; then
    echo "  [skip] CA cert already trusted in system keychain"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] Would trust CA cert: ${ca_cert}"
    return 0
  fi

  echo "  Trusting ATM CA cert (requires sudo)..."
  sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain "$ca_cert"
  echo "  [trusted] ${ca_cert}"
}

configure_vscode() {
  local vscode_settings
  if [[ "$OSTYPE" == "darwin"* ]]; then
    vscode_settings="$HOME/Library/Application Support/Code/User/settings.json"
  else
    vscode_settings="$HOME/.config/Code/User/settings.json"
  fi

  if [[ ! -f "$vscode_settings" ]]; then
    echo "  [skip] VS Code user settings not found at ${vscode_settings}"
    echo "         To configure manually, add to settings.json:"
    echo '           "http.proxy": "http://localhost:40080",'
    echo '           "http.proxyStrictSSL": true'
    return 0
  fi

  if grep -q '"http.proxy"' "$vscode_settings" 2>/dev/null; then
    echo "  [skip] VS Code http.proxy already configured"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] Would add http.proxy to ${vscode_settings}"
    return 0
  fi

  # Backup before modifying
  cp "$vscode_settings" "${vscode_settings}.atm-backup"

  # Update JSON safely using python3; restore backup on failure
  if ! python3 - "$vscode_settings" <<'PYEOF'
import json, sys
try:
    path = sys.argv[1]
    with open(path) as f:
        data = json.load(f)
    data["http.proxy"] = "http://localhost:40080"
    data["http.proxyStrictSSL"] = True
    with open(path, "w") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
        f.write("\n")
except Exception as e:
    print(f"Error updating settings: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
  then
    echo "  [error] Failed to update VS Code settings; restoring backup" >&2
    mv "${vscode_settings}.atm-backup" "$vscode_settings"
    return 1
  fi

  rm -f "${vscode_settings}.atm-backup"
  echo "  [set] http.proxy in ${vscode_settings}"
  echo "  [!] Restart VS Code for proxy settings to take effect"
}

main() {
  local profile user_id platform
  # globals set by interactive_setup (or flags):
  UPSTREAM_URL="https://api.openai.com"
  ENABLE_COPILOT=false
  CONFIGURE_VSCODE=false

  if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not installed" >&2
    exit 1
  fi

  profile=$(detect_shell_profile)
  user_id=$(generate_user_id)
  platform=$(detect_platform)

  if [[ "$UNINSTALL" == true ]]; then
    echo "Uninstalling AI Token Meter (ATM)..."
    remove_from_profile "$profile"
    rm -f "${INSTALL_DIR}/atm"
    echo "  [removed] ${INSTALL_DIR}/atm"
    if [[ "$DRY_RUN" == true ]]; then
      echo "  [dry-run] Would remove ${HOME}/.atm"
    else
      rm -rf "${HOME}/.atm"
      echo "  [removed] ${HOME}/.atm"
    fi
    echo ""
    echo "Done. Reload your shell: source ${profile}"
    return 0
  fi

  if [[ "$NON_INTERACTIVE" == true ]]; then
    UPSTREAM_URL="${UPSTREAM_URL_CLI:-https://api.openai.com}"
    ENABLE_COPILOT="$COPILOT"
    CONFIGURE_VSCODE=false
    echo "Non-interactive install."
  else
    interactive_setup
  fi
  echo "Platform: ${platform}"
  echo ""

  download_binary "$platform"
  echo ""

   add_line_to_profile "$profile" "export PATH=\"\${HOME}/.local/bin:\${PATH}\""
   add_line_to_profile "$profile" "export OPENAI_API_BASE=\"${PROXY_URL}\""
   add_line_to_profile "$profile" "export ANTHROPIC_BASE_URL=\"${PROXY_URL}\""
   echo ""

  write_config "$UPSTREAM_URL" "$user_id" "$COPILOT"
  echo ""

  if [[ "$COPILOT" == true ]]; then
    echo "Setting up GitHub Copilot forward proxy..."
    # Start atm briefly to generate CA cert, then stop it
    if [[ "$DRY_RUN" != true ]]; then
      "${INSTALL_DIR}/atm" &
      local atm_pid=$!
      local ca_cert="$HOME/.atm/ca.crt"
      local waited=0
      while [[ ! -f "$ca_cert" ]] && [[ $waited -lt 10 ]]; do
        sleep 0.5
        waited=$((waited + 1))
      done
      kill "$atm_pid" 2>/dev/null || true
      wait "$atm_pid" 2>/dev/null || true
      if [[ ! -f "$ca_cert" ]]; then
        echo "  [warn] CA cert not generated after 5s; run 'trust_ca_cert' manually after starting atm"
      fi
    fi
    trust_ca_cert
    echo ""
  fi

  if [[ "$CONFIGURE_VSCODE" == true ]]; then
    echo "Configuring VS Code..."
    configure_vscode
    echo ""
  fi

  echo "AI Token Meter (ATM) Setup Complete!"
  echo "  User ID:      ${user_id}"
  echo "  Upstream URL: ${UPSTREAM_URL}"
  echo "  Proxy URL:    ${PROXY_URL}"
  echo "  Binary:       ${INSTALL_DIR}/atm"
  echo "  Config:       ${HOME}/.atm/config.yaml"
  echo "  Profile:      ${profile}"
  echo ""
  echo "Next steps:"
  echo "  1. Reload your shell:  source ${profile}"
  echo "  2. Start atm daemon:   atm &"
  if [[ "$COPILOT" == true ]]; then
    echo "  3. Restart VS Code to activate the HTTP proxy setting"
  else
    echo "  3. Your AI tools will automatically route through: ${PROXY_URL}"
    echo "     To also track GitHub Copilot, rerun with: --copilot"
  fi
}

main "$@"
