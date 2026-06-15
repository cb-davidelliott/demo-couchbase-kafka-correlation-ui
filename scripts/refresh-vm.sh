#!/usr/bin/env bash
# ==============================================================================
# Refresh VM Script
# Fast inner-loop helper for updating an already-deployed VM without recreating it.
# Run this from the VM at /opt/couchbase-capella-kafka-demo.
# ==============================================================================

set -euo pipefail

TARGET="${1:-all}"
BRANCH="${2:-main}"
APP_DIR="${APP_DIR:-/opt/couchbase-capella-kafka-demo}"
COMPOSE_FILE="${COMPOSE_FILE:-app/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-.env}"

usage() {
    cat <<'EOF'
Usage:
  sudo ./scripts/refresh-vm.sh [target] [branch]

Targets:
  all        Pull code, rebuild/recreate all services, update connector config.
  generator  Pull code, rebuild/recreate only event-generator.
  ui         Pull code, rebuild/recreate only demo-ui.
  connect    Pull code, rebuild/recreate kafka-connect, update connector config.
  otel       Pull code, rebuild/recreate otel-demo and otel-collector.
  pull       Pull code only.
  status     Show compose and connector status only.

Examples:
  sudo ./scripts/refresh-vm.sh generator
  sudo ./scripts/refresh-vm.sh ui
  sudo ./scripts/refresh-vm.sh connect
  sudo ./scripts/refresh-vm.sh all main
EOF
}

log() {
    echo "[INFO] $*"
}

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

run_compose() {
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

refresh_service_only() {
    local service="$1"

    log "Building $service image..."
    run_compose build "$service"

    log "Recreating $service without touching dependent services..."
    run_compose up -d --no-deps --force-recreate "$service"
}

pull_latest() {
    log "Refreshing repository from origin/$BRANCH..."
    git fetch origin "$BRANCH"
    git checkout "$BRANCH"
    git pull --ff-only origin "$BRANCH"
}

connector_status() {
    if curl -s -f http://localhost:8083/ > /dev/null 2>&1; then
        curl -s http://localhost:8083/connectors/couchbase-sink-connector/status | jq . || true
    else
        echo "[WARN] Kafka Connect API is not reachable yet."
    fi
}

print_status() {
    log "Docker Compose service status:"
    run_compose ps

    log "Connector status:"
    connector_status
}

cd "$APP_DIR" || fail "App directory not found: $APP_DIR"

if [ ! -f "$ENV_FILE" ]; then
    fail "Environment file not found: $APP_DIR/$ENV_FILE"
fi

case "$TARGET" in
    all)
        pull_latest
        log "Rebuilding and recreating all services..."
        run_compose up -d --build
        log "Updating Couchbase connector configuration..."
        ./scripts/setup-connectors.sh
        print_status
        ;;
    generator|event-generator)
        pull_latest
        refresh_service_only event-generator
        print_status
        ;;
    generator-env)
        log "Generator environment from $APP_DIR/$ENV_FILE:"
        grep -E '^GENERATOR_' "$ENV_FILE" | sort || true
        ;;
    ui|demo-ui)
        pull_latest
        refresh_service_only demo-ui
        print_status
        ;;
    connect|connector|kafka-connect)
        pull_latest
        refresh_service_only kafka-connect
        log "Updating Couchbase connector configuration..."
        ./scripts/setup-connectors.sh
        print_status
        ;;
    otel)
        pull_latest
        log "Rebuilding and recreating OTel services..."
        run_compose up -d --build --force-recreate otel-collector otel-demo
        print_status
        ;;
    pull)
        pull_latest
        ;;
    status)
        print_status
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        fail "Unknown target: $TARGET"
        ;;
esac
