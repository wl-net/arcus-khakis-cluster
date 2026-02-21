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

DOCKER_COMPOSE_VERSION='1.27.4'

DCS=("dc1" "dc2" "dc3")

# Detect container runtime
if command -v docker &>/dev/null; then
  RUNTIME=docker
  COMPOSE_CMD=docker-compose
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
  check               Verify all containers are running and reachable

Deploy:
  update              Pull latest changes and show what changed
  deploy [svc...]     Rolling deploy of services (default: all Cassandra nodes)
                        --pull  Pull images before restarting

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
    if command -v docker-compose &>/dev/null; then
      local current
      current=$(docker-compose version --short 2>/dev/null || echo "unknown")
      echo "docker-compose is already installed (version $current)"
      if [[ "$current" == "$DOCKER_COMPOSE_VERSION" ]]; then
        echo "Already at target version $DOCKER_COMPOSE_VERSION, nothing to do."
        return
      fi
      echo "Upgrading to $DOCKER_COMPOSE_VERSION..."
    else
      echo "Installing docker-compose $DOCKER_COMPOSE_VERSION..."
    fi

    sudo pip3 install "docker-compose==$DOCKER_COMPOSE_VERSION"
    echo
    echo "Installed docker-compose $(docker-compose version --short)"
  fi
}

function find_compose_dir() {
  for dc in "${DCS[@]}"; do
    local dir="$ROOT/$dc/arcus-khakis-cluster"
    if [[ -f "$dir/docker-compose.yml" ]]; then
      # Check if any container from this DC's compose is running locally
      if $COMPOSE_CMD -f "$dir/docker-compose.yml" ps -q 2>/dev/null | head -1 | grep -q .; then
        read -r -p "Detected $dc — proceed? [Y/n] " confirm
        if [[ "$confirm" =~ ^[Nn] ]]; then
          echo "Aborted." >&2
          exit 1
        fi
        echo "$dir"
        return
      fi
    fi
  done
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

  if [[ -z "$COMPOSE_CMD" ]]; then
    echo "Error: No compose tool found. Run './arcuscmd.sh install' first."
    exit 1
  fi

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
  if [[ -z "$COMPOSE_CMD" ]]; then
    echo "Error: No compose tool found. Run './arcuscmd.sh install' first."
    exit 1
  fi

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
        if echo ruok | "$RUNTIME" exec -i "$container" nc localhost 2181 2>/dev/null | grep -q imok; then
          echo "OK    $svc ($ip) zookeeper=imok"
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
check)
  check
  ;;
deploy)
  deploy "${@:2}"
  ;;
update)
  update
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
