# arcus-khakis-cluster

This project contains docker-compose configuration suitable for bringing up a 3 node cluster of Arcus Platform. It should be seen as the bare minimum to run a highly-avaialable instance of Arcus Platform.

# DCs

## DC1

This DC runs all services (Kafka, Zookeeper, and Cassandra) and is designed to run alongside Arcus Platform. Requires 4-6GB of RAM and 20GB or more of disk space.

| Service | IP Address  |
|---|---|
| casandra-0  | 192.168.1.10  |
| casandra-1  | 192.168.1.11  |
| casandra-2  | 192.168.1.12  |
| kafka-0  | 192.168.1.13  |
| zookeeper-0  | 192.168.1.14  |

## DC2

This DC runs all services (Kafka, Zookeeper, and Cassandra) and is designed to run alongside Arcus Platform. Requires 4-6GB of RAM and 20GB or more of disk space.

| Service | IP Address  |
|---|---|
| casandra-0  | 192.168.2.10  |
| casandra-1  | 192.168.2.11  |
| casandra-2  | 192.168.2.12  |
| kafka-0  | 192.168.2.13  |
| zookeeper-0  | 192.168.2.14  |

## DC3

This DC runs minimal services (Kafka and Cassandra) and is designed to run to solve quorum issues ONLY. Requires 2GB of RAM and 10GB or more of disk space.


| Service | IP Address  |
|---|---|
| casandra-0  | 192.168.3.10  |
| casandra-1  | 192.168.3.11  |
| casandra-2  | 192.168.3.12  |
| zookeeper-0  | 192.168.3.13  |