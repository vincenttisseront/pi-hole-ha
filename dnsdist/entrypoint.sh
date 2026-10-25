#!/bin/sh
set -eu

resolve() {
    host="$1"
    i=0
    while [ "$i" -lt 60 ]; do
        ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 { print $1; exit }' || true)"
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    echo "Impossible de résoudre $host" >&2
    return 1
}

P1="$(resolve pihole-1)"
P2="$(resolve pihole-2)"

echo "dnsdist backends: pihole-1=${P1} pihole-2=${P2}"

cat > /tmp/dnsdist.conf <<EOF
setLocal("0.0.0.0:53")
setACL({"0.0.0.0/0", "::/0"})

-- Remonter l'IP client réelle à Pi-hole via EDNS Client Subnet (ECS).
-- Pi-hole : dns.EDNS0ECS = true (défaut) → le Query Log affiche le client, pas dnsdist.
setECSOverride(true)
setECSSourcePrefixV4(32)
setECSSourcePrefixV6(128)

newServer({
  address="${P1}:53",
  name="pihole-1",
  useClientSubnet=true,
  checkName="pi.hole.",
  checkType="A",
  checkInterval=2,
  checkTimeout=1000,
  maxCheckFailures=2,
  rise=2,
  order=1,
})

newServer({
  address="${P2}:53",
  name="pihole-2",
  useClientSubnet=true,
  checkName="pi.hole.",
  checkType="A",
  checkInterval=2,
  checkTimeout=1000,
  maxCheckFailures=2,
  rise=2,
  order=2,
})

setServerPolicy(firstAvailable)
EOF

exec dnsdist --supervised --disable-syslog -C /tmp/dnsdist.conf
