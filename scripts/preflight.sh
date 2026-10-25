#!/usr/bin/env bash
# Vérifie .env avant de démarrer le cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Fichier manquant : $ENV_FILE" >&2
    echo "Copie .env.example vers .env (réseau Docker + Traefik + mot de passe)." >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
    COMPOSE_PROFILES TZ PIHOLE_PASSWORD UPSTREAM_1 UPSTREAM_2
    SYNC_CRON DOCKER_NETWORK
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

if [[ "$PIHOLE_PASSWORD" == *'|'* || "$PIHOLE_PASSWORD" == *','* || "$PIHOLE_PASSWORD" == *'$'* || "$PIHOLE_PASSWORD" == *' '* ]]; then
    echo "PIHOLE_PASSWORD ne doit contenir ni | ni , ni \$ ni espace (format nebula-sync)." >&2
    exit 1
fi

if [[ "$PIHOLE_PASSWORD" == "changeme-now" || ${#PIHOLE_PASSWORD} -lt 8 ]]; then
    echo "Choisis un PIHOLE_PASSWORD d'au moins 8 caractères, différent de l'exemple." >&2
    exit 1
fi

obsolete='^(NODE1_IP|NODE2_IP|VIP|VIP_CIDR|LAN_PARENT|LAN_SUBNET|LAN_GATEWAY|VRRP_ROUTER_ID|VRRP_AUTH_PASS)='
if grep -qE "$obsolete" "$ENV_FILE"; then
    echo "Ce .env contient encore des variables macvlan/VIP (NODE*_IP, VIP, LAN_*, VRRP_*)." >&2
    echo "Ce mode est abandonné : le DNS est l'hôte Docker, les IP des nœuds sont assignées par Docker." >&2
    echo "Repars de .env.example (DOCKER_NETWORK=vpcbr, Traefik, pas de VIP)." >&2
    exit 1
fi

DOCKER_NETWORK_EXTERNAL="${DOCKER_NETWORK_EXTERNAL:-true}"
TRAEFIK_ENABLE="${TRAEFIK_ENABLE:-false}"
DNS_HOST_IP="${DNS_HOST_IP:-0.0.0.0}"

case "$DOCKER_NETWORK_EXTERNAL" in
    true|false) ;;
    *)
        echo "DOCKER_NETWORK_EXTERNAL=$DOCKER_NETWORK_EXTERNAL : attendu true ou false." >&2
        exit 1
        ;;
esac

if [[ "$DOCKER_NETWORK_EXTERNAL" == "true" ]]; then
    if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        echo "Réseau Docker introuvable : $DOCKER_NETWORK" >&2
        echo "Il doit être celui de Traefik (souvent vpcbr). Liste : docker network ls" >&2
        exit 1
    fi
fi

case "$TRAEFIK_ENABLE" in
    true|false) ;;
    *)
        echo "TRAEFIK_ENABLE=$TRAEFIK_ENABLE : attendu true ou false." >&2
        exit 1
        ;;
esac

if [[ "$TRAEFIK_ENABLE" == "true" ]]; then
    if [[ -z "${TRAEFIK_HOST:-}" || "$TRAEFIK_HOST" == "pihole.example.com" ]]; then
        echo "TRAEFIK_ENABLE=true : renseigne TRAEFIK_HOST." >&2
        exit 1
    fi
fi

host_ips="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | paste -sd, - || true)"
echo "Préflight OK ($COMPOSE_PROFILES, réseau ${DOCKER_NETWORK}, DNS = hôte ${DNS_HOST_IP}, IP hôte: ${host_ips:-?})."
if [[ "$TRAEFIK_ENABLE" == "true" ]]; then
    echo "  Traefik admin : https://${TRAEFIK_HOST}/admin/ (réseau ${DOCKER_NETWORK})"
fi
echo "  Clients DNS : pointe le routeur vers l'IP de cet hôte (pas une VIP dans .env)."
