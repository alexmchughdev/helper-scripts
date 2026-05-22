#!/usr/bin/env bash
#
# setupvnc.sh
# Sets up socat TCP forwarders from <LAN-IP>:<port> to running containers, so
# they can be reached from elsewhere on the LAN. Every run creates two forwards:
#   - vnc        qemu container's VNC port            (default 5900 -> 5900)
#   - fileshare  fileshare-external container's port  (80 -> 80)
#
# Flow:
#   1. Auto-detect / prompt for the LAN IP of this host.
#   2. For each forward: find the container via `docker ps`, read its
#      172.x.x.x bridge IP, and launch a backgrounded socat.
#
# Run it from the Ubuntu admin tools container, via the Portainer console.
#
# Usage:
#   ./setupvnc.sh
#   ./setupvnc.sh --lan-ip 192.168.1.50 --lan-port 5900 --container-port 5900
#   ./setupvnc.sh --stop    # stop every socat forwarder started by this script

set -euo pipefail

# -------- defaults --------
LAN_PORT_DEFAULT=5900
CONTAINER_PORT_DEFAULT=5900

# fileshare-external forward — set up automatically alongside the VNC forward.
FILESHARE_FILTER="externa"
FILESHARE_PORT=80

PIDFILE="/tmp/setup-vnc-socat.pid"

LAN_IP=""
LAN_PORT=""
CONTAINER_PORT=""
CONTAINER_FILTER="qemu"
STOP_ONLY=0

# -------- helpers --------
err()  { printf '\033[31m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Required command '$1' is not installed."
        err "Docker does not appear to be installed/available to this user."
        exit 1
    fi
}

# Ensure socat is installed; auto-install via apt-get if missing.
# The admin tools container is Ubuntu, so apt-get is the only supported path.
ensure_socat() {
    if command -v socat >/dev/null 2>&1; then
        return 0
    fi
    info "socat not found — installing via apt-get..."

    if ! command -v apt-get >/dev/null 2>&1; then
        err "apt-get not available — this script expects the Ubuntu admin tools container."
        err "Install socat manually and re-run."
        exit 1
    fi

    # Use sudo only if we're not already root.
    local SUDO=""
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            err "Not running as root and 'sudo' not found. Re-run as root."
            exit 1
        fi
    fi

    DEBIAN_FRONTEND=noninteractive $SUDO apt-get update -y
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y socat

    if ! command -v socat >/dev/null 2>&1; then
        err "Install appeared to succeed but socat is still not on PATH."
        exit 1
    fi
    ok "socat installed."
}

# Detect this host's LAN IP. Try eth0 first — in a host-networked admin
# container, eth0 is the host's LAN interface. Fall back to `ip route get`
# (the src IP used to reach the internet). Reject docker-bridge / link-local.
detect_lan_ip() {
    local ip=""

    if ip -4 -o addr show dev eth0 2>/dev/null | grep -q inet; then
        ip=$(ip -4 -o addr show dev eth0 \
                | awk '{print $4}' | cut -d/ -f1 | head -n1)
    fi

    if [[ -z "$ip" ]]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null \
                | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' \
                | head -n1)
    fi

    case "$ip" in
        172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|127.*) ip="" ;;
    esac

    echo "$ip"
}

# Succeed if the PID file lists at least one still-running process.
pidfile_has_live() {
    [[ -f "$PIDFILE" ]] || return 1
    local p
    while read -r p; do
        [[ -n "$p" ]] || continue
        kill -0 "$p" 2>/dev/null && return 0
    done < "$PIDFILE"
    return 1
}

# start_forward LABEL FILTER CONTAINER_PORT LAN_PORT
# Finds the container matching FILTER, resolves its 172.x.x.x IP, and launches a
# backgrounded socat from LAN_IP:LAN_PORT to <container>:CONTAINER_PORT. The PID
# is appended to PIDFILE. Returns non-zero (without exiting) if the forward
# could not be started, so a failure on one forward doesn't block the others.
start_forward() {
    local label="$1" filter="$2" cport="$3" lport="$4"
    local cid cip logfile pid

    echo
    info "[${label}] Looking for a running container matching '${filter}'..."
    cid=$(docker ps --filter "status=running" --format '{{.ID}} {{.Image}} {{.Names}}' \
            | grep -i "$filter" | awk '{print $1}' | head -n1 || true)
    if [[ -z "$cid" ]]; then
        err "[${label}] No running container matched '${filter}'."
        err "[${label}] Containers currently running:"
        docker ps --format '  {{.ID}}  {{.Image}}  {{.Names}}' >&2 || true
        return 1
    fi
    ok "[${label}] Found container: $cid"

    # Pull the first IPv4 in the 172.x.x.x range from docker inspect.
    cip=$(docker inspect "$cid" \
            | grep -Eo '"IPAddress": "172(\.[0-9]+){3}"' \
            | head -n1 | grep -Eo '172(\.[0-9]+){3}' || true)
    if [[ -z "$cip" ]]; then
        err "[${label}] Could not determine a 172.x.x.x IP for container $cid."
        docker inspect "$cid" | grep -E '"IPAddress"' >&2 || true
        return 1
    fi
    ok "[${label}] Container IP: $cip"

    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${lport}\$"; then
        err "[${label}] Something is already listening on port ${lport} — skipping."
        return 1
    fi

    logfile="/tmp/setup-vnc-socat-${label}.log"
    info "[${label}] Starting socat:  ${LAN_IP}:${lport}  ->  ${cip}:${cport}"

    # nohup + & so it survives this script exiting.
    nohup socat "TCP-LISTEN:${lport},fork,reuseaddr,bind=${LAN_IP}" \
                "TCP:${cip}:${cport}" \
                >"$logfile" 2>&1 &
    pid=$!

    # Give it a moment to either bind or crash.
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        err "[${label}] socat failed to start. Last log lines:"
        tail -n 20 "$logfile" >&2 || true
        return 1
    fi

    echo "$pid" >> "$PIDFILE"
    ok "[${label}] socat running (pid $pid) — reachable at ${LAN_IP}:${lport}"
    info "[${label}] Log: $logfile"
    return 0
}

usage() {
    cat <<EOF
Usage: $0 [options]

Sets up two socat forwarders on every run: the qemu VNC port and the
fileshare-external HTTP port.

Options:
  --lan-ip <ip>           LAN IP of THIS host (the one socat binds to).
                          If omitted, the script will prompt.
  --lan-port <port>       LAN port for the VNC forward (default: ${LAN_PORT_DEFAULT}).
  --container-port <port> VNC port inside the qemu container (default: ${CONTAINER_PORT_DEFAULT}).
  --filter <name>         Substring matched against 'docker ps' to find the
                          qemu container (default: qemu).
  --stop                  Stop every socat forwarder started by this script.
  -h, --help              Show this help.

The fileshare-external forward (container filter '${FILESHARE_FILTER}',
port ${FILESHARE_PORT}) is fixed — edit the defaults at the top of the
script to change it.
EOF
}

# -------- arg parsing --------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lan-ip)          LAN_IP="$2"; shift 2 ;;
        --lan-port)        LAN_PORT="$2"; shift 2 ;;
        --container-port)  CONTAINER_PORT="$2"; shift 2 ;;
        --filter)          CONTAINER_FILTER="$2"; shift 2 ;;
        --stop)            STOP_ONLY=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# -------- stop mode --------
if [[ "$STOP_ONLY" -eq 1 ]]; then
    if [[ -f "$PIDFILE" ]]; then
        stopped=0
        while read -r pid; do
            [[ -n "$pid" ]] || continue
            if kill -0 "$pid" 2>/dev/null; then
                if kill "$pid" 2>/dev/null; then
                    ok "Stopped socat (pid $pid)."
                    stopped=$((stopped + 1))
                else
                    info "Could not kill pid $pid."
                fi
            else
                info "PID $pid is not running."
            fi
        done < "$PIDFILE"
        rm -f "$PIDFILE"
        [[ "$stopped" -gt 0 ]] || info "Nothing was running."
    else
        info "No PID file at $PIDFILE — nothing to stop."
    fi
    exit 0
fi

# -------- preflight --------
require_cmd docker
ensure_socat

if pidfile_has_live; then
    err "Forwarders from a previous run are still active."
    err "Stop them first with:  $0 --stop"
    exit 1
fi

# -------- defaults for ports --------
LAN_PORT="${LAN_PORT:-$LAN_PORT_DEFAULT}"
CONTAINER_PORT="${CONTAINER_PORT:-$CONTAINER_PORT_DEFAULT}"

# -------- detect LAN IP --------
if [[ -z "$LAN_IP" ]]; then
    DETECTED=$(detect_lan_ip)
    if [[ -n "$DETECTED" ]]; then
        echo
        info "Detected LAN IP: ${DETECTED}"
        read -rp "Use this IP? [Y/n] (or enter a different IP): " ans
        case "$ans" in
            ""|y|Y|yes|YES) LAN_IP="$DETECTED" ;;
            n|N|no|NO)      read -rp "LAN IP: " LAN_IP ;;
            *)              LAN_IP="$ans" ;;   # user typed an IP directly
        esac
    else
        echo
        info "Could not auto-detect a LAN IP."
        info "Enter the LAN IP of THIS host (the box Portainer/Docker runs on)."
        read -rp "LAN IP: " LAN_IP
    fi

    if [[ -z "$LAN_IP" ]]; then
        err "LAN IP is required."
        exit 1
    fi
fi

# -------- set up forwards --------
: > "$PIDFILE"      # start a fresh PID list for this run
FAILED=0

# VNC forward to the qemu container.
start_forward "vnc"       "$CONTAINER_FILTER" "$CONTAINER_PORT" "$LAN_PORT"       || FAILED=1

# fileshare-external HTTP forward, set up alongside the VNC forward.
start_forward "fileshare" "$FILESHARE_FILTER" "$FILESHARE_PORT" "$FILESHARE_PORT" || FAILED=1

echo
if [[ "$FAILED" -ne 0 ]]; then
    err "One or more forwards failed to start (see messages above)."
    info "Stop whatever did start with:  $0 --stop"
    exit 1
fi

ok "All forwards running."
info "Stop them later with:  $0 --stop"
