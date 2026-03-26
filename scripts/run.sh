#!/usr/bin/env bash
set -euo pipefail

# Run a framework's Docker container interactively for manual testing.
# Usage: ./scripts/run.sh <framework>
# Press Ctrl+C to stop.

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <framework>"
    echo "Example: $0 express"
    exit 1
fi

FRAMEWORK="$1"
IMAGE_NAME="httparena-${FRAMEWORK}"
CONTAINER_NAME="httparena-run-${FRAMEWORK}"
PORT="${PORT:-8080}"
H2PORT="${H2PORT:-8443}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
META_FILE="$ROOT_DIR/frameworks/$FRAMEWORK/meta.json"
CERTS_DIR="$ROOT_DIR/certs"
DATA_DIR="$ROOT_DIR/data"

if [ ! -d "$ROOT_DIR/frameworks/$FRAMEWORK" ]; then
    echo "Error: framework '$FRAMEWORK' not found in frameworks/"
    exit 1
fi

if [ ! -f "$META_FILE" ]; then
    echo "Error: meta.json not found for '$FRAMEWORK'"
    exit 1
fi

TESTS=$(python3 -c "import json; print(' '.join(json.load(open('$META_FILE'))['tests']))")

has_test() {
    echo "$TESTS" | grep -qw "$1"
}

cleanup() {
    echo ""
    echo "[stop] Stopping container..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Build
echo "[build] Building Docker image for $FRAMEWORK..."
if [ -x "$ROOT_DIR/frameworks/$FRAMEWORK/build.sh" ]; then
    "$ROOT_DIR/frameworks/$FRAMEWORK/build.sh" || { echo "FAIL: Docker build failed"; exit 1; }
else
    docker build -t "$IMAGE_NAME" "$ROOT_DIR/frameworks/$FRAMEWORK" || { echo "FAIL: Docker build failed"; exit 1; }
fi

# Remove any stale container
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Build docker run args
docker_args=(--name "$CONTAINER_NAME" -p "$PORT:8080")
docker_args+=(-v "$DATA_DIR/dataset.json:/data/dataset.json:ro")

needs_h2=false
if has_test "baseline-h2" || has_test "static-h2" || has_test "baseline-h3" || has_test "static-h3"; then
    needs_h2=true
fi

if $needs_h2 && [ -d "$CERTS_DIR" ]; then
    docker_args+=(-p "$H2PORT:8443" -v "$CERTS_DIR:/certs:ro")
fi

if has_test "compression"; then
    docker_args+=(-v "$DATA_DIR/dataset-large.json:/data/dataset-large.json:ro")
fi

if has_test "db"; then
    DB_FILE="$DATA_DIR/benchmark.db"
    if [ ! -f "$DB_FILE" ]; then
        echo "[db] benchmark.db not found, generating..."
        python3 "$SCRIPT_DIR/generate-db.py" "$DATA_DIR/dataset.json" "$DB_FILE"
    fi
    docker_args+=(-v "$DB_FILE:/data/benchmark.db:ro")
fi

if has_test "static-h2" || has_test "static-h3"; then
    docker_args+=(-v "$DATA_DIR/static:/data/static:ro")
fi

ENGINE=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('engine',''))" 2>/dev/null || true)
if [ "$ENGINE" = "io_uring" ]; then
    docker_args+=(--security-opt seccomp=unconfined)
    docker_args+=(--ulimit memlock=-1:-1)
fi

echo ""
echo "============================================"
echo "  Framework: $FRAMEWORK"
echo "  HTTP:      http://localhost:$PORT"
if $needs_h2; then
    echo "  HTTPS/H2:  https://localhost:$H2PORT"
fi
echo "  Tests:     $TESTS"
echo "============================================"
echo ""
echo "Container logs below. Press Ctrl+C to stop."
echo ""

# Run attached (not -d) so logs stream and Ctrl+C stops it
docker run --rm "${docker_args[@]}" "$IMAGE_NAME"
