#!/usr/bin/env bash
# aws-wrapper.sh — one command to manage a personal OpenVPN server on EC2.
#
#   aws-wrapper.sh            status, start if stopped, open the VPN client
#   aws-wrapper.sh status     show instance state, IP and website health
#   aws-wrapper.sh start      start the instance (retries on capacity errors)
#   aws-wrapper.sh stop       stop the instance (asks first)
#   aws-wrapper.sh ssh        log in via EC2 Instance Connect (no stored key)
#
# Settings come from ~/.config/aws-wrapper.conf (or the environment):
#   INSTANCE_ID=i-0123456789abcdef0   required
#   OS_USER=ubuntu                    login user for `ssh`
#   OVPN_PROFILE=/path/to/profile.ovpn
#   OVPN_APP=/path/to/OpenVPNConnect.exe
#   HEALTH_URL=http://example.com/    optional website check
set -euo pipefail

CONF=${AWS_WRAPPER_CONF:-$HOME/.config/aws-wrapper.conf}
# shellcheck source=/dev/null
[[ -f $CONF ]] && source "$CONF"
: "${INSTANCE_ID:?set INSTANCE_ID in $CONF}"
OS_USER=${OS_USER:-ubuntu}
OVPN_PROFILE=${OVPN_PROFILE:-}
OVPN_APP=${OVPN_APP:-}
HEALTH_URL=${HEALTH_URL:-}

banner() {
    local line
    while IFS= read -r line; do echo "$line"; sleep .05; done <<'ART'
   _____  __      __  _________          __      ____________    _____ _________________________________________
  /  _  \/  \    /  \/   _____/         /  \    /  \______   \  /  _  \\______   \______   \_   _____/\______   \
 /  /_\  \   \/\/   /\_____  \   ______ \   \/\/   /|       _/ /  /_\  \|     ___/|     ___/|    __)_  |       _/
/    |    \        / /        \ /_____/  \        / |    |   \/    |    \    |    |    |    |        \ |    |   \
\____|__  /\__/\  / /_______  /           \__/\  /  |____|_  /\____|__  /____|    |____|   /_______  / |____|_  /
        \/      \/          \/                 \/          \/         \/                           \/         \/
ART
}

confirm() { local yn; read -rp "$1 (y/N): " yn; [[ $yn =~ ^[yY]([eE][sS])?$ ]]; }

describe() {
    aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].$1" --output text
}
state()     { describe State.Name; }
public_ip() { describe PublicIpAddress; }

wait_for() {
    local want=$1 spin='-\|/' i=0
    echo -n "Waiting for '$want'...  "
    while [[ $(state) != "$want" ]]; do
        printf '\b%s' "${spin:i++%4:1}"
        ((i < 240)) || { echo; echo "Gave up after ~4 min." >&2; return 1; }
        sleep 1
    done
    printf '\bdone\n'
}

cmd_status() {
    local s ip
    s=$(state); ip=$(public_ip)
    echo "Instance $INSTANCE_ID: $s${ip:+ at $ip}"
    if [[ $s == running && -n $HEALTH_URL ]]; then
        echo "Website $HEALTH_URL -> HTTP $(curl -s -o /dev/null -m 5 -w '%{http_code}' "$HEALTH_URL")"
    fi
}

cmd_start() {
    [[ $(state) == running ]] && { echo "Already running."; return; }
    echo "Starting $INSTANCE_ID..."
    # InsufficientInstanceCapacity is common for small types; keep trying
    until aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1; do
        echo "  No capacity right now, retrying in 30s..."
        sleep 30
    done
    wait_for running
}

cmd_stop() {
    confirm "Stop $INSTANCE_ID? Everything it serves goes down" || return 1
    aws ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null
    wait_for stopped
}

# Point the local OpenVPN profile at the current IP (no-op with an Elastic IP)
sync_profile() {
    local ip
    [[ -n $OVPN_PROFILE && -f $OVPN_PROFILE ]] || return 0
    ip=$(public_ip)
    if ! grep -q "^remote $ip 1194$" "$OVPN_PROFILE"; then
        sed -i "s/^remote .* 1194$/remote $ip 1194/" "$OVPN_PROFILE"
        echo "VPN profile now points at $ip"
    fi
}

cmd_ssh() {
    local key=$HOME/.ssh/aws-wrapper-eic
    [[ -f $key ]] || ssh-keygen -q -t ed25519 -N '' -f "$key" -C aws-wrapper-eic
    # The pushed key is valid for 60 seconds; it can take a moment to apply
    local rc
    for _ in 1 2 3; do
        aws ec2-instance-connect send-ssh-public-key --instance-id "$INSTANCE_ID" \
            --instance-os-user "$OS_USER" --ssh-public-key "file://$key.pub" >/dev/null
        sleep 2
        rc=0; ssh -i "$key" -o IdentitiesOnly=yes "$OS_USER@$(public_ip)" "$@" || rc=$?
        # 255 = ssh itself failed (e.g. key not applied yet); anything else is the session's own exit
        ((rc == 255)) || return "$rc"
        echo "Login refused, pushing the key again..." >&2
    done
    return 255
}

cmd_default() {
    clear; banner
    case $(state) in
        running) ;;
        stopped) echo "Instance is stopped."; confirm "Start it?" || exit 1; cmd_start ;;
        *)       echo "Instance is '$(state)', try again in a minute."; exit 1 ;;
    esac
    sync_profile
    cmd_status
    if [[ -n $OVPN_APP ]]; then "$OVPN_APP"; fi
}

case ${1:-} in
    "")     cmd_default ;;
    status) cmd_status ;;
    start)  cmd_start; sync_profile ;;
    stop)   cmd_stop ;;
    ssh)    shift; cmd_ssh "$@" ;;
    *)      sed -n '2,16p' "$0"; exit 1 ;;
esac
