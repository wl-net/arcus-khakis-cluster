# arcus-khakis-cluster

[![CI](https://github.com/wl-net/arcus-khakis-cluster/actions/workflows/ci.yml/badge.svg)](https://github.com/wl-net/arcus-khakis-cluster/actions/workflows/ci.yml)

Docker Compose configuration for a 3-node highly-available Arcus Platform cluster spanning three data centers.

## Quick Start

```bash
# Install docker-compose (detects docker vs podman)
./arcuscmd.sh install

# Pull latest changes
./arcuscmd.sh update

# Rolling deploy of Cassandra nodes (one at a time, waits for UN status)
./arcuscmd.sh deploy

# Deploy with fresh image pull
./arcuscmd.sh deploy --pull

# Deploy a specific service
./arcuscmd.sh deploy kafka-0

# Bring up all services after a config change
./arcuscmd.sh apply

# Show Cassandra ring status across all DCs
./arcuscmd.sh status

# Verify all containers are healthy
./arcuscmd.sh check

# Tail logs for a service
./arcuscmd.sh logs cassandra-0

# Open a shell or CQL shell
./arcuscmd.sh shell cassandra-0
./arcuscmd.sh dbshell

# Trigger a manual Cassandra repair
./arcuscmd.sh repair

# Upgrade SSTables on all Cassandra nodes
./arcuscmd.sh upgradesstables
```

## DCs

### DC1

Runs all services (Kafka, Zookeeper, and Cassandra) alongside Arcus Platform. Requires 4-6GB of RAM and 20GB or more of disk space.

| Service | IP Address |
|---|---|
| cassandra-0 | 192.168.1.10 |
| cassandra-1 | 192.168.1.11 |
| cassandra-2 | 192.168.1.12 |
| zookeeper-0 | 192.168.1.13 |
| kafka-0 | 192.168.1.14 |

### DC2

Runs all services (Kafka, Zookeeper, and Cassandra) alongside Arcus Platform. Requires 4-6GB of RAM and 20GB or more of disk space.

| Service | IP Address |
|---|---|
| cassandra-0 | 192.168.2.10 |
| cassandra-1 | 192.168.2.11 |
| cassandra-2 | 192.168.2.12 |
| zookeeper-0 | 192.168.2.13 |
| kafka-0 | 192.168.2.14 |

### DC3

Runs Zookeeper only, as the ensemble tiebreaker — no Cassandra, no Kafka. Requires 1GB of RAM and minimal disk space.

| Service | IP Address |
|---|---|
| zookeeper-0 | 192.168.3.13 |

## Automated Cassandra Repair

DC1 and DC2 each include a `cassandra-repair` service that runs daily repairs, staggered across DCs:

| DC | Repair Time (UTC) |
|---|---|
| DC1 | 02:00 |
| DC2 | 06:00 |

Repairs run sequentially per node within each DC using `nodetool repair -pr`. Logs are captured by the Docker logging driver:

```bash
./arcuscmd.sh logs cassandra-repair
```

To trigger a manual repair:

```bash
./arcuscmd.sh repair
```

## Network

Each DC uses a macvlan network on parent interface `br0`:

| DC | Subnet |
|---|---|
| DC1 | 192.168.1.0/24 |
| DC2 | 192.168.2.0/24 |
| DC3 | 192.168.3.0/24 |

Cross-DC traffic relies on host-level setup that isn't in this repo: OpenVPN TAP tunnels between sites, a `mac0` shim holding each DC's gateway, and ufw routed rules. See [docs/host-networking.md](docs/host-networking.md).
