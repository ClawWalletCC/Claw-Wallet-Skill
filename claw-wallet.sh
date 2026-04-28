#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BinaryPath="$SCRIPT_DIR/clay-sandbox"
LogPath="$SCRIPT_DIR/sandbox.log"
ErrLogPath="$SCRIPT_DIR/sandbox_err.log"
PidPath="$SCRIPT_DIR/sandbox.pid"

get_running_sandbox_pid() {
    if [[ ! -f "$PidPath" ]]; then
        return 1
    fi
    local pid_value
    pid_value="$(head -n 1 "$PidPath" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -z "$pid_value" ]]; then
        return 1
    fi
    if kill -0 "$pid_value" 2>/dev/null; then
        printf '%s\n' "$pid_value"
        return 0
    fi
    rm -f "$PidPath"
    return 1
}

prepare_log_paths() {
    local preferred_log="$LogPath"
    local preferred_err="$ErrLogPath"
    local log_parent
    log_parent="$(dirname "$preferred_log")"
    mkdir -p "$log_parent" 2>/dev/null || true
    rm -f "$preferred_log" "$preferred_err" 2>/dev/null || true
    if : >"$preferred_log" 2>/dev/null && : >"$preferred_err" 2>/dev/null; then
        return 0
    fi

    local fallback_dir="${TMPDIR:-/tmp}/claw-wallet"
    mkdir -p "$fallback_dir"
    LogPath="$fallback_dir/sandbox.log"
    ErrLogPath="$fallback_dir/sandbox_err.log"
    : >"$LogPath"
    : >"$ErrLogPath"
    echo "Warning: could not use $preferred_log; using fallback logs in $fallback_dir"
}

start_sandbox() {
    local running_pid=""
    if running_pid="$(get_running_sandbox_pid)"; then
        echo "claw wallet sandbox is already running."
        echo "PID file: $PidPath"
        echo "Log files: $LogPath , $ErrLogPath"
        return 0
    fi

    prepare_log_paths
    if command -v setsid >/dev/null 2>&1; then
        setsid "$BinaryPath" serve </dev/null >>"$LogPath" 2>>"$ErrLogPath" &
    else
        nohup "$BinaryPath" serve </dev/null >>"$LogPath" 2>>"$ErrLogPath" &
    fi
    local proc_pid=$!
    disown "$proc_pid" 2>/dev/null || true
    echo "$proc_pid" >"$PidPath"
    echo "claw wallet sandbox launched in the background."
    echo "PID file: $PidPath"
    echo "Log files: $LogPath , $ErrLogPath"
    if [[ -f "$SCRIPT_DIR/.env.clay" ]]; then
        echo "API auth: if HTTP returns 401, send header Authorization: Bearer <token> using AGENT_TOKEN or CLAY_AGENT_TOKEN from .env.clay (or agent_token in identity.json). See SKILL.md."
    fi
}

stop_sandbox() {
    local running_pid=""
    if running_pid="$(get_running_sandbox_pid || true)"; then
        if [[ -n "$running_pid" ]]; then
            kill "$running_pid" 2>/dev/null || true
        fi
    fi
    if [[ -x "$BinaryPath" ]]; then
        "$BinaryPath" stop >/dev/null 2>&1 || true
    fi
    rm -f "$PidPath"
    echo "claw wallet sandbox stop requested."
}

if [[ "${1:-}" == "upgrade" ]]; then
    cd "$SCRIPT_DIR"
    if [[ -x "$BinaryPath" ]]; then
        "$BinaryPath" stop 2>/dev/null || true
    fi
    rm -f "$PidPath"
    BaseUrl="${CLAW_WALLET_BASE_URL:-https://www.clawwallet.cc/skills}"
    echo "Upgrading from $BaseUrl/install.sh ..."
    export CLAW_WALLET_SKIP_INIT="1"
    export CLAW_WALLET_INSTALL_DIR="$SCRIPT_DIR"
    install_sh="$(mktemp "${TMPDIR:-/tmp}/claw-wallet-install-XXXXXX.sh")"
    trap 'rm -f "$install_sh"; unset CLAW_WALLET_INSTALL_DIR' EXIT
    curl -fsSL "$BaseUrl/install.sh" -o "$install_sh"
    bash "$install_sh"
    exit $?
fi

if [[ "${1:-}" == "uninstall" ]]; then
    cd "$SCRIPT_DIR"
    if [[ -x "$BinaryPath" ]]; then
        "$BinaryPath" stop 2>/dev/null || true
    fi
    rm -f "$PidPath"
    echo
    echo "=== WARNING: Uninstall claw-wallet skill ==="
    echo "This will DELETE the entire skill directory and all wallet data."
    echo "Files to be removed: .env.clay, identity.json, share3.json, and all others."
    echo "This action is IRREVERSIBLE. Please backup .env.clay, identity.json, share3.json first if needed."
    echo
    read -r -p "Type 'yes' to confirm uninstall: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Uninstall cancelled."
        exit 0
    fi
    echo "Removing $SCRIPT_DIR ..."
    parent_dir="$(dirname "$SCRIPT_DIR")"
    cd "$parent_dir"
    rm -rf "$SCRIPT_DIR"
    echo "claw-wallet skill has been uninstalled."
    exit 0
fi

if [[ ! -x "$BinaryPath" ]]; then
    echo "claw wallet sandbox is not installed. Expected binary at: $BinaryPath"
    echo "Run: $SCRIPT_DIR/install.sh"
    exit 1
fi

if [[ "${1:-}" == "" || "${1:-}" == "start" ]]; then
    start_sandbox
    exit 0
fi

if [[ "${1:-}" == "restart" ]]; then
    stop_sandbox
    sleep 1
    start_sandbox
    exit 0
fi

if [[ "${1:-}" == "stop" ]]; then
    stop_sandbox
    exit 0
fi

if [[ "${1:-}" == "is-running" ]]; then
    if get_running_sandbox_pid >/dev/null; then
        echo "claw wallet sandbox is running."
        exit 0
    fi
    echo "claw wallet sandbox is not running."
    exit 1
fi

if [[ "${1:-}" == "serve" ]]; then
    cd "$SCRIPT_DIR"
    shift || true
    if [[ $# -gt 0 ]]; then
        exec "$BinaryPath" "$@"
    fi
    exec "$BinaryPath" serve
fi

cd "$SCRIPT_DIR"
exec "$BinaryPath" "$@"
