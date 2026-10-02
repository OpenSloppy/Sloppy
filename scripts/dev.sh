#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${SLOPPY_BIN_DIR:-$HOME/.local/bin}"
DASHBOARD_DIR="${SLOPPY_DASHBOARD_DIR:-$HOME/.local/share/sloppy/dashboard}"
PID_FILE="/tmp/sloppy-server.pid"
LOG_FILE="/tmp/sloppy-server.log"
AUTOSTART_MARKER="# sloppy-autostart"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  setup          Build sloppy + Dashboard (debug) and create PATH symlinks.
  start          Start the sloppy server in the background.
  stop           Stop the background sloppy server.
  restart        Restart the sloppy server.
  status         Show whether the sloppy server is running.
  autostart      Install shell hook to auto-start sloppy server on new terminals.
  autostart-off  Remove the auto-start hook.
  logs           Tail the server log.

Options:
  --bin-dir <path>  Override symlink directory (default: $BIN_DIR).
  --dashboard-dir <path>  Override installed Dashboard bundle directory (default: $DASHBOARD_DIR).
  --help, -h        Show this help.
EOF
}

require_command() {
    local command_name="$1"
    local hint="$2"
    command -v "$command_name" >/dev/null 2>&1 || die "$hint"
}

build_dashboard_bundle() {
    local dashboard_source="$REPO_ROOT/Dashboard"
    local dashboard_entry="$dashboard_source/node_modules/vite/bin/vite.js"

    require_command node "'node' not found in PATH. Install Node.js before running setup."
    require_command npm "'npm' not found in PATH. Install npm before running setup."

    log "Installing Dashboard dependencies..."
    npm install --prefix "$dashboard_source"

    [[ -f "$dashboard_entry" ]] || die "Dashboard build tool is missing at $dashboard_entry after npm install."

    log "Building Dashboard bundle..."
    npm --prefix "$dashboard_source" run build:dev

    log "Installing Dashboard bundle in $DASHBOARD_DIR..."
    mkdir -p "$DASHBOARD_DIR"
    rm -rf "$DASHBOARD_DIR/dist"
    cp -R "$dashboard_source/dist" "$DASHBOARD_DIR/dist"
    cp "$dashboard_source/config.json" "$DASHBOARD_DIR/config.json"
}

server_is_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

cmd_setup() {
    log "Resolving Swift packages..."
    swift package resolve --package-path "$REPO_ROOT"

    log "Building sloppy (debug)..."
    swift build -c debug --package-path "$REPO_ROOT" --product sloppy

    build_dashboard_bundle

    local bin_path
    bin_path="$(swift build --show-bin-path -c debug --package-path "$REPO_ROOT")"

    log "Creating symlinks in $BIN_DIR..."
    mkdir -p "$BIN_DIR"
    ln -sf "$bin_path/sloppy" "$BIN_DIR/sloppy"
    rm -f "$BIN_DIR/SloppyNode"

    ok "Setup complete."
    ok "  sloppy    -> $BIN_DIR/sloppy"
    ok "  Dashboard -> $DASHBOARD_DIR"

    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        warn "$BIN_DIR is not in PATH. Add to your shell profile:"
        warn "  export PATH=\"$BIN_DIR:\$PATH\""
    fi
}

cmd_start() {
    if server_is_running; then
        ok "Sloppy server already running (PID $(cat "$PID_FILE"))."
        return 0
    fi

    command -v sloppy >/dev/null 2>&1 || die "'sloppy' not found in PATH. Run '$(basename "$0") setup' first."

    log "Starting sloppy server..."
    nohup sloppy run >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        ok "Sloppy server started (PID $pid). Logs: $LOG_FILE"
    else
        die "Server exited immediately. Check $LOG_FILE for details."
    fi
}

cmd_stop() {
    if ! server_is_running; then
        warn "Sloppy server is not running."
        return 0
    fi

    local pid
    pid="$(cat "$PID_FILE")"
    log "Stopping sloppy server (PID $pid)..."
    kill "$pid" 2>/dev/null || true

    local waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < 10 )); do
        sleep 1
        (( waited++ ))
    done

    if kill -0 "$pid" 2>/dev/null; then
        warn "Graceful shutdown timed out, sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    ok "Sloppy server stopped."
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_status() {
    if server_is_running; then
        ok "Sloppy server is running (PID $(cat "$PID_FILE"))."
    else
        warn "Sloppy server is not running."
        rm -f "$PID_FILE" 2>/dev/null || true
    fi
}

cmd_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        die "No log file found at $LOG_FILE."
    fi
    tail -f "$LOG_FILE"
}

autostart_snippet() {
    cat <<'SNIPPET'
# sloppy-autostart
if command -v sloppy >/dev/null 2>&1; then
    _sloppy_pid_file="/tmp/sloppy-server.pid"
    if ! { [ -f "$_sloppy_pid_file" ] && kill -0 "$(cat "$_sloppy_pid_file")" 2>/dev/null; }; then
        nohup sloppy run >> /tmp/sloppy-server.log 2>&1 &
        echo $! > "$_sloppy_pid_file"
    fi
    unset _sloppy_pid_file
fi
# sloppy-autostart-end
SNIPPET
}

cmd_autostart() {
    local rc_file="$HOME/.bashrc"
    [[ -n "${ZSH_VERSION:-}" ]] && rc_file="$HOME/.zshrc"

    if grep -qF "$AUTOSTART_MARKER" "$rc_file" 2>/dev/null; then
        ok "Auto-start hook already installed in $rc_file."
        return 0
    fi

    log "Installing auto-start hook in $rc_file..."
    printf '\n' >> "$rc_file"
    autostart_snippet >> "$rc_file"

    ok "Auto-start installed. Sloppy server will launch in new terminals."
    ok "Remove with: $(basename "$0") autostart-off"
}

cmd_autostart_off() {
    local rc_file="$HOME/.bashrc"
    [[ -n "${ZSH_VERSION:-}" ]] && rc_file="$HOME/.zshrc"

    if ! grep -qF "$AUTOSTART_MARKER" "$rc_file" 2>/dev/null; then
        warn "No auto-start hook found in $rc_file."
        return 0
    fi

    log "Removing auto-start hook from $rc_file..."
    local tmp
    tmp="$(mktemp)"
    sed "/$AUTOSTART_MARKER/,/# sloppy-autostart-end/d" "$rc_file" > "$tmp"
    mv "$tmp" "$rc_file"

    ok "Auto-start removed from $rc_file."
}

COMMAND=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        setup|start|stop|restart|status|logs|autostart|autostart-off)
            COMMAND="$1"; shift ;;
        --bin-dir)
            [[ $# -ge 2 ]] || die "--bin-dir requires a value"
            BIN_DIR="$2"; shift 2 ;;
        --dashboard-dir)
            [[ $# -ge 2 ]] || die "--dashboard-dir requires a value"
            DASHBOARD_DIR="$2"; shift 2 ;;
        --help|-h)
            usage; exit 0 ;;
        *)
            die "Unknown argument: $1. Use --help for usage." ;;
    esac
done

if [[ -z "$COMMAND" ]]; then
    usage
    exit 1
fi

case "$COMMAND" in
    setup)         cmd_setup ;;
    start)         cmd_start ;;
    stop)          cmd_stop ;;
    restart)       cmd_restart ;;
    status)        cmd_status ;;
    logs)          cmd_logs ;;
    autostart)     cmd_autostart ;;
    autostart-off) cmd_autostart_off ;;
esac
