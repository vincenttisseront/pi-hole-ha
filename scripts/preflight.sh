#!/usr/bin/env bash
# Vérifie .env avant de créer le réseau macvlan et les conteneurs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Fichier manquant : $ENV_FILE" >&2
    echo "Copie .env.example vers .env et renseigne les adresses du LAN." >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
    COMPOSE_PROFILES TZ LAN_PARENT LAN_SUBNET LAN_GATEWAY
    NODE1_IP NODE2_IP VIP VIP_CIDR VRRP_ROUTER_ID VRRP_AUTH_PASS
    PIHOLE_PASSWORD UPSTREAM_1 UPSTREAM_2 SYNC_CRON
)
for name in "${required[@]}"; do
    if [[ -z "${!name:-}" ]]; then
        echo "Variable vide : $name" >&2
        exit 1
    fi
done

case "$COMPOSE_PROFILES" in
    bundle|node1|node2) ;;
    *)
        echo "COMPOSE_PROFILES=$COMPOSE_PROFILES : attendu bundle, node1 ou node2." >&2
        exit 1
        ;;
esac

if ((${#VRRP_AUTH_PASS} > 8)); then
    echo "VRRP_AUTH_PASS fait ${#VRRP_AUTH_PASS} caractères ; maximum 8." >&2
    exit 1
fi

if ((VRRP_ROUTER_ID < 1 || VRRP_ROUTER_ID > 255)); then
    echo "VRRP_ROUTER_ID doit être entre 1 et 255." >&2
    exit 1
fi

if [[ "$PIHOLE_PASSWORD" == *'|'* || "$PIHOLE_PASSWORD" == *','* || "$PIHOLE_PASSWORD" == *'$'* || "$PIHOLE_PASSWORD" == *' '* ]]; then
    echo "PIHOLE_PASSWORD ne doit contenir ni | ni , ni \$ ni espace (format nebula-sync)." >&2
    exit 1
fi

if [[ "$PIHOLE_PASSWORD" == "changeme-now" || ${#PIHOLE_PASSWORD} -lt 8 ]]; then
    echo "Choisis un PIHOLE_PASSWORD d'au moins 8 caractères, différent de l'exemple." >&2
    exit 1
fi

python3 - "$LAN_SUBNET" "$LAN_GATEWAY" "$NODE1_IP" "$NODE2_IP" "$VIP" "$VIP_CIDR" <<'PY'
import ipaddress, sys
subnet = ipaddress.ip_network(sys.argv[1], strict=False)
gateway, node1, node2, vip = map(ipaddress.ip_address, sys.argv[2:6])
vip_cidr = sys.argv[6]
seen = {}
for name, ip in (("LAN_GATEWAY", gateway), ("NODE1_IP", node1), ("NODE2_IP", node2), ("VIP", vip)):
    if ip not in subnet:
        sys.exit(f"{name}={ip} n'est pas dans {subnet}")
    if ip in seen:
        sys.exit(f"{name} et {seen[ip]} utilisent la même adresse")
    seen[ip] = name
if not vip_cidr.startswith(f"{vip}/"):
    sys.exit("VIP_CIDR doit être VIP suivi du masque, par exemple 192.168.1.10/24")
prefix = int(vip_cidr.split("/", 1)[1])
if prefix != subnet.prefixlen:
    sys.exit(f"VIP_CIDR /{prefix} doit avoir le même masque que LAN_SUBNET (/{subnet.prefixlen})")
PY

if [[ "${PREFLIGHT_SKIP_NIC:-0}" != "1" ]]; then
    if ! ip link show "$LAN_PARENT" >/dev/null 2>&1; then
        echo "Interface LAN_PARENT=$LAN_PARENT introuvable. Regarde 'ip -br link'." >&2
        exit 1
    fi
fi

TRAEFIK_ENABLE="${TRAEFIK_ENABLE:-false}"
TRAEFIK_EXTERNAL="${TRAEFIK_EXTERNAL:-true}"
TRAEFIK_DOCKER_NETWORK="${TRAEFIK_DOCKER_NETWORK:-traefik}"
TRAEFIK_HOST="${TRAEFIK_HOST:-}"
TRAEFIK_REPLICA_ENABLE="${TRAEFIK_REPLICA_ENABLE:-false}"

case "$TRAEFIK_ENABLE" in
    true|false) ;;
    *)
        echo "TRAEFIK_ENABLE=$TRAEFIK_ENABLE : attendu true ou false." >&2
        exit 1
        ;;
esac

case "$TRAEFIK_EXTERNAL" in
    true|false) ;;
    *)
        echo "TRAEFIK_EXTERNAL=$TRAEFIK_EXTERNAL : attendu true ou false." >&2
        exit 1
        ;;
esac

if [[ "$TRAEFIK_ENABLE" == "true" ]]; then
    if [[ -z "$TRAEFIK_HOST" || "$TRAEFIK_HOST" == "pihole.example.com" ]]; then
        echo "TRAEFIK_ENABLE=true : renseigne TRAEFIK_HOST (pas l'exemple pihole.example.com)." >&2
        exit 1
    fi
    if [[ "$TRAEFIK_EXTERNAL" == "true" ]]; then
        if ! docker network inspect "$TRAEFIK_DOCKER_NETWORK" >/dev/null 2>&1; then
            echo "Réseau Docker Traefik introuvable : $TRAEFIK_DOCKER_NETWORK" >&2
            echo "Crée-le avec ton stack Traefik, ou mets TRAEFIK_EXTERNAL=false pour un bridge local." >&2
            exit 1
        fi
    fi
    if [[ "$TRAEFIK_REPLICA_ENABLE" == "true" && -z "${TRAEFIK_HOST_REPLICA:-}" ]]; then
        echo "TRAEFIK_REPLICA_ENABLE=true exige TRAEFIK_HOST_REPLICA." >&2
        exit 1
    fi
fi

extra=""
if [[ "$TRAEFIK_ENABLE" == "true" ]]; then
    extra=", Traefik Host ${TRAEFIK_HOST} via ${TRAEFIK_DOCKER_NETWORK}"
fi
echo "Préflight OK ($COMPOSE_PROFILES, VIP ${VIP}, nœuds ${NODE1_IP} et ${NODE2_IP}, parent ${LAN_PARENT}${extra})."
