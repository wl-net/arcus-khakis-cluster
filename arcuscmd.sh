#!/bin/bash
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Error: Do not run arcuscmd as root. Commands that need elevated privileges will use sudo."
  exit 1
fi

SCRIPT_PATH="$0"
SCRIPT_DIR=$(dirname "${SCRIPT_PATH}") # reserved for future use
export SCRIPT_DIR

if ! ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "Couldn't get root of git repository. You must checkout arcus-khakis-cluster as a git repository, not as an extracted zip."
  exit 1
fi

DOCKER_MIN_VERSION='27.0.0'
COMPOSE_MIN_VERSION='2.29.0'

DCS=("dc1" "dc2" "dc3")

# Detect container runtime and compose command
if command -v docker &>/dev/null; then
  RUNTIME=docker
  if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD=docker-compose
  elif docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
  else
    COMPOSE_CMD=""
  fi
elif command -v podman &>/dev/null; then
  RUNTIME=podman
  COMPOSE_CMD=podman-compose
else
  RUNTIME=""
  COMPOSE_CMD=""
fi

NODETOOL="/opt/cassandra/bin/nodetool"
# Max seconds to wait for a restarted node to serve again; raise for slow
# starts (commitlog replay, major version upgrades): NODE_TIMEOUT=1800 deploy
NODE_TIMEOUT="${NODE_TIMEOUT:-300}"
# Pause between Cassandra node restarts so hints drain and gossip settles
NODE_SETTLE="${NODE_SETTLE:-30}"

function print_available() {
  cat <<ENDOFDOC
arcuscmd: manage the arcus-khakis-cluster deployment

Setup:
  install             Install compose tool (docker-compose or podman-compose)

Status:
  status              Show Cassandra cluster status (nodetool status)
  check               Verify all containers are running and reachable

Deploy:
  update              Pull latest changes and show what changed
  apply               Bring up all services (docker-compose up -d)
  deploy [svc...]     Rolling deploy of changed services (Cassandra one node at a time);
                      unchanged services are skipped. Named services are always
                      recreated, without health checks. Runs a pre-flight health
                      check first and prompts if the cluster is unhealthy.
                        --pull   Pull images before restarting
                        --force  Skip the pre-flight health check

Operations:
  logs <svc>          Tail logs for a service
  shell <svc>         Open a shell on a service container
  dbshell             Open a Cassandra CQL shell
  nodetool <cmd>      Run a nodetool command on cassandra-0
                        -n <node>  Run on a specific node (e.g. -n cassandra-1)
                        --all      Run on all Cassandra nodes
  repair [keyspace]   Trigger a manual Cassandra repair (all keyspaces if none specified)
  upgradesstables     Upgrade SSTables on all Cassandra nodes
  snapshot [keyspace]  Take a Cassandra snapshot on all nodes
    snapshot --list    List existing snapshots
    snapshot --clear [name]  Clear snapshots (all, or by name)
    snapshot --export <name> [dest-dir]  Export a snapshot to tar.gz files
  backup [keyspace]   Snapshot + export in one step (saves to ./cassandra-backups/)

ENDOFDOC
}

function install_compose() {
  if [[ -z "$RUNTIME" ]]; then
    echo "Error: Neither docker nor podman found. Install a container runtime first."
    exit 1
  fi

  echo "Detected container runtime: $RUNTIME"

  if [[ "$RUNTIME" == "podman" ]]; then
    if command -v podman-compose &>/dev/null; then
      echo "podman-compose is already installed."
      return
    fi
    echo "Installing podman-compose..."
    sudo pip3 install podman-compose
    echo
    echo "Installed podman-compose $(podman-compose version 2>/dev/null || echo "")"
  else
    local current
    current=$($COMPOSE_CMD version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")

    if [[ -n "$current" ]] && version_gte "$current" "$COMPOSE_MIN_VERSION"; then
      echo "Docker Compose $current is installed and meets minimum $COMPOSE_MIN_VERSION."
      return
    fi

    if [[ -n "$current" ]]; then
      echo "Docker Compose $current is too old (minimum: $COMPOSE_MIN_VERSION)."
    else
      echo "Docker Compose is not installed."
    fi
    echo "Upgrade Docker to get a supported Compose version: https://docs.docker.com/engine/install/"
    exit 1
  fi
}

CACHE_DIR="$ROOT/.cache"

function detect_dc() {
  # All DCs share the same compose project name (arcus-khakis-cluster), so
  # 'compose ps -q' returns containers regardless of which DC's file is used.
  # Determine the actual DC by checking the running container's IP subnet.
  local container_id=""
  for dc in "${DCS[@]}"; do
    local dir="$ROOT/$dc/arcus-khakis-cluster"
    if [[ -f "$dir/docker-compose.yml" ]]; then
      # Probe zookeeper-0: it's the one service every DC runs (DC3 has no Cassandra)
      container_id=$($COMPOSE_CMD -f "$dir/docker-compose.yml" ps -q zookeeper-0 2>/dev/null | head -1)
      if [[ -n "$container_id" ]]; then
        break
      fi
    fi
  done

  if [[ -z "$container_id" ]]; then
    return
  fi

  local actual_ip
  actual_ip=$("$RUNTIME" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_id" 2>/dev/null)
  if [[ -z "$actual_ip" ]]; then
    return
  fi

  # Match IP against each DC's configured subnet
  for dc in "${DCS[@]}"; do
    local dir="$ROOT/$dc/arcus-khakis-cluster"
    if [[ -f "$dir/docker-compose.yml" ]]; then
      local subnet
      subnet=$(grep -oP 'subnet:\s*\K[\d.]+' "$dir/docker-compose.yml" | head -1)
      if [[ -n "$subnet" ]]; then
        local prefix="${subnet%.*}"
        if [[ "$actual_ip" == "$prefix".* ]]; then
          echo "$dc"
          return
        fi
      fi
    fi
  done
}

function find_compose_dir() {
  local verify="${1:-false}"

  # Use cached DC if available
  if [[ -f "$CACHE_DIR/dc" ]]; then
    local cached_dc
    cached_dc=$(cat "$CACHE_DIR/dc")
    local cached_dir="$ROOT/$cached_dc/arcus-khakis-cluster"
    if [[ -f "$cached_dir/docker-compose.yml" ]]; then
      # Verify cache is still valid if requested
      if [[ "$verify" == "true" ]]; then
        local detected
        detected=$(detect_dc)
        if [[ -n "$detected" && "$detected" != "$cached_dc" ]]; then
          echo "WARNING: Cached DC is $cached_dc but detected running containers for $detected" >&2
          read -r -p "Use $detected instead? [Y/n] " confirm
          if [[ ! "$confirm" =~ ^[Nn] ]]; then
            mkdir -p "$CACHE_DIR"
            echo "$detected" > "$CACHE_DIR/dc"
            echo "$ROOT/$detected/arcus-khakis-cluster"
            return
          fi
        fi
      fi
      echo "$cached_dir"
      return
    fi
  fi

  local detected
  detected=$(detect_dc)
  if [[ -n "$detected" ]]; then
    local dir="$ROOT/$detected/arcus-khakis-cluster"
    read -r -p "Detected $detected — proceed? [Y/n] " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
      echo "Aborted." >&2
      exit 1
    fi
    mkdir -p "$CACHE_DIR"
    echo "$detected" > "$CACHE_DIR/dc"
    echo "$dir"
    return
  fi

  echo "Error: Could not find a running DC on this host." >&2
  echo "Run from a host that has containers running, or specify the DC directory." >&2
  exit 1
}

function get_container_id() {
  local compose_dir="$1" service="$2"
  $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" ps -q "$service" 2>/dev/null | head -1 || true
}

function get_container_name() {
  local compose_dir="$1" service="$2"
  # || true: with no running container the empty-input xargs fails, and under
  # set -e/pipefail that would kill the caller instead of returning ""
  $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" ps -q "$service" 2>/dev/null | head -1 | xargs "$RUNTIME" inspect --format '{{.Name}}' 2>/dev/null | sed 's|^/||' || true
}

function get_container_ip() {
  local container="$1"
  "$RUNTIME" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container" 2>/dev/null || true
}

function get_cassandra_nodes() {
  local compose_dir="$1"
  $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" config --services 2>/dev/null | grep -E '^cassandra-[0-9]+$' | sort
}

function wait_for_node() {
  local container="$1" node_ip="$2"
  local elapsed=0

  local status_out info_out state reason=""
  echo "  Waiting for $container to rejoin cluster..."
  while [[ $elapsed -lt $NODE_TIMEOUT ]]; do
    # UN in its own gossip view is necessary but flips early; also require
    # the native transport to be up before calling the node ready, since
    # that's when it actually serves client queries again.
    # Capture nodetool output before grepping: grep -q on a live pipe closes
    # it early, docker exec dies with SIGPIPE, and pipefail turns a
    # successful match into a failed check.
    if ! status_out=$("$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" status 2>/dev/null); then
      reason="nodetool not responding yet"
    else
      state=$(echo "$status_out" | grep "$node_ip" | awk '{print $1}' || true)
      info_out=$("$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" info 2>/dev/null || true)
      if [[ "$state" != "UN" ]]; then
        reason="node state is ${state:-not in ring}, want UN"
      elif ! echo "$info_out" | grep -q "Native Transport active: true"; then
        reason="native transport not active yet"
      else
        echo "  Node $container is UN with native transport active after ${elapsed}s"
        return 0
      fi
    fi
    if [[ $elapsed -gt 0 && $((elapsed % 60)) -eq 0 ]]; then
      echo "  Still waiting (${elapsed}s): $reason"
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done

  echo "  WARNING: Node $container not ready within ${NODE_TIMEOUT}s (last: $reason)"
  return 1
}

function wait_for_running() {
  local compose_dir="$1" svc="$2"
  local elapsed=0 container status

  echo "  Waiting for $svc to be running..."
  while [[ $elapsed -lt 60 ]]; do
    sleep 5
    elapsed=$((elapsed + 5))
    container=$(get_container_name "$compose_dir" "$svc")
    [[ -z "$container" ]] && continue
    status=$("$RUNTIME" inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
    # Require a second consecutive running check so a crash-looping
    # container isn't caught in a transient 'running' state
    if [[ "$status" == "running" && $elapsed -ge 10 ]]; then
      echo "  $svc is running after ${elapsed}s"
      return 0
    fi
  done

  echo "  WARNING: $svc is not running after 60s (status: ${status:-not found})"
  return 1
}

function apply() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir true)
  echo "Applying configuration from: $compose_dir"

  $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" up -d
  echo
  echo "All services started."
}

function preflight_ring() {
  # Scan the whole ring (all DCs) from a local node: a DN node anywhere
  # means a rolling restart here could drop quorum.
  local compose_dir="$1"
  local node container bad
  node=$(get_cassandra_nodes "$compose_dir" | head -1)
  [[ -z "$node" ]] && return 0
  container=$(get_container_name "$compose_dir" "$node")
  [[ -z "$container" ]] && return 0  # nothing running yet, nothing to protect
  bad=$("$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" status 2>/dev/null | grep -E '^[UD][NLJM] ' | grep -v '^UN ' || true)
  if [[ -n "$bad" ]]; then
    echo "WARNING: Cassandra ring has nodes that are not UN:"
    echo "$bad"
    return 1
  fi
}

function deploy() {
  local pull=false
  local force=false
  local services=()

  for arg in "$@"; do
    if [[ "$arg" == "--pull" ]]; then
      pull=true
    elif [[ "$arg" == "--force" ]]; then
      force=true
    else
      services+=("$arg")
    fi
  done

  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)
  echo "Using compose directory: $compose_dir"

  # If specific services given, just restart them without health checks
  if [[ ${#services[@]} -gt 0 ]]; then
    for svc in "${services[@]}"; do
      echo "Deploying $svc..."
      if [[ "$pull" == true ]]; then
        $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" pull "$svc" || true
      fi
      $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" up -d --no-deps --force-recreate "$svc"
    done
    return
  fi

  # Pre-flight: don't start a rolling deploy on an unhealthy cluster
  # without the operator confirming. --force skips the check (e.g. when
  # deploying precisely to fix the unhealthy service).
  if [[ "$force" != true ]]; then
    echo "Running pre-flight health check..."
    local healthy=true
    check || healthy=false
    preflight_ring "$compose_dir" || healthy=false
    if [[ "$healthy" != true ]]; then
      echo
      read -r -p "Cluster is not fully healthy. Deploy anyway? [y/N] " confirm
      if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo "Aborted. (--force skips the pre-flight check)"
        exit 1
      fi
    fi
    echo
  fi

  # Default: rolling deploy of all services. Cassandra nodes go first, one
  # at a time with UN checks; every other service follows one at a time.
  local cassandra_nodes other_services
  cassandra_nodes=$(get_cassandra_nodes "$compose_dir")
  other_services=$($COMPOSE_CMD -f "$compose_dir/docker-compose.yml" config --services 2>/dev/null | grep -vE '^cassandra-[0-9]+$')

  echo "Starting rolling deploy of all services..."
  if [[ "$pull" == true ]]; then
    echo "Pulling images..."
    $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" pull
  fi

  # Recreate only services whose image or config changed ('up -d' detects
  # this); unchanged services are left alone so deploy is idempotent.
  local before after
  for node in $cassandra_nodes; do
    echo
    echo "--- Deploying $node ---"

    before=$(get_container_id "$compose_dir" "$node")
    $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" up -d --no-deps "$node"
    after=$(get_container_id "$compose_dir" "$node")

    if [[ -n "$before" && "$before" == "$after" ]]; then
      echo "--- $node unchanged, skipping ---"
      continue
    fi

    # Treat "can't verify" as failure: continuing past an unverifiable node
    # would keep bouncing the remaining nodes with a potentially broken
    # image and could take the whole DC down.
    local container
    container=$(get_container_name "$compose_dir" "$node")
    if [[ -z "$container" ]]; then
      echo "  ERROR: Could not find container for $node (crashed on start?)."
      echo "  Aborting deploy. Fix $node before continuing."
      exit 1
    fi

    local ip
    ip=$(get_container_ip "$container")
    if [[ -z "$ip" ]]; then
      echo "  ERROR: Could not determine IP for $container (not running?)."
      echo "  Aborting deploy. Fix $node before continuing."
      exit 1
    fi

    if ! wait_for_node "$container" "$ip"; then
      echo "  Aborting deploy. Fix $node before continuing."
      exit 1
    fi

    echo "  Letting the cluster settle for ${NODE_SETTLE}s..."
    sleep "$NODE_SETTLE"

    echo "--- $node deployed successfully ---"
  done

  for svc in $other_services; do
    echo
    echo "--- Deploying $svc ---"

    before=$(get_container_id "$compose_dir" "$svc")
    $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" up -d --no-deps "$svc"
    after=$(get_container_id "$compose_dir" "$svc")

    if [[ -n "$before" && "$before" == "$after" ]]; then
      echo "--- $svc unchanged, skipping ---"
      continue
    fi

    if ! wait_for_running "$compose_dir" "$svc"; then
      echo "  Aborting deploy. Fix $svc before continuing."
      exit 1
    fi

    echo "--- $svc deployed successfully ---"
  done

  echo
  echo "All services deployed successfully."
  echo "Run './arcuscmd.sh check' to verify service health."
}

function check() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)

  local failed=0

  # Get all services defined in the compose file
  local services
  services=$($COMPOSE_CMD -f "$compose_dir/docker-compose.yml" config --services 2>/dev/null)

  for svc in $services; do
    local container
    container=$(get_container_name "$compose_dir" "$svc")
    if [[ -z "$container" ]]; then
      echo "DOWN  $svc (not running)"
      failed=$((failed + 1))
      continue
    fi

    local status
    status=$("$RUNTIME" inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)
    if [[ "$status" != "running" ]]; then
      echo "DOWN  $svc ($status)"
      failed=$((failed + 1))
      continue
    fi

    local ip
    ip=$(get_container_ip "$container")

    # Service-specific reachability checks
    case "$svc" in
      cassandra-repair|cassandra-backup)
        echo "OK    $svc running"
        ;;
      cassandra-*)
        if "$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" status &>/dev/null; then
          local node_status
          node_status=$("$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" status 2>/dev/null | grep "$ip" | awk '{print $1}' || true)
          echo "OK    $svc ($ip) cassandra=${node_status:-unknown}"
        else
          echo "WARN  $svc ($ip) running but nodetool unreachable"
          failed=$((failed + 1))
        fi
        ;;
      zookeeper-*)
        local zk_mode
        zk_mode=$("$RUNTIME" exec "$container" zkServer.sh status 2>&1 | grep "Mode:" | awk '{print $2}' || true)
        if [[ -n "$zk_mode" ]]; then
          echo "OK    $svc ($ip) zookeeper=$zk_mode"
        else
          echo "WARN  $svc ($ip) running but zookeeper not responding"
          failed=$((failed + 1))
        fi
        ;;
      kafka-*)
        echo "OK    $svc ($ip) running"
        ;;
      *)
        echo "OK    $svc ($ip) running"
        ;;
    esac
  done

  echo
  if [[ $failed -gt 0 ]]; then
    echo "$failed service(s) with issues."
    return 1
  else
    echo "All services healthy."
  fi
}

function version_gte() {
  # Returns 0 (true) if $1 >= $2
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

function check_versions() {
  if [[ "$RUNTIME" != "docker" ]]; then
    return
  fi

  local docker_version
  docker_version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
  if [[ -n "$docker_version" ]] && ! version_gte "$docker_version" "$DOCKER_MIN_VERSION"; then
    echo "Error: Docker $docker_version is too old (minimum: $DOCKER_MIN_VERSION)."
    echo "Upgrade Docker: https://docs.docker.com/engine/install/"
    exit 1
  fi

  local compose_version
  compose_version=$($COMPOSE_CMD version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
  if [[ -n "$compose_version" ]] && ! version_gte "$compose_version" "$COMPOSE_MIN_VERSION"; then
    echo "Error: Docker Compose $compose_version is too old (minimum: $COMPOSE_MIN_VERSION)."
    if [[ "$compose_version" == 1.* ]]; then
      echo "Docker Compose V1 is no longer supported. Upgrade Docker to get Compose V2."
    else
      echo "Upgrade: https://docs.docker.com/compose/install/"
    fi
    exit 1
  fi
}

function require_compose() {
  if [[ -z "$COMPOSE_CMD" ]]; then
    echo "Error: No compose tool found. Run './arcuscmd.sh install' first."
    exit 1
  fi
  check_versions
}

function status() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)

  local container
  container=$(get_container_name "$compose_dir" "cassandra-0")
  if [[ -z "$container" ]]; then
    echo "Error: cassandra-0 is not running."
    exit 1
  fi

  "$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" status
}

function logs() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)

  if [[ $# -eq 0 ]]; then
    echo "Usage: arcuscmd logs <service>"
    echo
    echo "Services:"
    $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" config --services 2>/dev/null
    exit 1
  fi

  $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" logs -f "$@"
}

function shell_exec() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)

  if [[ $# -eq 0 ]]; then
    echo "Usage: arcuscmd shell <service>"
    echo
    echo "Services:"
    $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" config --services 2>/dev/null
    exit 1
  fi

  local svc="$1"
  shift
  local container
  container=$(get_container_name "$compose_dir" "$svc")
  if [[ -z "$container" ]]; then
    echo "Error: $svc is not running."
    exit 1
  fi

  if [[ $# -gt 0 ]]; then
    "$RUNTIME" exec -it "$container" "$@"
  else
    "$RUNTIME" exec -it "$container" sh
  fi
}

function dbshell() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)

  local container
  container=$(get_container_name "$compose_dir" "cassandra-0")
  if [[ -z "$container" ]]; then
    echo "Error: cassandra-0 is not running."
    exit 1
  fi

  local ip
  ip=$(get_container_ip "$container")
  "$RUNTIME" exec -it "$container" /opt/cassandra/bin/cqlsh "$ip"
}

function run_nodetool() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)

  local all=false
  local target="cassandra-0"
  local args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        all=true
        shift
        ;;
      -n)
        target="$2"
        shift 2
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#args[@]} -eq 0 ]]; then
    echo "Usage: arcuscmd nodetool [--all | -n <node>] <command> [args...]"
    exit 1
  fi

  local nodes
  if [[ "$all" == true ]]; then
    nodes=$(get_cassandra_nodes "$compose_dir")
    if [[ -z "$nodes" ]]; then
      echo "No Cassandra nodes found in compose file."
      return
    fi
  else
    nodes="$target"
  fi

  for node in $nodes; do
    local container
    container=$(get_container_name "$compose_dir" "$node")
    if [[ -z "$container" ]]; then
      echo "Error: $node is not running."
      [[ "$all" == true ]] && continue || exit 1
    fi

    if [[ "$all" == true ]]; then
      echo "--- $node ---"
    fi
    "$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" "${args[@]}"
    if [[ "$all" == true ]]; then
      echo
    fi
  done
}

function upgradesstables() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)

  local cassandra_nodes
  cassandra_nodes=$(get_cassandra_nodes "$compose_dir")
  if [[ -z "$cassandra_nodes" ]]; then
    echo "No Cassandra nodes found in compose file."
    return
  fi

  echo "Running upgradesstables on all Cassandra nodes..."
  for node in $cassandra_nodes; do
    local container
    container=$(get_container_name "$compose_dir" "$node")
    if [[ -z "$container" ]]; then
      echo "SKIP  $node (not running)"
      continue
    fi

    echo
    echo "--- $node ---"
    "$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" upgradesstables "$@"
    echo "--- $node done ---"
  done

  echo
  echo "upgradesstables complete."
}

function repair() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)

  local container
  container=$(get_container_name "$compose_dir" "cassandra-repair")
  if [[ -z "$container" ]]; then
    echo "Error: cassandra-repair is not running."
    echo "Start it with: $COMPOSE_CMD -f $compose_dir/docker-compose.yml up -d cassandra-repair"
    exit 1
  fi

  if [[ $# -gt 0 ]]; then
    echo "Starting manual Cassandra repair for keyspace(s): $*"
  else
    echo "Starting manual Cassandra repair (all keyspaces)..."
  fi
  "$RUNTIME" exec "$container" /repair/cassandra-repair.sh "$@"
}

function update() {
  cd "$ROOT"

  local before after
  before=$(git rev-parse HEAD)

  if ! git pull --ff-only; then
    echo "Error: git pull failed. Resolve any conflicts and try again."
    exit 1
  fi

  after=$(git rev-parse HEAD)

  if [[ "$before" == "$after" ]]; then
    echo "Already up to date."
  else
    echo
    echo "Updated $before -> $after"
    echo
    git --no-pager log --oneline "${before}..${after}"
    echo
    echo "Changed files:"
    git --no-pager diff --stat "${before}..${after}"
  fi
}

function snapshot_take() {
  local compose_dir="$1"
  shift
  local tag="$1"
  shift

  local ks_args=()
  if [[ $# -gt 0 ]]; then
    echo "Taking snapshot '$tag' of keyspace(s): $*"
    ks_args=("--" "$@")
  else
    echo "Taking snapshot '$tag' of all keyspaces..."
  fi

  for node in $(get_cassandra_nodes "$compose_dir"); do
    local container
    container=$(get_container_name "$compose_dir" "$node")
    if [[ -z "$container" ]]; then
      echo "SKIP  $node (not running)"
      continue
    fi
    echo "  $node: taking snapshot..."
    "$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" snapshot -t "$tag" "${ks_args[@]}"
  done

  echo
  echo "Snapshot '$tag' created on all nodes."
}

function snapshot_list() {
  local compose_dir="$1"

  for node in $(get_cassandra_nodes "$compose_dir"); do
    local container
    container=$(get_container_name "$compose_dir" "$node")
    if [[ -z "$container" ]]; then
      echo "SKIP  $node (not running)"
      continue
    fi
    echo "--- $node ---"
    "$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" listsnapshots
    echo
  done
}

function snapshot_clear() {
  local compose_dir="$1"
  local name="${2:-}"

  local clear_args=()
  if [[ -n "$name" ]]; then
    clear_args+=("-t" "$name")
    echo "Clearing snapshot '$name' on all nodes..."
  else
    clear_args+=("--all")
    echo "Clearing all snapshots on all nodes..."
  fi

  for node in $(get_cassandra_nodes "$compose_dir"); do
    local container
    container=$(get_container_name "$compose_dir" "$node")
    if [[ -z "$container" ]]; then
      echo "SKIP  $node (not running)"
      continue
    fi
    echo "  $node: clearing snapshots..."
    "$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" clearsnapshot "${clear_args[@]}"
  done
  echo "Done."
}

function snapshot_export() {
  local compose_dir="$1"
  local name="$2"
  local dest_dir="${3:-./cassandra-backups}"

  mkdir -p "$dest_dir"
  echo "Exporting snapshot '$name' to $dest_dir/"

  for node in $(get_cassandra_nodes "$compose_dir"); do
    local container
    container=$(get_container_name "$compose_dir" "$node")
    if [[ -z "$container" ]]; then
      echo "SKIP  $node (not running)"
      continue
    fi

    local outfile="$dest_dir/${node}-${name}.tar.gz"
    echo "  $node: finding snapshot files..."

    # Find all snapshot dirs matching the tag and tar them from inside the container
    if ! "$RUNTIME" exec "$container" sh -c "find /data/data -path '*/snapshots/$name' -type d" | grep -q .; then
      echo "  SKIP  $node: no snapshot '$name' found"
      continue
    fi

    echo "  $node: exporting to $outfile..."
    "$RUNTIME" exec "$container" sh -c "cd /data && find data -path '*/snapshots/$name' -type d -exec find {} -type f \; | tar czf - -T -" > "$outfile"
    local size
    size=$(du -h "$outfile" | cut -f1)
    echo "  $node: exported ($size)"
  done

  echo
  echo "Export complete. Files in $dest_dir/"
  ls -lh "$dest_dir/"*-"${name}.tar.gz" 2>/dev/null
}

function snapshot() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)

  case "${1:-}" in
    --list)
      snapshot_list "$compose_dir"
      ;;
    --clear)
      snapshot_clear "$compose_dir" "${2:-}"
      ;;
    --export)
      if [[ -z "${2:-}" ]]; then
        echo "Usage: snapshot --export <snapshot-name> [dest-dir]"
        exit 1
      fi
      snapshot_export "$compose_dir" "$2" "${3:-}"
      ;;
    *)
      local tag
      tag="backup-$(date +%Y%m%d-%H%M%S)"
      snapshot_take "$compose_dir" "$tag" "$@"
      echo "To export: ./arcuscmd.sh snapshot --export $tag [dest-dir]"
      echo "To clear:  ./arcuscmd.sh snapshot --clear $tag"
      ;;
  esac
}

function backup() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)

  local tag
  tag="backup-$(date +%Y%m%d-%H%M%S)"
  local dest_dir="./cassandra-backups"

  snapshot_take "$compose_dir" "$tag" "$@"
  snapshot_export "$compose_dir" "$tag" "$dest_dir"
  snapshot_clear "$compose_dir" "$tag"
}

subcmd=${1:-help}

case "$subcmd" in
install)
  install_compose
  ;;
status)
  status
  ;;
check)
  check
  ;;
apply)
  apply
  ;;
deploy)
  deploy "${@:2}"
  ;;
update)
  update
  ;;
logs)
  logs "${@:2}"
  ;;
shell)
  shell_exec "${@:2}"
  ;;
dbshell)
  dbshell
  ;;
nodetool)
  run_nodetool "${@:2}"
  ;;
repair)
  repair "${@:2}"
  ;;
upgradesstables)
  upgradesstables "${@:2}"
  ;;
snapshot)
  snapshot "${@:2}"
  ;;
backup)
  backup "${@:2}"
  ;;
help)
  print_available
  ;;
*)
  echo "Unsupported Command: $subcmd"
  echo
  print_available
  exit 1
  ;;
esac
