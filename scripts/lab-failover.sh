#!/usr/bin/env bash
# Fait tourner le cluster sur une interface dummy et vérifie la bascule de VIP.
# N'utilise pas le LAN réel. Nettoie les conteneurs et les interfaces en sortant.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PARENT="${LAB_PARENT:-pihole-dummy}"
SHIM="${LAB_SHIM:-pihole-shim}"
SHIM_ADDR="${LAB_SHIM_ADDR:-192.168.199.1/24}"
ENV_FILE="$ROOT/.env.lab"
export ENV_FILE

if docker info >/dev/null 2>&1; then
    COMPOSE=(docker compose --env-file "$ENV_FILE")
else
    COMPOSE=(sudo docker compose --env-file "$ENV_FILE")
fi

logs() {
    "${COMPOSE[@]}" ps || true
    "${COMPOSE[@]}" logs --no-color --tail=80 || true
}

cleanup() {
    "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
    sudo ip link del "$SHIM" >/dev/null 2>&1 || true
    sudo ip link del "$PARENT" >/dev/null 2>&1 || true
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

sudo modprobe dummy 2>/dev/null || true
sudo ip link del "$SHIM" >/dev/null 2>&1 || true
sudo ip link del "$PARENT" >/dev/null 2>&1 || true
sudo ip link add "$PARENT" type dummy
sudo ip link set "$PARENT" up
sudo ip link set "$PARENT" promisc on
sudo ip link add "$SHIM" link "$PARENT" type macvlan mode bridge
sudo ip addr add "$SHIM_ADDR" dev "$SHIM"
sudo ip link set "$SHIM" up

cp "$ROOT/env.lab.example" "$ENV_FILE"
"$ROOT/scripts/preflight.sh"

echo "Construction et démarrage du cluster de lab..."
"${COMPOSE[@]}" up -d --build --wait --wait-timeout 300

# shellcheck disable=SC1090
source "$ENV_FILE"

holder_of() {
    local container="$1"
    local addr
    addr="$("${COMPOSE[@]}" exec -T "$container" ip -4 addr show 2>/dev/null || true)"
    [[ "$addr" == *" ${VIP}/"* ]]
}

wait_holder() {
    local container="$1"
    local i
    for i in $(seq 1 25); do
        if holder_of "$container"; then
            return 0
        fi
        sleep 1
    done
    echo "Délai dépassé : $container n'a pas ${VIP}" >&2
    "${COMPOSE[@]}" exec -T keepalived-1 ip -4 addr || true
    "${COMPOSE[@]}" exec -T keepalived-2 ip -4 addr || true
    return 1
}

dns_node() {
    local name="$1" expected="$2"
    local answer
    answer="$(dig +time=2 +tries=1 +short "@${VIP}" "$name" A || true)"
    [[ "$answer" == "$expected" ]]
}

echo "Attente de la VIP..."
initial=""
for _ in $(seq 1 30); do
    if holder_of keepalived-1; then
        initial=1
        break
    fi
    if holder_of keepalived-2; then
        initial=2
        break
    fi
    sleep 1
done
echo "Adresses après élection"
"${COMPOSE[@]}" exec -T keepalived-1 ip -4 addr show || true
"${COMPOSE[@]}" exec -T keepalived-2 ip -4 addr show || true
if [[ -z "$initial" ]]; then
    echo "Aucune VIP au démarrage" >&2
    exit 1
fi
echo "Le nœud ${initial} porte la VIP."

if ! dns_node "pihole-${initial}.cluster" "$([[ "$initial" == 1 ]] && echo "$NODE1_IP" || echo "$NODE2_IP")"; then
    echo "Le DNS de la VIP ne répond pas avec l'enregistrement du nœud ${initial}." >&2
    dig +time=2 "@${VIP}" "pihole-${initial}.cluster" A || true
    exit 1
fi
echo "dig @${VIP} pihole-${initial}.cluster OK"

if [[ "$initial" == 1 ]]; then
    victim_pihole=pihole-1
    survivor_keep=keepalived-2
    survivor_name=pihole-2.cluster
    survivor_ip="$NODE2_IP"
else
    victim_pihole=pihole-2
    survivor_keep=keepalived-1
    survivor_name=pihole-1.cluster
    survivor_ip="$NODE1_IP"
fi

echo "Arrêt de ${victim_pihole} pour forcer la bascule..."
"${COMPOSE[@]}" stop "$victim_pihole"

if ! wait_holder "$survivor_keep"; then
    exit 1
fi

if ! dns_node "$survivor_name" "$survivor_ip"; then
    echo "Après bascule, ${VIP} ne sert pas ${survivor_name}." >&2
    dig +time=2 "@${VIP}" "$survivor_name" A || true
    exit 1
fi
echo "Bascule OK : ${VIP} répond via ${survivor_name} -> ${survivor_ip}"

echo "Redémarrage de ${victim_pihole} (nopreempt : la VIP doit rester sur le survivant)..."
"${COMPOSE[@]}" start "$victim_pihole"
# Le healthcheck et keepalived reprennent ; on laisse quelques secondes.
sleep 20

if ! holder_of "$survivor_keep"; then
    echo "La VIP est revenue sur le nœud arrêté alors que nopreempt est actif." >&2
    exit 1
fi
if ! dns_node "$survivor_name" "$survivor_ip"; then
    echo "Le DNS de la VIP ne répond plus après le retour du nœud." >&2
    exit 1
fi

echo "Lab OK : VIP ${VIP}, bascule, et pas de retour agressif."
