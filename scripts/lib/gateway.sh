# scripts/lib/gateway.sh — gateway-64 compose stack lifecycle.
#
# Gateway profiles use a multi-container compose stack (reverse proxy +
# backend + optional shared postgres), not the standard single-container
# framework image. Compose file lives at frameworks/<fw>/compose.gateway.yml.

GATEWAY_PROJECT=""
GATEWAY_CONTAINERS=""
GATEWAY_CONTAINER_COUNT=0

_gateway_env() {
    # All compose invocations need the same env vars for interpolation.
    CERTS_DIR="$CERTS_DIR" \
    DATA_DIR="$DATA_DIR" \
    DATABASE_URL="$DATABASE_URL" \
    "$@"
}

gateway_up() {
    local framework="$1"
    local compose_file="$ROOT_DIR/frameworks/$framework/compose.gateway.yml"
    GATEWAY_PROJECT="httparena-$framework"

    [ -f "$compose_file" ] || fail "compose.gateway.yml not found for $framework"

    _gateway_env docker compose -f "$compose_file" -p "$GATEWAY_PROJECT" \
        down --remove-orphans 2>/dev/null || true

    info "starting gateway compose stack: $framework"
    # --build forces compose to rebuild from source if any file in the
    # build context changed. Without this, an edit to a service Dockerfile
    # or Program.cs silently falls back to a stale image from the last run.
    _gateway_env docker compose -f "$compose_file" -p "$GATEWAY_PROJECT" up --build -d \
        || fail "gateway compose up failed"

    # Discover running container IDs for stats collection.
    sleep 2
    GATEWAY_CONTAINERS=$(docker ps -q --filter "label=com.docker.compose.project=$GATEWAY_PROJECT" 2>/dev/null | tr '\n' ' ')
    GATEWAY_CONTAINER_COUNT=$(echo "$GATEWAY_CONTAINERS" | wc -w)
    info "gateway containers: $GATEWAY_CONTAINER_COUNT ($GATEWAY_CONTAINERS)"

    if [ "$GATEWAY_CONTAINER_COUNT" -ne 2 ]; then
        warn "gateway-64 expects exactly 2 containers (proxy + server), found $GATEWAY_CONTAINER_COUNT — stats may not sum correctly"
    fi
}

gateway_down() {
    local framework="$1"
    local compose_file="$ROOT_DIR/frameworks/$framework/compose.gateway.yml"
    [ -f "$compose_file" ] || return 0
    _gateway_env docker compose -f "$compose_file" -p "httparena-$framework" \
        down --remove-orphans 2>/dev/null || true
    GATEWAY_PROJECT=""
    GATEWAY_CONTAINERS=""
    GATEWAY_CONTAINER_COUNT=0
}

gateway_service_names() {
    local framework="$1"
    local compose_file="$ROOT_DIR/frameworks/$framework/compose.gateway.yml"
    _gateway_env docker compose -f "$compose_file" -p "httparena-$framework" \
        ps --services 2>/dev/null
}
