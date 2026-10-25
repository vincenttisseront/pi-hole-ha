# Cluster Pi-hole — deux nœuds, une VIP

Deux Pi-hole v6 derrière **une seule adresse DNS**. Si le nœud qui porte cette adresse ne répond plus, l’autre la prend. Les listes et la configuration du primaire sont poussées vers le réplica.

Pi-hole n’a pas de mode cluster. Ce dépôt le construit avec trois briques :

| Brique | Rôle |
| --- | --- |
| `pihole-1`, `pihole-2` | Deux résolveurs indépendants, chacun avec sa propre base |
| keepalived | Protocole VRRP : une VIP unique, retirée si le DNS local ne répond plus |
| [nebula-sync](https://github.com/lovelaze/nebula-sync) | Pousse la configuration du primaire vers le réplica (API Pi-hole v6) |

```
clients du LAN
      │  DNS = VIP uniquement
      ▼
  192.168.1.10  ◄── VRRP, une seule des deux machines à la fois
   ┌────┴────┐
pihole-1   pihole-2
 .11         .12
   └────┬────┘
   nebula-sync
   primaire → réplica
```

Le DHCP des Pi-hole est éteint. Le routeur reste serveur DHCP et annonce **seulement la VIP** comme DNS.

## Démarrage sur une machine

Il faut Docker Engine avec le plugin Compose, et une interface Ethernet (ou Wi-Fi) qui accepte le mode promiscuous. Quatre adresses du même sous-réseau : la passerelle, deux nœuds, la VIP. Elles doivent être **en dehors** du pool DHCP.

```bash
cp .env.example .env
# Éditer LAN_PARENT, le sous-réseau, les trois adresses et PIHOLE_PASSWORD.
./scripts/preflight.sh
docker compose up -d --build
./scripts/which-master.sh
```

L’interface d’admin du primaire : `http://<NODE1_IP>/admin`. Le mot de passe est `PIHOLE_PASSWORD`.

Les modifications (listes, domaines, groupes, clients) se font **sur le primaire**. nebula-sync les recopie vers le réplica. Une modification faite sur le réplica, ou via la VIP quand elle est sur le réplica, sera écrasée.

`SYNC_CRON` est à toutes les 15 minutes. Un cron chaque minute finit par faire échouer l’authentification de l’API.

## Bascule

```bash
dig @192.168.1.10 pi.hole
docker compose stop pihole-1
sleep 8
dig @192.168.1.10 pihole-2.cluster
./scripts/which-master.sh
docker compose start pihole-1
```

`pihole-1.cluster` et `pihole-2.cluster` sont des enregistrements locaux. Celui qui répond indique quel nœud porte la VIP.

Les deux nœuds sont `BACKUP` avec `nopreempt`. Au démarrage, la priorité 150 gagne. Après une panne, le survivant garde la VIP quand l’autre revient : pas de second coupure le temps d’un retour. Pour rendre la VIP au primaire : `docker compose restart keepalived-2`.

Le contrôle de santé interroge `127.0.0.1` en DNS toutes les 2 secondes. Deux échecs et la priorité tombe de 60, sous celle du réplica, donc la VIP part même si le conteneur est encore là.

## Deux machines

`COMPOSE_PROFILES=bundle` lance les deux nœuds dans le même moteur Docker. Si cette machine s’éteint, les deux s’éteignent.

Pour tenir la perte d’un hôte, même fichier, deux `.env` :

| | Machine 1 | Machine 2 |
| --- | --- | --- |
| `COMPOSE_PROFILES` | `node1` | `node2` |
| `LAN_PARENT` | l’interface de cette machine | l’interface de cette machine |
| adresses, VIP, `VRRP_ROUTER_ID`, `VRRP_AUTH_PASS` | identiques | identiques |

Les deux hôtes sont dans le **même VLAN**. Sinon la VIP ne peut pas migrer (ARP).

```bash
docker compose up -d --build
```

Sur la machine 2, le service keepalived s’appelle `keepalived-2-node` : c’est lui qui construit l’image, puisque `keepalived-1` n’est pas sur cet hôte. Le conteneur reste `keepalived-2`.

Ouvrir entre les nœuds : TCP 80 (synchro) et le protocole IP 112 (VRRP unicast). Les clients n’ont besoin que de UDP/TCP 53 vers la VIP.

Ne lance pas `bundle` sur les deux machines : les adresses seraient en double.

## L’hôte Docker ne joint pas la VIP

macvlan isole l’hôte de ses propres conteneurs. Les autres machines du LAN, elles, joignent la VIP. Pour que l’hôte s’en serve aussi, une interface shim (remplace les noms par ceux de `.env`) :

```bash
sudo ip link add pihole-shim link eth0 type macvlan mode bridge
sudo ip addr add 192.168.1.9/32 dev pihole-shim
sudo ip link set pihole-shim up
sudo ip route add 192.168.1.10/32 dev pihole-shim
```

`192.168.1.9` doit être libre et différente de la passerelle, des nœuds et de la VIP.

## Limites

- Pas de DHCP Pi-hole : deux serveurs DHCP sur le même segment se marchent dessus.
- `FTLCONF_dns_listeningMode=ALL` répond sur toutes les interfaces, y compris la VIP. Ne pas publier le port 53 vers Internet.
- Le mot de passe d’API est celui de `.env`. Il ne doit contenir ni `|`, ni `,`, ni `$`, ni espace : nebula-sync coupe sur `|`.
- `VRRP_AUTH_PASS` fait 8 caractères au plus.
- nebula-sync n’est pas un composant Pi-hole. Pi-hole est une marque de Pi-hole LLC.

## Lab sans toucher au LAN

`scripts/lab-failover.sh` reprend les mêmes services et les branche sur un bridge Docker (pas d’interface physique, pas de macvlan). Il vérifie qu’un `dig` vers la VIP répond, arrête le nœud qui la porte, et vérifie que l’autre répond. Il détruit le lab en sortant.

```bash
./scripts/lab-failover.sh
```

## Dépannage

| Symptôme | Piste |
| --- | --- |
| `network cluster ... parent` | `LAN_PARENT` n’existe pas, ou n’est pas up. `ip -br link`. |
| La VIP ne bascule pas | Pare-feu qui jette le protocole 112 entre les deux IP de nœud. Même `VRRP_ROUTER_ID` et le même mot de passe des deux côtés. |
| Les clients gardent l’ancienne machine | Cache ARP. keepalived envoie des gratuitous ARP ; un `ping` de la VIP depuis le client aide. |
| nebula-sync 401 / 403 | Mot de passe différent de `PIHOLE_PASSWORD`, ou `|` dedans. Les deux nœuds doivent être up (`docker compose ps`). |
| L’admin de la VIP ne montre pas le primaire | Normal quand la VIP est sur le réplica. Toujours éditer `http://<NODE1_IP>/admin`. |
| `which-master` ne voit pas la VIP | `docker compose logs keepalived-1 keepalived-2`. Le script DNS a échoué si `dig @127.0.0.1` depuis le nœud échoue. |

Journaux : `docker compose logs -f pihole-1 nebula-sync keepalived-1`.
