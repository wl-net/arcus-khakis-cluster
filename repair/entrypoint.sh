#!/bin/sh

REPAIR_HOUR="${REPAIR_HOUR:-2}"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [scheduler] $*"
}

log "Cassandra repair scheduler started (target hour: ${REPAIR_HOUR}:00 UTC)"

while true; do
  CURRENT_HOUR=$(date -u +%H | sed 's/^0//')
  CURRENT_MIN=$(date -u +%M | sed 's/^0//')
  CURRENT_SEC=$(date -u +%S | sed 's/^0//')

  # Seconds since midnight
  NOW_SECS=$(( CURRENT_HOUR * 3600 + CURRENT_MIN * 60 + CURRENT_SEC ))
  TARGET_SECS=$(( REPAIR_HOUR * 3600 ))

  if [ "$NOW_SECS" -lt "$TARGET_SECS" ]; then
    SLEEP_SECS=$(( TARGET_SECS - NOW_SECS ))
  else
    # Target already passed today, schedule for tomorrow
    SLEEP_SECS=$(( 86400 - NOW_SECS + TARGET_SECS ))
  fi

  log "Next repair in ${SLEEP_SECS}s ($(( SLEEP_SECS / 3600 ))h $(( (SLEEP_SECS % 3600) / 60 ))m)"
  sleep "$SLEEP_SECS"

  log "Starting scheduled repair..."
  if /repair/cassandra-repair.sh; then
    log "Scheduled repair completed successfully"
  else
    log "Scheduled repair finished with errors"
  fi
done
