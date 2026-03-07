#!/usr/bin/env bash
set -euo pipefail

FRAMEWORK="$1"
IMAGE_NAME="httparena-${FRAMEWORK}"
CONTAINER_NAME="httparena-validate-${FRAMEWORK}"
PORT=8080
H2PORT=8443
PASS=0
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
META_FILE="$ROOT_DIR/frameworks/$FRAMEWORK/meta.json"
CERTS_DIR="$ROOT_DIR/certs"

cleanup() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Validating: $FRAMEWORK ==="

# Read subscribed tests from meta.json
if [ ! -f "$META_FILE" ]; then
    echo "FAIL: meta.json not found"
    exit 1
fi
TESTS=$(python3 -c "import json; print(' '.join(json.load(open('$META_FILE'))['tests']))")
echo "[info] Subscribed tests: $TESTS"

has_test() {
    echo "$TESTS" | grep -qw "$1"
}

# Build
echo "[build] Building Docker image..."
if [ -x "frameworks/$FRAMEWORK/build.sh" ]; then
    "frameworks/$FRAMEWORK/build.sh" || { echo "FAIL: Docker build failed"; exit 1; }
else
    docker build -t "$IMAGE_NAME" "frameworks/$FRAMEWORK" || { echo "FAIL: Docker build failed"; exit 1; }
fi

# Run
docker_args=(-d --name "$CONTAINER_NAME" -p "$PORT:8080")
docker_args+=(-v "$ROOT_DIR/data/dataset.json:/data/dataset.json:ro")

if has_test "baseline-h2" && [ -d "$CERTS_DIR" ]; then
    docker_args+=(-p "$H2PORT:8443" -v "$CERTS_DIR:/certs:ro")
fi

docker run "${docker_args[@]}" "$IMAGE_NAME"

# Wait for server to start
echo "[wait] Waiting for server..."
for i in $(seq 1 30); do
    if curl -s -o /dev/null -w '' "http://localhost:$PORT/baseline11?a=1&b=1" 2>/dev/null; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "FAIL: Server did not start within 30s"
        exit 1
    fi
    sleep 1
done
echo "[ready] Server is up"

check() {
    local label="$1"
    local expected_body="$2"
    shift 2
    local response
    response=$(curl -s -D- "$@")
    local body
    body=$(echo "$response" | tail -1)
    local server_hdr
    server_hdr=$(echo "$response" | grep -i "^server:" || true)

    local ok=true

    if [ "$body" != "$expected_body" ]; then
        echo "  FAIL [$label]: expected body '$expected_body', got '$body'"
        ok=false
    fi

    if [ -z "$server_hdr" ]; then
        echo "  FAIL [$label]: missing Server header in response"
        ok=false
    fi

    if $ok; then
        echo "  PASS [$label]"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

# baseline / limited-conn both use /baseline11
if has_test "baseline" || has_test "limited-conn"; then
    echo "[test] baseline endpoints"
    check "GET /baseline11?a=13&b=42" "55" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    check "POST /baseline11?a=13&b=42 + CL body=20" "75" \
        -X POST -H "Content-Type: text/plain" -d "20" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    check "POST /baseline11?a=13&b=42 + chunked body=20" "75" \
        -X POST -H "Content-Type: text/plain" -H "Transfer-Encoding: chunked" -d "20" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    # Cache detection: same URL, different body — verify server reads the body
    echo "[test] cache detection"
    BODY1=$((RANDOM % 900 + 100))
    BODY2=$((RANDOM % 900 + 100))
    while [ "$BODY1" -eq "$BODY2" ]; do BODY2=$((RANDOM % 900 + 100)); done
    EXPECTED1=$((13 + 42 + BODY1))
    EXPECTED2=$((13 + 42 + BODY2))

    check "POST /baseline11?a=13&b=42 + body=$BODY1 (cache check 1)" "$EXPECTED1" \
        -X POST -H "Content-Type: text/plain" -d "$BODY1" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    check "POST /baseline11?a=13&b=42 + body=$BODY2 (cache check 2)" "$EXPECTED2" \
        -X POST -H "Content-Type: text/plain" -d "$BODY2" \
        "http://localhost:$PORT/baseline11?a=13&b=42"
fi

# pipelined uses /pipeline
if has_test "pipelined"; then
    echo "[test] pipelined endpoint"
    check "GET /pipeline" "ok" \
        "http://localhost:$PORT/pipeline"
fi

# json uses /json
if has_test "json"; then
    echo "[test] json endpoint"
    response=$(curl -s "http://localhost:$PORT/json")
    json_result=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_total = all('total' in item for item in items) if items else False
print(f'{count} {has_total}')
" 2>/dev/null || echo "0 False")
    json_count=$(echo "$json_result" | cut -d' ' -f1)
    json_total=$(echo "$json_result" | cut -d' ' -f2)

    if [ "$json_count" = "50" ] && [ "$json_total" = "True" ]; then
        echo "  PASS [GET /json]"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [GET /json]: count=$json_count, has_total=$json_total"
        FAIL=$((FAIL + 1))
    fi
fi

# baseline-h2 uses /baseline2 over HTTP/2 + TLS on port 8443
if has_test "baseline-h2"; then
    echo "[test] baseline-h2 endpoint"
    # Wait for H2 port
    for i in $(seq 1 10); do
        if curl -sk -o /dev/null "https://localhost:$H2PORT/baseline2?a=1&b=1" 2>/dev/null; then
            break
        fi
        if [ "$i" -eq 10 ]; then
            echo "  FAIL [baseline-h2]: HTTPS port $H2PORT not responding"
            FAIL=$((FAIL + 1))
        fi
        sleep 1
    done

    check "GET /baseline2?a=13&b=42 over HTTP/2" "55" \
        -sk "https://localhost:$H2PORT/baseline2?a=13&b=42"

    # Cache detection: same URL, different query params
    A3=$((RANDOM % 900 + 100))
    B3=$((RANDOM % 900 + 100))
    EXPECTED3=$((A3 + B3))
    check "GET /baseline2?a=$A3&b=$B3 over HTTP/2 (cache check)" "$EXPECTED3" \
        -sk "https://localhost:$H2PORT/baseline2?a=$A3&b=$B3"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
