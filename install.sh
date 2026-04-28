#!/bin/bash
# claw wallet minimal installer for Linux/macOS
# Served at: https://www.clawwallet.cc/skills/install.sh  (curl -fsSL ... | bash)
# Usage: first-time install (wallet init) | upgrade (CLAW_WALLET_SKIP_INIT=1, no wallet init)
set -euo pipefail

# Piped from curl: BASH_SOURCE is "-"; use cwd (user should: mkdir -p skills/claw-wallet && cd skills/claw-wallet)
if [[ "${BASH_SOURCE[0]:-}" == "-" ]]; then
    SCRIPT_DIR="$(pwd -P)"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
cd "$SCRIPT_DIR"

CLAW_WALLET_BASE_URL="${CLAW_WALLET_BASE_URL:-https://www.clawwallet.cc}"

download_skill_bundle() {
    echo "Downloading SKILL.md and wrapper scripts from ${CLAW_WALLET_BASE_URL} ..."
    curl -fsSL "${CLAW_WALLET_BASE_URL}/skills/SKILL.md" -o SKILL.md
    curl -fsSL "${CLAW_WALLET_BASE_URL}/skills/claw-wallet.sh" -o claw-wallet.sh
    curl -fsSL "${CLAW_WALLET_BASE_URL}/skills/claw-wallet" -o claw-wallet
    chmod +x claw-wallet.sh claw-wallet
}

if [[ "${CLAW_WALLET_SKIP_SKILL_DOWNLOAD:-0}" != "1" ]]; then
    download_skill_bundle
fi

OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_TYPE="$(uname -m)"

BINARY_NAME="clay-sandbox-linux-amd64"
if [ "$OS_TYPE" = "darwin" ]; then
    if [ "$ARCH_TYPE" = "arm64" ]; then
        BINARY_NAME="clay-sandbox-darwin-arm64"
    else
        BINARY_NAME="clay-sandbox-darwin-amd64"
    fi
fi

BINARY_URL="${CLAW_WALLET_BASE_URL}/bin/${BINARY_NAME}"
BINARY_TARGET="./clay-sandbox"
PID_PATH="$SCRIPT_DIR/sandbox.pid"
LOG_PATH="$SCRIPT_DIR/sandbox.log"
ERR_LOG_PATH="$SCRIPT_DIR/sandbox_err.log"

get_running_sandbox_pid() {
    if [ ! -f "$PID_PATH" ]; then
        return 1
    fi
    local pid_value
    pid_value="$(head -n 1 "$PID_PATH" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -z "$pid_value" ]; then
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

    prepare_log_paths
    nohup "$BINARY_TARGET" serve </dev/null >>"$LOG_PATH" 2>>"$ERR_LOG_PATH" &
    
    local proc_pid=$!
    disown "$proc_pid" 2>/dev/null || true
    echo "$proc_pid" >"$PID_PATH"
    echo "claw wallet sandbox launched in the background."
    echo "PID file: $PID_PATH"
    echo "Log files: $LOG_PATH , $ERR_LOG_PATH"
    if [ -f "$SCRIPT_DIR/.env.clay" ]; then
        echo "API auth: if HTTP returns 401, send header Authorization: Bearer <token> using AGENT_TOKEN from .env.clay. See SKILL.md."
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
    if [ -x "$BINARY_TARGET" ]; then
        "$BINARY_TARGET" stop >/dev/null 2>&1 || true
    fi
    rm -f "$PID_PATH"
}

# --- Common: stop, download, start ---
if [ "${CLAW_WALLET_SKIP_STOP:-0}" != "1" ]; then
    stop_sandbox
fi

echo "Downloading sandbox binary from $BINARY_URL ..."
TMP_TARGET="${BINARY_TARGET}.download"
curl -L -o "$TMP_TARGET" "$BINARY_URL"
mv -f "$TMP_TARGET" "$BINARY_TARGET"

chmod +x "$BINARY_TARGET"

start_sandbox

# --- First-time only: wallet init (skipped when upgrade passes CLAW_WALLET_SKIP_INIT=1) ---
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

if [ "${CLAW_WALLET_SKIP_INIT:-0}" != "1" ]; then
    do_wallet_init
fi

# --- Common: final messages ---
echo "Check .env.clay for CLAY_SANDBOX_URL"
echo "If you have set an AGENT_TOKEN, then HTTP clients (curl, agents) must call protected APIs with: Authorization: Bearer <same token>."
echo "Sandbox start success. at: $BINARY_TARGET"
