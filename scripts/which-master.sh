#!/usr/bin/env bash
# Affiche quel nœud porte la VIP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

VIP="${VIP:?Définis VIP ou passe ENV_FILE}"

found=0
for container in keepalived-1 keepalived-2; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
        echo "$container : conteneur absent"
        continue
    fi
    if docker exec "$container" ip -4 addr show | grep -q " ${VIP}/"; then
        echo "$container détient ${VIP}"
        found=1
    else
        echo "$container ne détient pas ${VIP}"
    fi
done

if ((found == 0)); then
    echo "Aucune VIP ${VIP} sur les nœuds." >&2
    exit 1
fi
