# arcus-khakis-cluster

Docker Compose configurations for a 3-node highly-available Arcus Platform cluster spanning three data centers.

## Project Structure

```
arcuscmd.sh                                  # CLI tool for managing the cluster
repair/cassandra-repair.sh                   # Automated Cassandra repair script
repair/entrypoint.sh                         # Sleep-loop scheduler for daily repairs
compose/common.yml                           # Shared service definitions (extended by each DC)
dc1/arcus-khakis-cluster/docker-compose.yml  # DC1: full services (Cassandra, Kafka, Zookeeper)
dc2/arcus-khakis-cluster/docker-compose.yml  # DC2: full services (Cassandra, Kafka, Zookeeper)
dc3/arcus-khakis-cluster/docker-compose.yml  # DC3: Zookeeper quorum only (no Cassandra, no Kafka)
```

Common service config (images, heap, ports, logging, Kafka tuning) lives in `compose/common.yml`; each DC's compose file `extends` it and overrides only DC-specific values (IPs, seeds, DC name, broker/ZK IDs, repair hour). Edit `compose/common.yml` for cluster-wide changes.

## Network Layout

Each DC uses a macvlan network on parent interface `br0`:

| DC  | Subnet           | Cassandra nodes          | Kafka       | Zookeeper    |
|-----|------------------|--------------------------|-------------|--------------|
| DC1 | 192.168.1.0/24   | .10, .11, .12            | .14         | .13          |
| DC2 | 192.168.2.0/24   | .10, .11, .12            | .14         | .13          |
| DC3 | 192.168.3.0/24   | (none)                   | (none)      | .13          |

Cross-DC connectivity depends on host setup outside this repo (OpenVPN TAP tunnels, the `mac0` gateway shim, ufw routed rules). See `docs/host-networking.md`.

## Key Details

- **Images**: Arcus custom images from `us-west1-docker.pkg.dev/arcus-238802/arcus-prod/arcus/`
- **Zookeeper**: `zookeeper:3.8.6`, ensemble across all 3 DCs (`ZOO_MY_ID` 1/2/3)
- **Cassandra DC**: DC1 and DC2 each run three nodes with their own DC name and `GossipingPropertyFileSnitch`
- **Cassandra seeds**: DC1/DC2 nodes seed from each other's `192.168.x.10`
- **Cassandra heap**: `MAX_HEAP_SIZE=768M` (set in `compose/common.yml`)
- **Kafka**: Rack-aware replication, broker IDs 1/2 in DC1/DC2, `KAFKA_PROTOCOL_VERSION=2.6`
- **Logging**: All services use `max-size: 50m`
- **DC3 purpose**: Zookeeper quorum/tiebreaker only — no Cassandra, no Kafka
- **Nodetool path**: `/opt/cassandra/bin/nodetool` (not in default PATH)
- **Cassandra CQL**: Requires macvlan IP (via `docker inspect`), not localhost
- **Nodetool JMX**: Uses `::ffff:127.0.0.1` for the `-h` flag
- **Docker**: Minimum Docker 27.0+, Compose V2 2.29+

## arcuscmd.sh

CLI tool for managing the cluster. Detects docker vs podman automatically.

- `install` — Install/upgrade docker-compose (or podman-compose)
- `status` — Show full Cassandra ring via `nodetool status`
- `check` — Verify all containers are running and reachable (Cassandra UN, Zookeeper mode, etc.)
- `update` — Git pull with fast-forward, show changes
- `apply` — Bring up all services (`docker-compose up -d`), verifies cached DC is still correct
- `deploy` — Rolling Cassandra deploy (one node at a time, waits for UN status)
- `deploy --pull` — Same but pulls images first
- `deploy <svc>` — Deploy a specific service without health checks
- `logs <svc>` — Tail logs for a service
- `shell <svc>` — Open a shell on a service container
- `dbshell` — Open `cqlsh` on cassandra-0
- `repair` — Trigger a manual Cassandra repair

## Automated Cassandra Repair

DC1 and DC2 each run a `cassandra-repair` service (`docker:cli` image) on a daily schedule, staggered across DCs:

| DC | REPAIR_HOUR (UTC) |
|----|-------------------|
| DC1 | 2 |
| DC2 | 6 |

The repair script discovers keyspaces via `cqlsh` and runs `nodetool repair -pr` sequentially on each node.
