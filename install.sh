#!/bin/bash
# claw wallet unified installer and runtime entrypoint for Linux/macOS
# Served at: https://test.clawwallet.cc/skills/install.sh
set -euo pipefail

if [[ "${BASH_SOURCE[0]:-}" == "-" ]]; then
    SCRIPT_DIR="$(pwd -P)"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

LEGACY_UPGRADE_MODE="0"
COMMAND="${1:-}"
if [[ -n "${CLAW_WALLET_INSTALL_DIR:-}" && -z "$COMMAND" ]]; then
    SCRIPT_DIR="$CLAW_WALLET_INSTALL_DIR"
    LEGACY_UPGRADE_MODE="1"
fi

cd "$SCRIPT_DIR"

CLAW_WALLET_BASE_URL="https://test.clawwallet.cc"

OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_TYPE="$(uname -m)"

BINARY_NAME="clay-sandbox-linux-amd64"
if [[ "$OS_TYPE" == "darwin" ]]; then
    if [[ "$ARCH_TYPE" == "arm64" ]]; then
        BINARY_NAME="clay-sandbox-darwin-arm64"
    else
        BINARY_NAME="clay-sandbox-darwin-amd64"
    fi
fi

BINARY_URL="${CLAW_WALLET_BASE_URL}/bin/${BINARY_NAME}"
BINARY_PATH="$SCRIPT_DIR/clay-sandbox"
PID_PATH="$SCRIPT_DIR/sandbox.pid"
LOG_PATH="$SCRIPT_DIR/sandbox.log"
ERR_LOG_PATH="$SCRIPT_DIR/sandbox_err.log"

download_file() {
    local url="$1"
    local target="$2"
    local tmp_target="${target}.download"
    curl -fsSL "$url" -o "$tmp_target"
    mv -f "$tmp_target" "$target"
}

download_skill_bundle() {
    echo "Downloading skill files from ${CLAW_WALLET_BASE_URL} ..."
    download_file "${CLAW_WALLET_BASE_URL}/skills/SKILL.md" "$SCRIPT_DIR/SKILL.md"
    download_file "${CLAW_WALLET_BASE_URL}/skills/install.sh" "$SCRIPT_DIR/install.sh"
    download_file "${CLAW_WALLET_BASE_URL}/skills/claw-wallet.sh" "$SCRIPT_DIR/claw-wallet.sh"
    chmod +x "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/claw-wallet.sh"
}

download_binary() {
    echo "Downloading sandbox binary from $BINARY_URL ..."
    download_file "$BINARY_URL" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
}

get_running_sandbox_pid() {
    if [[ ! -f "$PID_PATH" ]]; then
        return 1
    fi
    local pid_value
    pid_value="$(head -n 1 "$PID_PATH" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -z "$pid_value" ]]; then
        return 1
    fi
    if kill -0 "$pid_value" 2>/dev/null; then
        printf '%s\n' "$pid_value"
        return 0
    fi
    rm -f "$PID_PATH"
    return 1
}

prepare_log_paths() {
    local preferred_log="$LOG_PATH"
    local preferred_err="$ERR_LOG_PATH"
    local log_parent
    log_parent="$(dirname "$preferred_log")"
    mkdir -p "$log_parent" 2>/dev/null || true
    rm -f "$preferred_log" "$preferred_err" 2>/dev/null || true
    if : >"$preferred_log" 2>/dev/null && : >"$preferred_err" 2>/dev/null; then
        return 0
    fi

    local fallback_dir="${TMPDIR:-/tmp}/claw-wallet"
    mkdir -p "$fallback_dir"
    LOG_PATH="$fallback_dir/sandbox.log"
    ERR_LOG_PATH="$fallback_dir/sandbox_err.log"
    : >"$LOG_PATH"
    : >"$ERR_LOG_PATH"
    echo "Warning: could not use $preferred_log; using fallback logs in $fallback_dir"
}

start_sandbox() {
    local running_pid
    if running_pid="$(get_running_sandbox_pid)"; then
        echo "claw wallet sandbox is already running."
        echo "PID file: $PID_PATH"
        echo "Log files: $LOG_PATH , $ERR_LOG_PATH"
        return 0
    fi

    if [[ ! -x "$BINARY_PATH" ]]; then
        echo "claw wallet sandbox is not installed. Expected binary at: $BINARY_PATH"
        echo "Run: $SCRIPT_DIR/install.sh"
        return 1
    fi

    prepare_log_paths
    nohup "$BINARY_PATH" serve </dev/null >>"$LOG_PATH" 2>>"$ERR_LOG_PATH" &
    local proc_pid=$!
    disown "$proc_pid" 2>/dev/null || true
    echo "$proc_pid" >"$PID_PATH"
    echo "claw wallet sandbox launched in the background."
    echo "PID file: $PID_PATH"
    echo "Log files: $LOG_PATH , $ERR_LOG_PATH"
    if [[ -f "$SCRIPT_DIR/.env.clay" ]]; then
        echo "API auth: if HTTP returns 401, send header Authorization: Bearer <token> using AGENT_TOKEN or CLAY_AGENT_TOKEN from .env.clay (or agent_token in identity.json). See SKILL.md."
    fi
}

stop_sandbox() {
    if [ -f "$PID_PATH" ]; then
        local running_pid
        running_pid="$(get_running_sandbox_pid || true)"
        if [ -n "$running_pid" ]; then
            kill "$running_pid" 2>/dev/null || true
        fi
    fi
    if [[ -x "$BINARY_PATH" ]]; then
        "$BINARY_PATH" stop >/dev/null 2>&1 || true
    fi
    rm -f "$PID_PATH"
}

read_env_value() {
    local pattern="$1"
    local file="$2"
    awk -F= -v pattern="$pattern" '
        $0 ~ pattern {
            sub(/^[^=]*=/, "", $0)
            gsub(/["\047\r]/, "", $0)
            sub(/[[:space:]]*$/, "", $0)
            print
            exit
        }
    ' "$file" 2>/dev/null || true
}

do_wallet_init() {
    echo "Waiting for sandbox and initializing wallet ..."
    for i in $(seq 1 90); do
        CLAY_SANDBOX_URL=""
        AGENT_TOKEN=""
        if [ -f "$SCRIPT_DIR/.env.clay" ]; then
            CLAY_SANDBOX_URL="$(read_env_value '^CLAY_SANDBOX_URL=' "$SCRIPT_DIR/.env.clay")"
            AGENT_TOKEN="$(read_env_value '^(AGENT_TOKEN)=' "$SCRIPT_DIR/.env.clay")"
        fi
        if [ -z "${CLAY_SANDBOX_URL:-}" ]; then
            REASON=".env.clay (CLAY_SANDBOX_URL)"
        elif ! curl -s -f "${CLAY_SANDBOX_URL}/health" 2>/dev/null | grep -qE '"status"[[:space:]]*:[[:space:]]*"ok"'; then
            REASON="health ok at ${CLAY_SANDBOX_URL}"
        else
            echo "  Calling wallet/init ..."
            if [ -n "${AGENT_TOKEN:-}" ]; then
                if init_resp="$(curl -sS -f -X POST "${CLAY_SANDBOX_URL}/api/v1/wallet/init" \
                    -H "Authorization: Bearer ${AGENT_TOKEN}" \
                    -H "Content-Type: application/json" \
                    -d '{}' 2>/dev/null)"; then
                    if printf '%s' "$init_resp" | grep -qE '"uid"|"status"'; then
                        echo "Wallet initialized."
                        return 0
                    fi
                    echo "Wallet init request completed."
                    return 0
                else
                    REASON="wallet/init at ${CLAY_SANDBOX_URL}"
                fi
            elif init_resp="$(curl -sS -f -X POST "${CLAY_SANDBOX_URL}/api/v1/wallet/init" \
                -H "Content-Type: application/json" \
                -d '{}' 2>/dev/null)"; then
                if printf '%s' "$init_resp" | grep -qE '"uid"|"status"'; then
                    echo "Wallet initialized."
                    return 0
                fi
                echo "Wallet init request completed."
                return 0
            else
                REASON="wallet/init at ${CLAY_SANDBOX_URL}"
            fi
        fi
        [ "$((i % 10))" -eq 0 ] && echo "  Still waiting for ${REASON} ... (${i}s)"
        sleep 1
    done
    echo "Error: wallet init did not complete after 90s. Check sandbox.log, then run POST {CLAY_SANDBOX_URL}/api/v1/wallet/init manually. If AGENT_TOKEN is empty, local dev mode allows the request without Authorization. See SKILL.md." >&2
    return 1
}

print_final_messages() {
    echo "Check .env.clay for CLAY_SANDBOX_URL"
    echo "If you have set an AGENT_TOKEN, then HTTP clients (curl, agents) must call protected APIs with: Authorization: Bearer <same token>."
    echo "Sandbox start success. at: $BINARY_PATH"
}

install_or_upgrade() {
    local should_init="$1"
    stop_sandbox
    download_skill_bundle
    download_binary
    start_sandbox
    if [[ "$should_init" == "1" ]]; then
        do_wallet_init
    fi
    print_final_messages
}

uninstall_skill() {
    stop_sandbox
    echo
    echo "=== WARNING: Uninstall claw-wallet skill ==="
    echo "This will DELETE the entire skill directory and all wallet data."
    echo "Files to be removed: .env.clay, identity.json, share3.json, and all others."
    echo "This action is IRREVERSIBLE. Please backup .env.clay, identity.json, share3.json first if needed."
    echo
    local confirm=""
    read -r -p "Type 'yes' to confirm uninstall: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Uninstall cancelled."
        return 0
    fi
    echo "Removing $SCRIPT_DIR ..."
    local parent_dir
    parent_dir="$(dirname "$SCRIPT_DIR")"
    cd "$parent_dir"
    rm -rf "$SCRIPT_DIR"
    echo "claw-wallet skill has been uninstalled."
}

case "$COMMAND" in
    "")
        if [[ "$LEGACY_UPGRADE_MODE" == "1" ]]; then
            install_or_upgrade 0
        else
            install_or_upgrade 1
        fi
        ;;
    install)
        install_or_upgrade 1
        ;;
    upgrade)
        install_or_upgrade 0
        ;;
    start)
        start_sandbox
        ;;
    restart)
        stop_sandbox
        sleep 1
        start_sandbox
        ;;
    stop)
        stop_sandbox
        echo "claw wallet sandbox stop requested."
        ;;
    is-running)
        if get_running_sandbox_pid >/dev/null; then
            echo "claw wallet sandbox is running."
            exit 0
        fi
        echo "claw wallet sandbox is not running."
        exit 1
        ;;
    uninstall)
        uninstall_skill
        ;;
    serve)
        shift || true
        if [[ ! -x "$BINARY_PATH" ]]; then
            echo "claw wallet sandbox is not installed. Expected binary at: $BINARY_PATH"
            echo "Run: $SCRIPT_DIR/install.sh"
            exit 1
        fi
        if [[ $# -gt 0 ]]; then
            exec "$BINARY_PATH" serve "$@"
        fi
        exec "$BINARY_PATH" serve
        ;;
    *)
        if [[ ! -x "$BINARY_PATH" ]]; then
            echo "claw wallet sandbox is not installed. Expected binary at: $BINARY_PATH"
            echo "Run: $SCRIPT_DIR/install.sh"
            exit 1
        fi
        exec "$BINARY_PATH" "$@"
        ;;
esac
