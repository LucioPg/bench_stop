#!/bin/bash

##############################################################################
# stop_bench.sh - Gracefully stop all Frappe bench processes
#
# This script reads the bench configuration to identify the correct Redis ports
# and gracefully shuts down all associated processes.
##############################################################################

set -e

# Script directory (should be frappe-bench)
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${BENCH_DIR}/config"
SITES_DIR="${BENCH_DIR}/sites"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log function
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Read port from Redis config file
# Usage: get_redis_port <config_file_name>
get_redis_port() {
    local conf_file="${CONFIG_DIR}/$1"
    if [[ -f "$conf_file" ]]; then
        grep -E "^port " "$conf_file" | awk '{print $2}' | tr -d '[:space:]'
    fi
}

# Read port from common_site_config.json
# Usage: get_json_port <key>
get_json_port() {
    local json_file="${SITES_DIR}/common_site_config.json"
    if [[ -f "$json_file" ]]; then
        grep -E "\"$2\":" "$json_file" | sed -E 's/.*:.*:([0-9]+).*/\1/' | tr -d '[:space:]'
    fi
}

# Get PID from pidfile
# Usage: get_pid_from_file <pidfile_path>
get_pid_from_file() {
    local pidfile="$1"
    if [[ -f "$pidfile" ]]; then
        cat "$pidfile" | tr -d '[:space:]'
    fi
}

# Find process PID by port
# Usage: find_pid_by_port <port>
find_pid_by_port() {
    local port="$1"
    # Try using lsof first (more reliable)
    if command -v lsof &> /dev/null; then
        lsof -ti ":$port" 2>/dev/null | head -1
    else
        # Fallback to using ss/netstat
        local pid=$(ss -ltpn 2>/dev/null | grep ":$port " | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -1)
        if [[ -z "$pid" ]] && command -v netstat &> /dev/null; then
            pid=$(netstat -ltpn 2>/dev/null | grep ":$port " | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -1)
        fi
        echo "$pid"
    fi
}

# Find process PID by command pattern
# Usage: find_pid_by_pattern <pattern>
find_pid_by_pattern() {
    local pattern="$1"
    pgrep -f "$pattern" | head -1
}

# Gracefully kill a process
# Usage: graceful_kill <pid> <process_name> <timeout>
graceful_kill() {
    local pid="$1"
    local name="$2"
    local timeout="${3:-10}"

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        log_warn "$name: Process not running (PID: $pid)"
        return 0  # Not an error - process already stopped
    fi

    log_info "$name: Stopping gracefully (PID: $pid)..."

    # Send SIGTERM for graceful shutdown
    kill -TERM "$pid" 2>/dev/null || true

    # Wait for process to terminate
    local count=0
    while kill -0 "$pid" 2>/dev/null && [[ $count -lt $timeout ]]; do
        sleep 1
        ((count++))
        echo -n "."
    done
    echo ""

    # Check if process is still running
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "$name: Still running after ${timeout}s, forcing shutdown..."
        kill -KILL "$pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            log_error "$name: Failed to kill process (PID: $pid)"
            return 1
        else
            log_info "$name: Force killed"
        fi
    else
        log_info "$name: Stopped successfully"
    fi

    return 0
}

# Stop a Redis instance
# Usage: stop_redis <name> <config_file>
stop_redis() {
    local name="$1"
    local conf_file="$2"
    local pid

    # First try to get PID from pidfile
    local pidfile_name="redis_${name}.pid"
    local pidfile_content=$(get_pid_from_file "${CONFIG_DIR}/pids/${pidfile_name}")

    if [[ -n "$pidfile_content" ]] && kill -0 "$pidfile_content" 2>/dev/null; then
        pid="$pidfile_content"
    else
        # Fallback: find by port
        local port=$(get_redis_port "$conf_file")
        if [[ -n "$port" ]]; then
            pid=$(find_pid_by_port "$port")
        fi
    fi

    if [[ -n "$pid" ]]; then
        graceful_kill "$pid" "Redis ($name)" 5
    else
        log_warn "Redis ($name): Not running"
    fi
}

# Stop Frappe processes
# Usage: stop_frappe_process <pattern> <name>
stop_frappe_process() {
    local pattern="$1"
    local name="$2"
    local pid

    pid=$(find_pid_by_pattern "$pattern")

    if [[ -n "$pid" ]]; then
        graceful_kill "$pid" "$name" 10
    else
        log_warn "$name: Not running"
    fi
}

# Stop Node processes
# Usage: stop_node_process <pattern> <name>
stop_node_process() {
    local pattern="$1"
    local name="$2"
    local pid

    pid=$(find_pid_by_pattern "$pattern")

    if [[ -n "$pid" ]]; then
        graceful_kill "$pid" "$name" 5
    else
        log_warn "$name: Not running"
    fi
}

##############################################################################
# Main
##############################################################################

main() {
    log_info "=== Stopping Frappe Bench ==="
    log_info "Bench directory: ${BENCH_DIR}"
    echo ""

    # Check if we're in the right directory (look for Procfile and sites)
    if [[ ! -f "${BENCH_DIR}/Procfile" ]] || [[ ! -d "${CONFIG_DIR}" ]] || [[ ! -d "${BENCH_DIR}/sites" ]]; then
        log_error "This script must be run from the frappe-bench directory"
        exit 1
    fi

    # Stop in reverse order of startup (important for clean shutdown)
    # 1. Stop worker (let it finish current jobs)
    stop_frappe_process "frappe.utils.bench_helper frappe worker" "Bench Worker" || true

    # 2. Stop schedule
    stop_frappe_process "frappe.utils.bench_helper frappe schedule" "Bench Schedule" || true

    # 3. Stop watch processes
    stop_frappe_process "frappe.utils.bench_helper frappe watch" "Bench Watch" || true
    stop_node_process "esbuild --watch" "Esbuild Watch" || true
    stop_node_process "yarn run watch" "Yarn Watch" || true

    # 4. Stop web server
    stop_frappe_process "frappe.utils.bench_helper frappe serve" "Bench Serve" || true

    # 5. Stop Socket.io
    stop_node_process "socketio.js" "Socket.io" || true

    # 6. Stop Redis instances
    stop_redis "cache" "redis_cache.conf" || true
    stop_redis "queue" "redis_queue.conf" || true
    stop_redis "socketio" "redis_socketio.conf" || true

    echo ""
    log_info "=== All bench processes stopped ==="
}

# Run main function
main "$@"
