# Pi-hole HA cluster — two nodes, one VIP

Two Pi-hole v6 instances behind **a single DNS address**. When the node holding that address stops answering, the other takes it. Blocklists and primary configuration are pushed to the replica.

Pi-hole has no built-in cluster mode. This repo builds one from three pieces:

| Piece | Role |
| --- | --- |
| `pihole-1`, `pihole-2` | Independent resolvers, each with its own database |
| keepalived | VRRP: one VIP, removed when the local DNS check fails |
| [nebula-sync](https://github.com/lovelaze/nebula-sync) | Copies lists, groups, clients, and domains from primary to replica |

```
LAN clients
      │  DNS = VIP only
      ▼
  192.168.1.10  ◄── VRRP, only one host at a time
   ┌────┴────┐
pihole-1   pihole-2
 (Docker)   (Docker)
   └────┬────┘
   nebula-sync
   primary → replica
```

Pi-hole DHCP is disabled. Your router stays the DHCP server and advertises **only the VIP** as DNS.

Container IPs for `pihole-1` / `pihole-2` are **assigned by Docker** on the macvlan network. Do **not** put them in `.env`. Only the floating VIP (reserved via IPAM `aux_addresses`) belongs there.

## Single-host start

You need Docker Engine with the Compose plugin, and a NIC that supports promiscuous mode. Choose a VIP on the LAN subnet, outside the DHCP pool. Gateway + VIP go in `.env`; node addresses do not.

```bash
cp .env.example .env
# Set LAN_PARENT, LAN_SUBNET, LAN_GATEWAY, VIP, PIHOLE_PASSWORD, Traefik.
./scripts/preflight.sh
docker compose up -d --build
./scripts/which-master.sh
docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}} {{end}}' pihole-1 pihole-2
```

Primary admin UI: Traefik (`https://<TRAEFIK_HOST>/admin/`) when enabled. Password is `PIHOLE_PASSWORD`.

### Traefik (admin UI only)

DNS stays on the VIP / macvlan. Traefik only proxies the **primary** web UI.

In `.env` (defaults assume you already run Traefik):

| Variable | Typical value |
| --- | --- |
| `TRAEFIK_ENABLE` | `true` |
| `TRAEFIK_EXTERNAL` | `true` |
| `TRAEFIK_DOCKER_NETWORK` | name of your Traefik Docker network (`docker network ls`) |
| `TRAEFIK_HOST` | `pihole.your.domain` |
| `TRAEFIK_ENTRYPOINT` | `websecure` |
| `TRAEFIK_CERTRESOLVER` | your ACME resolver name |
| `TRAEFIK_REPLICA_ENABLE` | `false` (keep edits on the primary) |

Traefik must share `TRAEFIK_DOCKER_NETWORK` with this stack. `/` redirects to `/admin/`.

Without Traefik: `TRAEFIK_ENABLE=false` and `TRAEFIK_EXTERNAL=false`.

Change lists, domains, groups, and clients **on the primary**. nebula-sync copies them to the replica. Edits on the replica (or on the VIP while it sits on the replica) are overwritten.

Upstreams, listening mode, and DHCP are not synced: they come from `.env` and are the same on both nodes. Pi-hole locks any value set through `FTLCONF_*`. A full config Teleporter import hits those keys and the API returns 400.

`SYNC_CRON` defaults to every 15 minutes. A one-minute cron tends to break API authentication.

## Failover

```bash
dig @192.168.1.10 pi.hole
docker compose stop pihole-1
sleep 8
dig @192.168.1.10 pi.hole
./scripts/which-master.sh
docker compose start pihole-1
```

Both nodes start as `BACKUP` with `nopreempt`. At boot, priority 150 wins. After a failure, the survivor keeps the VIP when the other returns — no second cutover on recovery. To hand the VIP back to the primary: `docker compose restart keepalived-2`.

The health check queries `127.0.0.1` over DNS every 2 seconds. Two failures drop priority by 60, below the replica, so the VIP moves even if the container is still running.

## Two hosts

`COMPOSE_PROFILES=bundle` runs both nodes on one Docker engine. If that machine dies, both die.

To survive host loss, use the same compose file with two `.env` files:

| | Host 1 | Host 2 |
| --- | --- | --- |
| `COMPOSE_PROFILES` | `node1` | `node2` |
| `LAN_PARENT` | that host’s NIC | that host’s NIC |
| `VIP`, `VRRP_ROUTER_ID`, `VRRP_AUTH_PASS` | identical | identical |
| `PEER_HOST_1` / `REPLICA_HOST` | hostname or IP of host 2’s pihole | — |
| `PEER_HOST_2` | — | hostname or IP of host 1’s pihole |

On a single Docker engine (`bundle`), leave `PEER_HOST_*` / `REPLICA_HOST` at the defaults (`pihole-2` / `pihole-1`): keepalived and nebula-sync resolve them via Docker DNS after containers get their IPs.

Both hosts must be on the **same VLAN**. Otherwise the VIP cannot migrate (ARP).

```bash
docker compose up -d --build
```

On host 2 the keepalived service is named `keepalived-2-node` so it can build the image (host 2 does not run `keepalived-1`). The container name remains `keepalived-2`.

Open between nodes: TCP 80 (sync) and IP protocol 112 (VRRP unicast). Clients only need UDP/TCP 53 to the VIP.

Do not run `bundle` on both hosts — the node addresses would collide.

## Docker host cannot reach the VIP

macvlan isolates the host from its own containers. Other LAN machines can still reach the VIP. For the host itself, add a shim interface (replace names with values from `.env`):

```bash
sudo ip link add pihole-shim link eth0 type macvlan mode bridge
sudo ip addr add 192.168.1.9/32 dev pihole-shim
sudo ip link set pihole-shim up
sudo ip route add 192.168.1.10/32 dev pihole-shim
```

`192.168.1.9` must be free and different from the gateway, nodes, and VIP.

## Limits

- No Pi-hole DHCP: two DHCP servers on one segment fight each other.
- `FTLCONF_dns_listeningMode=ALL` answers on every interface, including the VIP. Do not expose port 53 to the internet.
- The API password is the one in `.env`. It must not contain `|`, `,`, `$`, or spaces — nebula-sync splits on `|`.
- `VRRP_AUTH_PASS` is at most 8 characters.
- nebula-sync is not a Pi-hole component. Pi-hole is a trademark of Pi-hole LLC.

## Lab without touching the LAN

`scripts/lab-failover.sh` uses the same services on a Docker bridge (no physical NIC, no macvlan). It checks that `dig` against the VIP works, stops the VIP holder, and checks that the other node answers. It tears the lab down on exit.

```bash
./scripts/lab-failover.sh
```

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `network cluster ... parent` | `LAN_PARENT` missing or down. Run `ip -br link`. |
| VIP does not fail over | Firewall dropping protocol 112 between node IPs. Same `VRRP_ROUTER_ID` and password on both sides. |
| Clients stick to the old host | ARP cache. keepalived sends gratuitous ARP; pinging the VIP from the client helps. |
| nebula-sync 401 / 403 | Password differs from `PIHOLE_PASSWORD`, or contains `\|`. Both nodes must be up (`docker compose ps`). |
| VIP admin UI is not the primary | Expected when the VIP sits on the replica. Always edit `http://<NODE1_IP>/admin`. |
| `which-master` sees no VIP | `docker compose logs keepalived-1 keepalived-2`. The DNS script failed if `dig @127.0.0.1` from the node fails. |

Logs: `docker compose logs -f pihole-1 nebula-sync keepalived-1`.
