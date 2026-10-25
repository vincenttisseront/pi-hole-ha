#!/usr/bin/env bash
# Vérifie la bascule DNS via dnsdist sur 127.0.0.1 (sans macvlan / VIP).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="$ROOT/.env.lab"
LAB_COMPOSE="$(mktemp)"
export ENV_FILE

if docker info >/dev/null 2>&1; then
    COMPOSE=(docker compose --project-directory "$ROOT" -f "$LAB_COMPOSE" --env-file "$ENV_FILE")
else
    COMPOSE=(sudo docker compose --project-directory "$ROOT" -f "$LAB_COMPOSE" --env-file "$ENV_FILE")
fi

logs() {
    "${COMPOSE[@]}" ps || true
    "${COMPOSE[@]}" logs --no-color --tail=80 || true
}

cleanup() {
    if [[ -f "${LAB_COMPOSE:-}" ]]; then
        "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
        rm -f "$LAB_COMPOSE"
    fi
    docker network rm pihole-lab >/dev/null 2>&1 || true
    if [[ "${LAB_LEGACY_FW:-0}" == 1 && -n "${LAB_FW_SUB:-}" ]]; then
        sudo iptables-legacy -D FORWARD -s "$LAB_FW_SUB" -j ACCEPT >/dev/null 2>&1 || true
        sudo iptables-legacy -D FORWARD -d "$LAB_FW_SUB" -j ACCEPT >/dev/null 2>&1 || true
    fi
}

on_exit() {
    local code=$?
    if ((code != 0)); then
        echo "---- échec, journaux ----" >&2
        logs >&2 || true
    fi
    if [[ "${LAB_KEEP:-0}" != "1" ]]; then
        cleanup
    fi
    exit "$code"
}
trap on_exit EXIT

cp "$ROOT/docker-compose.yml" "$LAB_COMPOSE"
cp "$ROOT/env.lab.example" "$ENV_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

sudo rm -rf "$ROOT/data"

echo "Préparation réseau lab ${DOCKER_NETWORK}..."
docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 \
    || docker network create "$DOCKER_NETWORK" >/dev/null

if sudo iptables-legacy -S FORWARD 2>/dev/null | head -n 1 | grep -q -- '-P FORWARD DROP'; then
    LAB_LEGACY_FW=1
    SUB="$(docker network inspect "$DOCKER_NETWORK" -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
    if [[ -n "$SUB" ]]; then
        LAB_FW_SUB="$SUB"
        sudo iptables-legacy -C FORWARD -s "$SUB" -j ACCEPT 2>/dev/null \
            || sudo iptables-legacy -I FORWARD 1 -s "$SUB" -j ACCEPT
        sudo iptables-legacy -C FORWARD -d "$SUB" -j ACCEPT 2>/dev/null \
            || sudo iptables-legacy -I FORWARD 1 -d "$SUB" -j ACCEPT
        echo "FORWARD legacy ouvert pour $SUB"
    fi
fi

"$ROOT/scripts/preflight.sh"

echo "Construction et démarrage du cluster de lab..."
"${COMPOSE[@]}" up -d --build --wait --wait-timeout 300

dns_ok() {
    dig +time=2 +tries=1 +short @"${DNS_HOST_IP}" pi.hole A >/dev/null 2>&1
}

echo "IP Docker :"
docker inspect -f "{{.Name}} {{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}}={{\$v.IPAddress}} {{end}}" pihole-1 pihole-2 || true

if ! dns_ok; then
    echo "DNS hôte ${DNS_HOST_IP} ne répond pas." >&2
    dig +time=2 @"${DNS_HOST_IP}" pi.hole A || true
    exit 1
fi
echo "dig @${DNS_HOST_IP} pi.hole OK"

echo "Arrêt de pihole-1 (bascule dnsdist → pihole-2)..."
"${COMPOSE[@]}" stop pihole-1
sleep 6

if ! dns_ok; then
    echo "Après arrêt du primaire, ${DNS_HOST_IP} ne répond plus." >&2
    "${COMPOSE[@]}" exec -T dnsdist dnsdist -e 'showServers()' || true
    exit 1
fi
echo "Bascule OK via pihole-2"

echo "Redémarrage de pihole-1..."
"${COMPOSE[@]}" start pihole-1
sleep 15
if ! dns_ok; then
    echo "DNS cassé après retour du primaire." >&2
    exit 1
fi

echo "Lab OK : DNS = hôte ${DNS_HOST_IP}, bascule dnsdist sans VIP."
