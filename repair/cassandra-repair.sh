#!/bin/sh

# Max seconds for one keyspace repair on one node before giving up, so a
# hung repair can't wedge the daily schedule.
REPAIR_TIMEOUT="${REPAIR_TIMEOUT:-7200}"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [repair] $*"
}

# Find local Cassandra containers by compose service label
CONTAINERS=$(docker ps --filter "label=com.docker.compose.service" --format '{{.Names}}' | grep -E 'cassandra-[0-9]+' | sort)

if [ -z "$CONTAINERS" ]; then
  log "ERROR: No running Cassandra containers found"
  exit 1
fi

log "Found Cassandra containers: $(echo "$CONTAINERS" | tr '\n' ' ')"

# Use provided keyspaces or discover non-system ones
if [ $# -gt 0 ]; then
  KEYSPACES="$*"
else
  FIRST_NODE=$(echo "$CONTAINERS" | head -n1)
  FIRST_NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$FIRST_NODE")
  log "Discovering keyspaces from $FIRST_NODE ($FIRST_NODE_IP)..."

  KEYSPACES=$(docker exec "$FIRST_NODE" /opt/cassandra/bin/cqlsh "$FIRST_NODE_IP" -e "DESCRIBE KEYSPACES" 2>/dev/null | tr -s ' \n' '\n' | grep -v -E '^(system|system_auth|system_distributed|system_schema|system_traces|system_views|system_virtual_schema)$' | grep -v '^$' | sort)

  if [ -z "$KEYSPACES" ]; then
    log "ERROR: No non-system keyspaces found"
    exit 1
  fi
fi

log "Keyspaces to repair: $(echo "$KEYSPACES" | tr '\n' ' ')"

# Repair each node sequentially
FAILURES=0
for CONTAINER in $CONTAINERS; do
  log "--- Starting repairs on $CONTAINER ---"

  for KS in $KEYSPACES; do
    log "Repairing keyspace '$KS' on $CONTAINER..."
    if timeout "$REPAIR_TIMEOUT" docker exec "$CONTAINER" /opt/cassandra/bin/nodetool -h "::ffff:127.0.0.1" repair "$KS" -pr; then
      log "Completed repair of '$KS' on $CONTAINER"
    else
      RC=$?
      if [ "$RC" -eq 124 ]; then
        log "WARNING: Repair of '$KS' on $CONTAINER timed out after ${REPAIR_TIMEOUT}s, continuing..."
      else
        log "WARNING: Repair of '$KS' on $CONTAINER failed (exit code $RC), continuing..."
      fi
      FAILURES=$((FAILURES + 1))
    fi
  done

  log "--- Finished repairs on $CONTAINER ---"
done

if [ "$FAILURES" -gt 0 ]; then
  log "Repairs finished with $FAILURES failure(s)"
  exit 1
fi

log "All repairs complete"
