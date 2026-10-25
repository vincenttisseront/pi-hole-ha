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

newServer({
  address="${P1}:53",
  name="pihole-1",
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
