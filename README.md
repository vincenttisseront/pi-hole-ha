# Pi-hole HA cluster — host DNS + Traefik

Two Pi-hole v6 instances with config sync. **Clients use this Docker host as DNS** (port 53). Container IPs are assigned by Docker — nothing like `NODE1_IP` / `VIP` belongs in `.env`.

| Piece | Role |
| --- | --- |
| `pihole-1`, `pihole-2` | Resolvers on your Docker / Traefik network (`vpcbr`, …) |
| [dnsdist](https://dnsdist.org/) | Listens on the **host** `:53`, fails over to a healthy Pi-hole |
| [nebula-sync](https://github.com/lovelaze/nebula-sync) | Copies lists / groups / clients from primary → replica |
| Traefik | Primary admin UI only |

```
LAN clients
      │  DNS = IP of the Docker host
      ▼
   dnsdist :53  (on the host)
   ┌────┴────┐
pihole-1   pihole-2     ← Docker-assigned IPs on vpcbr
   └────┬────┘
   nebula-sync
   Traefik → pihole-1 /admin
```

## Configure

```bash
cp .env.example .env
# DOCKER_NETWORK=vpcbr          # same network as Traefik
# TRAEFIK_HOST=pihole.example.com
# PIHOLE_PASSWORD=...
# DNS_HOST_IP=0.0.0.0           # or the VM LAN IP only
./scripts/preflight.sh
docker compose up -d
./scripts/which-master.sh
```

Point the router / DHCP DNS option at **this host’s IP**. Do not invent a floating VIP in `.env`.

Admin: `https://<TRAEFIK_HOST>/admin/` (Traefik). Edit lists only on the primary.

| Variable | Meaning |
| --- | --- |
| `DOCKER_NETWORK` | Existing Docker network shared with Traefik (e.g. `vpcbr`) |
| `DOCKER_NETWORK_EXTERNAL` | `true` if that network already exists |
| `DNS_HOST_IP` | Host address dnsdist binds (`0.0.0.0` = all interfaces) |
| `TRAEFIK_*` | Reverse-proxy labels for the primary UI |
| `REPLICA_HOST` | Docker DNS name of the replica (`pihole-2`) |

Watchtower: `pihole-1`, `pihole-2`, and `nebula-sync` have `com.centurylinklabs.watchtower.enable=true`. `dnsdist` is a local build and is opted out. Your Watchtower must run with `--label-enable` (or `WATCHTOWER_LABEL_ENABLE=true`).

## Failover

```bash
dig @<host-ip> pi.hole
docker compose stop pihole-1
sleep 6
dig @<host-ip> pi.hole
./scripts/which-master.sh
docker compose start pihole-1
```

dnsdist prefers `pihole-1` when healthy (`firstAvailable`), then `pihole-2`.

## Two Docker hosts

`bundle` keeps both nodes on one engine. To split hosts, use `node1` / `node2` and publish DNS on each host (or keep an external LB). Set `REPLICA_HOST` to a name reachable from the primary for nebula-sync.

## Limits

- Port 53 on the host must be free (disable systemd-resolved stub listener if it binds `53`).
- No Pi-hole DHCP (two DHCP servers would clash); the router stays DHCP and advertises the **host** as DNS.
- `PIHOLE_PASSWORD` must not contain `|`, `,`, `$`, or spaces.
- nebula-sync is not part of Pi-hole. Pi-hole is a trademark of Pi-hole LLC.

## Lab

```bash
./scripts/lab-failover.sh
```

Uses a local bridge, binds DNS on `127.0.0.1`, stops the primary, checks dnsdist still answers.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `preflight` rejects VIP / NODE*_IP | Copy a fresh `.env.example` — those keys are gone |
| network not found | `DOCKER_NETWORK` must match Traefik (`docker network ls`) |
| `failed to bind host port …:53` | See **Port 53 already in use** below |
| Traefik 404 | Pi-hole and Traefik must share `DOCKER_NETWORK` |
| nebula-sync 401 | password mismatch or `\|` inside `PIHOLE_PASSWORD` |

### Port 53 already in use

```bash
sudo ss -ulnp | grep ':53'
sudo ss -tlnp | grep ':53'
```

Prefer binding dnsdist to the VM LAN IP only (avoids clashing with systemd-resolved on `127.0.0.53`):

```bash
# in .env
DNS_HOST_IP=172.24.0.110
sudo docker compose up -d dnsdist
dig @172.24.0.110 pi.hole
```

Or disable the resolved stub, then `DNS_HOST_IP=0.0.0.0` can work:

```bash
sudo sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
```

Logs: `docker compose logs -f dnsdist pihole-1 nebula-sync`.
