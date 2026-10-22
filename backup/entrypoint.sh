#!/bin/sh

BACKUP_DAY="${BACKUP_DAY:-0}"    # day of week, 0 = Sunday (UTC)
BACKUP_HOUR="${BACKUP_HOUR:-12}" # hour of day (UTC)

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [backup-scheduler] $*"
}

log "Cassandra backup scheduler started (target: day ${BACKUP_DAY} at ${BACKUP_HOUR}:00 UTC)"

while true; do
  NOW_DOW=$(date -u +%w)
  NOW_SECS=$(( $(date -u +%-H) * 3600 + $(date -u +%-M) * 60 + $(date -u +%-S) ))

  DAY_DIFF=$(( (BACKUP_DAY - NOW_DOW + 7) % 7 ))
  SLEEP_SECS=$(( DAY_DIFF * 86400 + BACKUP_HOUR * 3600 - NOW_SECS ))
  if [ "$SLEEP_SECS" -le 0 ]; then
    # Target already passed this week, schedule for next week
    SLEEP_SECS=$(( SLEEP_SECS + 7 * 86400 ))
  fi

  log "Next backup in ${SLEEP_SECS}s ($(( SLEEP_SECS / 86400 ))d $(( (SLEEP_SECS % 86400) / 3600 ))h $(( (SLEEP_SECS % 3600) / 60 ))m)"
  sleep "$SLEEP_SECS"

  log "Starting scheduled backup..."
  if /backup/cassandra-backup.sh; then
    log "Scheduled backup completed successfully"
  else
    log "Scheduled backup finished with errors"
  fi
done
