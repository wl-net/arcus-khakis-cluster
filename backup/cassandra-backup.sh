#!/bin/sh

# Weekly Cassandra backup: schema dump + snapshot + export to $BACKUP_DIR.
# An external system pulls the files off this host; nothing here has (or
# should be given) credentials to push them anywhere.

BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-28}"
# Max seconds for a single step (schema dump, snapshot, per-node export)
# before giving up. busybox timeout exits 143 on expiry, not GNU's 124.
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-3600}"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [backup] $*"
}

TAG="backup-$(date -u +%Y%m%d)"
FAILURES=0

if [ ! -d "$BACKUP_DIR" ]; then
  log "ERROR: Backup directory $BACKUP_DIR is not mounted"
  exit 1
fi

# Find local Cassandra containers by compose service label
CONTAINERS=$(docker ps --filter "label=com.docker.compose.service" --format '{{.Names}}' | grep -E 'cassandra-[0-9]+' | sort)

if [ -z "$CONTAINERS" ]; then
  log "ERROR: No running Cassandra containers found"
  exit 1
fi

log "Found Cassandra containers: $(echo "$CONTAINERS" | tr '\n' ' ')"

# Dump the schema first: restoring SSTables requires recreating the schema
FIRST_NODE=$(echo "$CONTAINERS" | head -n1)
FIRST_NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$FIRST_NODE")
log "Dumping schema from $FIRST_NODE ($FIRST_NODE_IP)..."
if timeout "$BACKUP_TIMEOUT" docker exec "$FIRST_NODE" /opt/cassandra/bin/cqlsh "$FIRST_NODE_IP" -e "DESCRIBE SCHEMA" > "$BACKUP_DIR/schema-$TAG.cql"; then
  log "Schema saved to schema-$TAG.cql"
else
  RC=$?
  log "WARNING: Schema dump failed (exit code $RC)"
  rm -f "$BACKUP_DIR/schema-$TAG.cql"
  FAILURES=$((FAILURES + 1))
fi

for CONTAINER in $CONTAINERS; do
  log "--- Backing up $CONTAINER ---"

  if timeout "$BACKUP_TIMEOUT" docker exec "$CONTAINER" /opt/cassandra/bin/nodetool -h "::ffff:127.0.0.1" snapshot -t "$TAG"; then
    :
  else
    RC=$?
    log "WARNING: Snapshot failed on $CONTAINER (exit code $RC), skipping export"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  OUTFILE="$BACKUP_DIR/$CONTAINER-$TAG.tar.gz"
  log "Exporting snapshot to $(basename "$OUTFILE")..."
  if timeout "$BACKUP_TIMEOUT" docker exec "$CONTAINER" sh -c "cd /data && find data -path '*/snapshots/$TAG/*' -type f | tar czf - -T -" > "$OUTFILE"; then
    log "Exported $(du -h "$OUTFILE" | cut -f1)"
  else
    RC=$?
    log "WARNING: Export failed on $CONTAINER (exit code $RC)"
    rm -f "$OUTFILE"
    FAILURES=$((FAILURES + 1))
  fi

  if timeout "$BACKUP_TIMEOUT" docker exec "$CONTAINER" /opt/cassandra/bin/nodetool -h "::ffff:127.0.0.1" clearsnapshot -t "$TAG"; then
    log "Cleared snapshot on $CONTAINER"
  else
    log "WARNING: Failed to clear snapshot on $CONTAINER"
    FAILURES=$((FAILURES + 1))
  fi
done

if [ "$FAILURES" -gt 0 ]; then
  # Don't prune after a failed run: sustained failures would otherwise age
  # out every remaining good backup exactly when the pipeline is broken.
  log "Skipping retention pruning because this run had failures"
  log "Backup finished with $FAILURES failure(s)"
  exit 1
fi

log "Pruning backups older than ${BACKUP_RETAIN_DAYS} days..."
find "$BACKUP_DIR" -maxdepth 1 \( -name '*.tar.gz' -o -name 'schema-*.cql' \) -mtime +"$BACKUP_RETAIN_DAYS" -print -exec rm -f {} \;

log "Backup complete: $TAG"
