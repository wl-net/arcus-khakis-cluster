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

CASSANDRA_NODES=("cassandra-0" "cassandra-1" "cassandra-2")
NODETOOL="/opt/cassandra/bin/nodetool"
NODE_TIMEOUT=300

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
  deploy [svc...]     Rolling deploy of services (default: all Cassandra nodes)
                        --pull  Pull images before restarting

Operations:
  logs <svc>          Tail logs for a service
  shell <svc>         Open a shell on a service container
  dbshell             Open a Cassandra CQL shell
  repair [keyspace]   Trigger a manual Cassandra repair (all keyspaces if none specified)
  upgradesstables     Upgrade SSTables on all Cassandra nodes

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
      container_id=$($COMPOSE_CMD -f "$dir/docker-compose.yml" ps -q cassandra-0 2>/dev/null | head -1)
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

function get_container_name() {
  local compose_dir="$1" service="$2"
  $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" ps -q "$service" 2>/dev/null | head -1 | xargs "$RUNTIME" inspect --format '{{.Name}}' 2>/dev/null | sed 's|^/||'
}

function get_container_ip() {
  local container="$1"
  "$RUNTIME" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container"
}

function wait_for_node() {
  local container="$1" node_ip="$2"
  local elapsed=0

  echo "  Waiting for $container to rejoin cluster..."
  while [[ $elapsed -lt $NODE_TIMEOUT ]]; do
    if "$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" status 2>/dev/null | grep "$node_ip" | grep -q "^UN"; then
      echo "  Node $container is UN (Up/Normal) after ${elapsed}s"
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done

  echo "  WARNING: Node $container did not reach UN status within ${NODE_TIMEOUT}s"
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

function deploy() {
  local pull=false
  local services=()

  for arg in "$@"; do
    if [[ "$arg" == "--pull" ]]; then
      pull=true
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
      $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" up -d --no-deps "$svc"
    done
    return
  fi

  # Default: rolling deploy of Cassandra nodes
  echo "Starting rolling Cassandra deploy..."
  if [[ "$pull" == true ]]; then
    echo "Pulling Cassandra image..."
    $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" pull cassandra-0
  fi

  for node in "${CASSANDRA_NODES[@]}"; do
    echo
    echo "--- Deploying $node ---"

    $COMPOSE_CMD -f "$compose_dir/docker-compose.yml" up -d --no-deps "$node"

    local container
    container=$(get_container_name "$compose_dir" "$node")
    if [[ -z "$container" ]]; then
      echo "  WARNING: Could not find container for $node, skipping health check"
      continue
    fi

    local ip
    ip=$(get_container_ip "$container")
    if [[ -z "$ip" ]]; then
      echo "  WARNING: Could not determine IP for $container, skipping health check"
      continue
    fi

    if ! wait_for_node "$container" "$ip"; then
      echo "  Aborting deploy. Fix $node before continuing."
      exit 1
    fi

    echo "--- $node deployed successfully ---"
  done

  echo
  echo "All Cassandra nodes deployed successfully."
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
    status=$("$RUNTIME" inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
    if [[ "$status" != "running" ]]; then
      echo "DOWN  $svc ($status)"
      failed=$((failed + 1))
      continue
    fi

    local ip
    ip=$(get_container_ip "$container")

    # Service-specific reachability checks
    case "$svc" in
      cassandra-repair)
        echo "OK    $svc running"
        ;;
      cassandra-*)
        if "$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" status &>/dev/null; then
          local node_status
          node_status=$("$RUNTIME" exec "$container" "$NODETOOL" -h "::ffff:127.0.0.1" status 2>/dev/null | grep "$ip" | awk '{print $1}')
          echo "OK    $svc ($ip) cassandra=$node_status"
        else
          echo "WARN  $svc ($ip) running but nodetool unreachable"
          failed=$((failed + 1))
        fi
        ;;
      zookeeper-*)
        local zk_mode
        zk_mode=$("$RUNTIME" exec "$container" zkServer.sh status 2>&1 | grep "Mode:" | awk '{print $2}')
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

function upgradesstables() {
  require_compose
  local compose_dir
  compose_dir=$(find_compose_dir)

  echo "Running upgradesstables on all Cassandra nodes..."
  for node in "${CASSANDRA_NODES[@]}"; do
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
repair)
  repair "${@:2}"
  ;;
upgradesstables)
  upgradesstables "${@:2}"
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
