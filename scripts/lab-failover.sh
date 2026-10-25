#!/usr/bin/env bash
# Vérifie la bascule de VIP sur un bridge Docker, sans toucher au LAN.
# Les services viennent de docker-compose.yml ; seul le réseau est remplacé.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="$ROOT/.env.lab"
LAB_COMPOSE="$(mktemp)"
export ENV_FILE PREFLIGHT_SKIP_NIC=1

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
    if [[ "${LAB_LEGACY_FW:-0}" == 1 && -n "${LAN_SUBNET:-}" ]]; then
        sudo iptables-legacy -D FORWARD -s "$LAN_SUBNET" -j ACCEPT >/dev/null 2>&1 || true
        sudo iptables-legacy -D FORWARD -d "$LAN_SUBNET" -j ACCEPT >/dev/null 2>&1 || true
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

# Ce noyau de lab n'a pas forcément macvlan. On garde les services du
# compose de production et on remplace seulement le réseau par un bridge,
# pour pouvoir joindre la VIP depuis l'hôte sans toucher au LAN.
python3 - "$ROOT/docker-compose.yml" "$LAB_COMPOSE" <<'PY'
import sys
from pathlib import Path
source, dest = sys.argv[1:]
text = Path(source).read_text()
head, sep, _ = text.partition("\nnetworks:\n")
if not sep:
    raise SystemExit("bloc networks introuvable dans docker-compose.yml")
Path(dest).write_text(head + """
networks:
  cluster:
    name: pihole-lab
    driver: bridge
    ipam:
      config:
        - subnet: 192.168.199.0/24
          gateway: 192.168.199.1
  traefik:
    name: pihole-lab-proxy
    driver: bridge
""")
PY

cp "$ROOT/env.lab.example" "$ENV_FILE"
"$ROOT/scripts/preflight.sh"

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

# Certains hôtes ont iptables-legacy (FORWARD DROP) en plus des règles nft
# que Docker programme. Le subnet du lab n'est alors pas routé : Pi-hole ne
# peut pas télécharger gravity. On ouvre ce subnet uniquement pour le test.
if sudo iptables-legacy -S FORWARD 2>/dev/null | head -n 1 | grep -q -- '-P FORWARD DROP'; then
    LAB_LEGACY_FW=1
    sudo iptables-legacy -C FORWARD -s "$LAN_SUBNET" -j ACCEPT 2>/dev/null \
        || sudo iptables-legacy -I FORWARD 1 -s "$LAN_SUBNET" -j ACCEPT
    sudo iptables-legacy -C FORWARD -d "$LAN_SUBNET" -j ACCEPT 2>/dev/null \
        || sudo iptables-legacy -I FORWARD 1 -d "$LAN_SUBNET" -j ACCEPT
fi

sudo rm -rf "$ROOT/data"

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
