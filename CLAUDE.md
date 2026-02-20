# arcus-khakis-cluster

Docker Compose configurations for a 3-node highly-available Arcus Platform cluster spanning three data centers.

## Project Structure

```
dc1/arcus-khakis-cluster/docker-compose.yml  # DC1: full services (Cassandra, Kafka, Zookeeper)
dc2/arcus-khakis-cluster/docker-compose.yml  # DC2: full services (Cassandra, Kafka, Zookeeper)
dc3/arcus-khakis-cluster/docker-compose.yml  # DC3: quorum only (Cassandra, Zookeeper, no Kafka)
```

## Network Layout

Each DC uses a macvlan network on parent interface `br0`:

| DC  | Subnet           | Cassandra nodes          | Kafka       | Zookeeper    |
|-----|------------------|--------------------------|-------------|--------------|
| DC1 | 192.168.1.1/24   | .10, .11, .12            | .14         | .13          |
| DC2 | 192.168.2.1/24   | .10, .11, .12            | .13         | .14          |
| DC3 | 192.168.3.1/24   | .10, .11, .12            | (none)      | .13          |

## Key Details

- **Images**: Arcus custom images from `us-west1-docker.pkg.dev/arcus-238802/arcus-prod/arcus/`
- **Zookeeper**: `zookeeper:3.8`, ensemble across all 3 DCs (`ZOO_MY_ID` 1/2/3)
- **Cassandra DC**: Each DC has its own DC name (`DC1`, `DC2`, `DC3`) with `GossipingPropertyFileSnitch`
- **Cassandra seeds**: DC1/DC2 nodes seed from each other's `192.168.x.10`; DC3 seeds from DC1/DC2
- **Cassandra heap**: DC1/DC2 use `MAX_HEAP_SIZE=512M`; DC3 uses `256M` (lightweight quorum node)
- **Kafka**: Rack-aware replication, broker IDs 1/2 in DC1/DC2, `KAFKA_PROTOCOL_VERSION=2.3`
- **Logging**: All services use `max-size: 50m`
- **DC3 purpose**: Quorum/tiebreaker only — no Kafka, smaller heap, `max_attempts: 5` restart policy
