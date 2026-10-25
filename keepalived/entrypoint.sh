#!/bin/sh
set -eu

: "${VIP_CIDR:?VIP_CIDR manquant}"
: "${VRRP_ROUTER_ID:?VRRP_ROUTER_ID manquant}"
: "${VRRP_AUTH_PASS:?VRRP_AUTH_PASS manquant}"
: "${PRIORITY:?PRIORITY manquant}"
: "${PEER_HOST:?PEER_HOST manquant}"

ROUTER_ID="${ROUTER_ID:-pihole}"
VIP_ADDR="${VIP_CIDR%%/*}"
PREFIX="${VIP_CIDR##*/}"

if [ "${#VRRP_AUTH_PASS}" -gt 8 ]; then
    echo "VRRP_AUTH_PASS fait ${#VRRP_AUTH_PASS} caractères ; keepalived PASS est limité à 8." >&2
    exit 1
fi

ipv4_to_int() {
    # shellcheck disable=SC2086,SC2183
    set -- $(echo "$1" | tr '.' ' ')
    echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
}

same_subnet() {
    a="$(ipv4_to_int "$1")"
    b="$(ipv4_to_int "$2")"
    if [ "$3" -eq 0 ]; then
        return 0
    fi
    mask=$(( 0xFFFFFFFF << (32 - $3) & 0xFFFFFFFF ))
    [ $((a & mask)) -eq $((b & mask)) ]
}

# IP Docker du conteneur sur le sous-réseau de la VIP (pas celle de Traefik).
detect_src() {
    while read -r _ iface _ cidr _; do
        [ "$iface" = "lo" ] && continue
        [ -z "$cidr" ] && continue
        ipaddr="${cidr%/*}"
        case "$ipaddr" in
            *.*.*.*) ;;
            *) continue ;;
        esac
        if same_subnet "$ipaddr" "$VIP_ADDR" "$PREFIX"; then
            printf '%s|%s\n' "$iface" "$ipaddr"
            return 0
        fi
    done <<EOF
$(ip -4 -o addr show)
EOF
    return 1
}

resolve_peer() {
    host="$1"
    case "$host" in
        *.*.*.*)
            echo "$host"
            return 0
            ;;
    esac
    i=0
    while [ "$i" -lt 30 ]; do
        ans="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 { print $1; exit }' || true)"
        if [ -n "$ans" ]; then
            echo "$ans"
            return 0
        fi
        ans="$(dig +short +time=1 +tries=1 A "$host" 2>/dev/null | awk 'NR==1 { print; exit }' || true)"
        case "$ans" in
            *.*.*.*)
                echo "$ans"
                return 0
                ;;
        esac
        i=$((i + 1))
        sleep 1
    done
    return 1
}

detected="$(detect_src)" || {
    echo "Aucune IP locale dans le sous-réseau de la VIP (${VIP_CIDR})." >&2
    ip -4 addr show >&2 || true
    exit 1
}

if [ -z "${INTERFACE:-}" ] || [ "${INTERFACE}" = "auto" ]; then
    INTERFACE="${detected%%|*}"
fi
SRC_IP="${detected##*|}"

PEER_IP="$(resolve_peer "$PEER_HOST")" || {
    echo "Impossible de résoudre PEER_HOST=${PEER_HOST}." >&2
    exit 1
}

export INTERFACE ROUTER_ID SRC_IP PEER_IP

envsubst '${INTERFACE} ${ROUTER_ID} ${VRRP_ROUTER_ID} ${PRIORITY} ${SRC_IP} ${PEER_IP} ${VIP_CIDR} ${VRRP_AUTH_PASS}' \
    < /etc/keepalived/keepalived.conf.tmpl \
    > /etc/keepalived/keepalived.conf

echo "keepalived ${ROUTER_ID} if=${INTERFACE} src=${SRC_IP} peer=${PEER_HOST}/${PEER_IP} vip=${VIP_CIDR} prio=${PRIORITY}"
ip -4 addr show || true

args="--dont-fork --log-console -f /etc/keepalived/keepalived.conf"
if [ "${KEEPALIVED_DEBUG:-0}" = "1" ]; then
    args="--dont-fork --log-console --log-detail -f /etc/keepalived/keepalived.conf"
fi

# shellcheck disable=SC2086
exec keepalived $args
