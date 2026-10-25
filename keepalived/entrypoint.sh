#!/bin/sh
set -eu

: "${SRC_IP:?SRC_IP manquant}"
: "${PEER_IP:?PEER_IP manquant}"
: "${VIP_CIDR:?VIP_CIDR manquant}"
: "${VRRP_ROUTER_ID:?VRRP_ROUTER_ID manquant}"
: "${VRRP_AUTH_PASS:?VRRP_AUTH_PASS manquant}"
: "${PRIORITY:?PRIORITY manquant}"

ROUTER_ID="${ROUTER_ID:-pihole}"

if [ "${#VRRP_AUTH_PASS}" -gt 8 ]; then
    echo "VRRP_AUTH_PASS fait ${#VRRP_AUTH_PASS} caractères ; keepalived PASS est limité à 8." >&2
    exit 1
fi

if [ -z "${INTERFACE:-}" ] || [ "${INTERFACE}" = "auto" ]; then
    INTERFACE="$(ip -4 -o addr show | awk -v ip="${SRC_IP}" '$4 ~ "^" ip "/" { print $2; exit }')"
fi

if [ -z "${INTERFACE:-}" ]; then
    echo "Interface introuvable pour ${SRC_IP}. Définis CLUSTER_INTERFACE dans .env." >&2
    ip -4 addr show >&2 || true
    exit 1
fi

export INTERFACE ROUTER_ID

envsubst '${INTERFACE} ${ROUTER_ID} ${VRRP_ROUTER_ID} ${PRIORITY} ${SRC_IP} ${PEER_IP} ${VIP_CIDR} ${VRRP_AUTH_PASS}' \
    < /etc/keepalived/keepalived.conf.tmpl \
    > /etc/keepalived/keepalived.conf

echo "keepalived ${ROUTER_ID} if=${INTERFACE} src=${SRC_IP} peer=${PEER_IP} vip=${VIP_CIDR} prio=${PRIORITY}"
ip -4 addr show || true

args="--dont-fork --log-console -f /etc/keepalived/keepalived.conf"
if [ "${KEEPALIVED_DEBUG:-0}" = "1" ]; then
    args="--dont-fork --log-console --log-detail -f /etc/keepalived/keepalived.conf"
fi

# shellcheck disable=SC2086
exec keepalived $args
