#!/usr/bin/env bash
# Affiche l'état des backends dnsdist (quel Pi-hole répond derrière l'hôte).
set -euo pipefail

if ! docker inspect dnsdist >/dev/null 2>&1; then
    echo "Conteneur dnsdist absent (profil bundle ?)." >&2
    exit 1
fi

echo "dnsdist (dernières lignes) :"
docker logs dnsdist --tail 30 2>&1 || true
echo
echo "Probe DNS hôte :"
dig +time=2 +tries=1 +short @127.0.0.1 pi.hole A 2>/dev/null \
    || dig +time=2 +tries=1 +short @$(hostname -I | awk '{print $1}') pi.hole A 2>/dev/null \
    || true

echo
echo "IP Docker des nœuds :"
for c in pihole-1 pihole-2; do
    if docker inspect "$c" >/dev/null 2>&1; then
        docker inspect -f "{{.Name}} {{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}}={{\$v.IPAddress}} {{end}}" "$c"
    else
        echo "$c : absent"
    fi
done
