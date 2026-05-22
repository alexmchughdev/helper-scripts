#!/usr/bin/env bash
#
# setup-vnc.sh
# Automatically sets up a socat TCP forwarder from <LAN-IP>:<LAN-PORT>
# to a qemu container's internal VNC port (default 5900).
#
# Flow:
#   1. Find the qemu container via `docker ps`
#   2. Inspect it to discover its 172.x.x.x bridge IP
#   3. Ask the user for the LAN IP of this host (not reliably auto-detectable
#      from inside Portainer / a containerized shell)
#   4. Launch socat in the background, bound to that LAN IP, listening on
#      the LAN port the user picks (default 5900), forwarding to the
#      container's VNC port (default 5900).
#
# Usage:
#   sudo ./setup-vnc.sh
#   sudo ./setup-vnc.sh --lan-ip 192.168.1.50 --lan-port 5900 --container-port 5900
#   sudo ./setup-vnc.sh --stop    # kill any running socat forwarder started by this script

set -euo pipefail

# -------- defaults --------
LAN_PORT_DEFAULT=5900
CONTAINER_PORT_DEFAULT=5900
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

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --lan-ip <ip>           LAN IP of THIS host (the one socat will bind to).
                          If omitted, the script will prompt.
  --lan-port <port>       Port to expose on the LAN (default: ${LAN_PORT_DEFAULT}).
  --container-port <port> VNC port inside the container (default: ${CONTAINER_PORT_DEFAULT}).
  --filter <name>         Substring to grep for in 'docker ps' (default: qemu).
  --stop                  Stop the socat forwarder previously started by this script.
  -h, --help              Show this help.
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
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" && ok "Stopped socat (pid $pid)."
        else
            info "PID $pid in $PIDFILE is not running."
        fi
        rm -f "$PIDFILE"
    else
        info "No PID file at $PIDFILE — nothing to stop."
    fi
    exit 0
fi

# -------- preflight --------
require_cmd docker
ensure_socat

# -------- find container --------
info "Looking for a running container matching '${CONTAINER_FILTER}'..."
CID=$(docker ps --filter "status=running" --format '{{.ID}} {{.Image}} {{.Names}}' \
        | grep -i "$CONTAINER_FILTER" | awk '{print $1}' | head -n1 || true)

if [[ -z "$CID" ]]; then
    err "No running container matched '${CONTAINER_FILTER}'."
    err "Containers currently running:"
    docker ps --format '  {{.ID}}  {{.Image}}  {{.Names}}' >&2 || true
    exit 1
fi
ok "Found container: $CID"

# -------- get container IP --------
# Pull the first IPv4 in the 172.x.x.x range from docker inspect.
CIP=$(docker inspect "$CID" \
        | grep -Eo '"IPAddress": "172(\.[0-9]+){3}"' \
        | head -n1 | grep -Eo '172(\.[0-9]+){3}' || true)

if [[ -z "$CIP" ]]; then
    err "Could not determine 172.x.x.x IP for container $CID."
    err "Falling back to full inspect dump — please pick the right IP manually:"
    docker inspect "$CID" | grep -E '"IPAddress"' >&2 || true
    exit 1
fi
ok "Container IP: $CIP"

# -------- detect LAN IP --------
# Try eth0 first — in a host-networked admin container, eth0 is the host's
# LAN interface. Fall back to `ip route get` (the src IP used to reach the
# internet). Skip docker bridges (172.16/12) and link-local.
detect_lan_ip() {
    local ip=""

    # 1. eth0, if it exists and has a non-docker IPv4
    if ip -4 -o addr show dev eth0 2>/dev/null | grep -q inet; then
        ip=$(ip -4 -o addr show dev eth0 \
                | awk '{print $4}' | cut -d/ -f1 | head -n1)
    fi

    # 2. Fallback: route to a public IP, take the src
    if [[ -z "$ip" ]]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null \
                | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' \
                | head -n1)
    fi

    # Reject obvious docker-bridge / link-local addresses
    case "$ip" in
        172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|127.*) ip="" ;;
    esac

    echo "$ip"
}

if [[ -z "$LAN_IP" ]]; then
    DETECTED=$(detect_lan_ip)
    if [[ -n "$DETECTED" ]]; then
        echo
        info "Detected LAN IP: ${DETECTED}"
        read -rp "Use this IP? [Y/n] (or enter a different IP): " ans
        case "$ans" in
            ""|y|Y|yes|YES) LAN_IP="$DETECTED" ;;
            n|N|no|NO)
                read -rp "LAN IP: " LAN_IP
                ;;
            *) LAN_IP="$ans" ;;   # user typed an IP directly
        esac
    else
        echo
        info "Could not auto-detect a LAN IP."
        info "Enter the LAN IP of THIS host (the box Portainer/Docker is running on)."
        read -rp "LAN IP: " LAN_IP
    fi

    if [[ -z "$LAN_IP" ]]; then
        err "LAN IP is required."
        exit 1
    fi
fi

# -------- defaults for ports --------
LAN_PORT="${LAN_PORT:-$LAN_PORT_DEFAULT}"
CONTAINER_PORT="${CONTAINER_PORT:-$CONTAINER_PORT_DEFAULT}"

# -------- sanity: is something already on that port? --------
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${LAN_PORT}\$"; then
    err "Something is already listening on port ${LAN_PORT}."
    err "Stop it first, or pick another port with --lan-port."
    exit 1
fi

# -------- launch socat --------
echo
info "Starting socat:"
info "  ${LAN_IP}:${LAN_PORT}  ->  ${CIP}:${CONTAINER_PORT}"

# nohup + & so it survives this script exiting.
nohup socat "TCP-LISTEN:${LAN_PORT},fork,bind=${LAN_IP}" \
            "TCP:${CIP}:${CONTAINER_PORT}" \
            >/tmp/setup-vnc-socat.log 2>&1 &

SOCAT_PID=$!
echo "$SOCAT_PID" > "$PIDFILE"

# Give it a moment to either bind or crash.
sleep 1
if ! kill -0 "$SOCAT_PID" 2>/dev/null; then
    err "socat failed to start. Last log lines:"
    tail -n 20 /tmp/setup-vnc-socat.log >&2 || true
    rm -f "$PIDFILE"
    exit 1
fi

ok "socat is running (pid $SOCAT_PID)."
ok "Connect your VNC client to: ${LAN_IP}:${LAN_PORT}"
info "Log: /tmp/setup-vnc-socat.log"
info "Stop it later with: $0 --stop"