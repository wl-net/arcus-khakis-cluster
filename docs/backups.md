# Cassandra Backups

DC1 and DC2 each run a `cassandra-backup` service (`docker:cli` image, same
pattern as `cassandra-repair`) that takes a weekly backup of the local
Cassandra nodes:

| DC | Schedule (UTC) |
|----|----------------|
| DC1 | Sunday 12:00 |
| DC2 | Sunday 16:00 |

Each run:

1. Dumps the schema from one node (`cqlsh -e 'DESCRIBE SCHEMA'`) — restoring
   SSTables requires recreating the schema first.
2. Takes a `nodetool snapshot` on every local node.
3. Exports each node's snapshot as a tarball, then clears the snapshot.
4. Prunes anything older than `BACKUP_RETAIN_DAYS` (default 28).

Output lands on the host in `/var/backups/arcus-khakis-cluster/`:

```
schema-backup-YYYYMMDD.cql
<container>-backup-YYYYMMDD.tar.gz   # one per Cassandra node
```

Every `docker exec` step is wrapped in `timeout` (`BACKUP_TIMEOUT`, default
3600s) so a hung node can't wedge the weekly schedule. The script exits
non-zero if any step failed, which the scheduler logs as
"finished with errors":

```bash
./arcuscmd.sh logs cassandra-backup
```

A manual run: `docker compose exec cassandra-backup /backup/cassandra-backup.sh`
(or `./arcuscmd.sh backup`, which is the interactive equivalent and writes to
`./cassandra-backups/` instead).

## Offsite copies (pull model)

The cluster hosts deliberately have **no credentials to push backups
anywhere**. A separate backup system pulls the files off each host, e.g.:

```bash
# On the backup machine (not a cluster host), e.g. via cron
rsync -az --delete site1:/var/backups/arcus-khakis-cluster/ /srv/backups/arcus/dc1/
rsync -az --delete site2:/var/backups/arcus-khakis-cluster/ /srv/backups/arcus/dc2/
```

This keeps the blast radius of a compromised cluster host to its own data:
it can't reach the backup store. The backup machine's SSH access to the
hosts can be restricted to rsync-only via `command=` in `authorized_keys`
(or rrsync) if desired.

Cassandra data is replicated between DC1 and DC2, so the two DCs' backups
are redundant copies of (roughly) the same data taken 4 hours apart.

## Restore (outline)

For a lost keyspace/table (cluster still healthy):

1. Recreate the schema objects from `schema-backup-YYYYMMDD.cql` if missing.
2. Extract the matching table directories from each node's tarball; paths
   inside are `data/<keyspace>/<table-uuid>/snapshots/<tag>/...`.
3. Copy the snapshot files into the live table directory on each node
   (`/data/data/<keyspace>/<table-uuid>/`) and run
   `nodetool refresh <keyspace> <table>`, or use `sstableloader` to stream
   them in (handles token ownership changes).

For full-cluster disaster recovery, restore the schema first, then
`sstableloader` each node's tarball contents into the rebuilt cluster.

Test a restore occasionally — an unverified backup is a hope, not a backup.
