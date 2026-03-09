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
DATA_DIR="$ROOT_DIR/data"

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

# Mount volumes based on subscribed tests
docker_args=(-d --name "$CONTAINER_NAME" -p "$PORT:8080")
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

if has_test "static-h2" || has_test "static-h3"; then
    docker_args+=(-v "$DATA_DIR/static:/data/static:ro")
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

# ───── Helpers ─────

check() {
    local label="$1"
    local expected_body="$2"
    shift 2
    local response
    response=$(curl -s -D- "$@")
    local body
    body=$(echo "$response" | tail -1)

    if [ "$body" = "$expected_body" ]; then
        echo "  PASS [$label]"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [$label]: expected body '$expected_body', got '$body'"
        FAIL=$((FAIL + 1))
    fi
}

check_status() {
    local label="$1"
    local expected_status="$2"
    shift 2
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' "$@")

    if [ "$http_code" = "$expected_status" ]; then
        echo "  PASS [$label] (HTTP $http_code)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [$label]: expected HTTP $expected_status, got HTTP $http_code"
        FAIL=$((FAIL + 1))
    fi
}

check_header() {
    local label="$1"
    local header_name="$2"
    local expected_value="$3"
    shift 3
    local headers
    headers=$(curl -s -D- -o /dev/null "$@")
    local value
    value=$(echo "$headers" | grep -i "^${header_name}:" | sed 's/^[^:]*: *//' | tr -d '\r' || true)

    if [ "$value" = "$expected_value" ]; then
        echo "  PASS [$label] ($header_name: $value)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [$label]: expected $header_name '$expected_value', got '$value'"
        FAIL=$((FAIL + 1))
    fi
}

wait_h2() {
    echo "[wait] Waiting for HTTPS port..."
    for i in $(seq 1 15); do
        if curl -sk -o /dev/null "https://localhost:$H2PORT/baseline2?a=1&b=1" 2>/dev/null; then
            return 0
        fi
        if [ "$i" -eq 15 ]; then
            echo "  FAIL: HTTPS port $H2PORT not responding"
            FAIL=$((FAIL + 1))
            return 1
        fi
        sleep 1
    done
}

# ───── Baseline (GET/POST /baseline11) ─────

if has_test "baseline" || has_test "limited-conn"; then
    echo "[test] baseline endpoints"
    check "GET /baseline11?a=13&b=42" "55" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    check "POST /baseline11?a=13&b=42 body=20" "75" \
        -X POST -H "Content-Type: text/plain" -d "20" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    check "POST /baseline11?a=13&b=42 chunked body=20" "75" \
        -X POST -H "Content-Type: text/plain" -H "Transfer-Encoding: chunked" -d "20" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    # Anti-cheat: randomized inputs to detect hardcoded responses
    echo "[test] baseline anti-cheat (randomized inputs)"
    A1=$((RANDOM % 900 + 100))
    B1=$((RANDOM % 900 + 100))
    check "GET /baseline11?a=$A1&b=$B1 (random)" "$((A1 + B1))" \
        "http://localhost:$PORT/baseline11?a=$A1&b=$B1"

    BODY1=$((RANDOM % 900 + 100))
    BODY2=$((RANDOM % 900 + 100))
    while [ "$BODY1" -eq "$BODY2" ]; do BODY2=$((RANDOM % 900 + 100)); done
    check "POST body=$BODY1 (cache check 1)" "$((13 + 42 + BODY1))" \
        -X POST -H "Content-Type: text/plain" -d "$BODY1" \
        "http://localhost:$PORT/baseline11?a=13&b=42"
    check "POST body=$BODY2 (cache check 2)" "$((13 + 42 + BODY2))" \
        -X POST -H "Content-Type: text/plain" -d "$BODY2" \
        "http://localhost:$PORT/baseline11?a=13&b=42"
fi

# ───── Pipelined (GET /pipeline) ─────

if has_test "pipelined"; then
    echo "[test] pipelined endpoint"
    check "GET /pipeline" "ok" \
        "http://localhost:$PORT/pipeline"
fi

# ───── JSON Processing (GET /json) ─────

if has_test "json"; then
    echo "[test] json endpoint"
    response=$(curl -s "http://localhost:$PORT/json")
    json_result=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_total = all('total' in item for item in items) if items else False
# Verify total is computed correctly (price * quantity, rounded to 2 decimals)
correct_totals = True
for item in items:
    expected = round(item['price'] * item['quantity'], 2)
    if abs(item.get('total', 0) - expected) > 0.01:
        correct_totals = False
        break
print(f'{count} {has_total} {correct_totals}')
" 2>/dev/null || echo "0 False False")
    json_count=$(echo "$json_result" | cut -d' ' -f1)
    json_total=$(echo "$json_result" | cut -d' ' -f2)
    json_correct=$(echo "$json_result" | cut -d' ' -f3)

    if [ "$json_count" = "50" ] && [ "$json_total" = "True" ] && [ "$json_correct" = "True" ]; then
        echo "  PASS [GET /json] (50 items, totals computed correctly)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [GET /json]: count=$json_count, has_total=$json_total, correct_totals=$json_correct"
        FAIL=$((FAIL + 1))
    fi

    # Check Content-Type header
    check_header "GET /json Content-Type" "Content-Type" "application/json" \
        "http://localhost:$PORT/json"
fi

# ───── Upload (POST /upload) ─────

if has_test "upload"; then
    echo "[test] upload endpoint"
    # Small upload: known CRC32
    UPLOAD_BODY="Hello, HttpArena!"
    EXPECTED_CRC=$(python3 -c "import zlib; print(format(zlib.crc32(b'$UPLOAD_BODY') & 0xFFFFFFFF, '08x'))")
    check "POST /upload small body" "$EXPECTED_CRC" \
        -X POST -H "Content-Type: application/octet-stream" --data-binary "$UPLOAD_BODY" \
        "http://localhost:$PORT/upload"

    # Anti-cheat: random body to detect hardcoded CRC
    RANDOM_BODY=$(head -c 64 /dev/urandom | base64 | head -c 48)
    EXPECTED_RANDOM_CRC=$(echo -n "$RANDOM_BODY" | python3 -c "import sys,zlib; print(format(zlib.crc32(sys.stdin.buffer.read()) & 0xFFFFFFFF, '08x'))")
    ACTUAL_CRC=$(curl -s -X POST -H "Content-Type: application/octet-stream" --data-binary "$RANDOM_BODY" "http://localhost:$PORT/upload")
    if [ "$ACTUAL_CRC" = "$EXPECTED_RANDOM_CRC" ]; then
        echo "  PASS [POST /upload random body] (CRC32: $ACTUAL_CRC)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [POST /upload random body]: expected CRC '$EXPECTED_RANDOM_CRC', got '$ACTUAL_CRC'"
        FAIL=$((FAIL + 1))
    fi
fi

# ───── Compression (GET /compression) ─────

if has_test "compression"; then
    echo "[test] compression endpoint"

    # Must return Content-Encoding: gzip when Accept-Encoding: gzip is sent
    comp_headers=$(curl -s -D- -o /dev/null -H "Accept-Encoding: gzip" "http://localhost:$PORT/compression")
    comp_encoding=$(echo "$comp_headers" | grep -i "^content-encoding:" | tr -d '\r' | awk '{print tolower($2)}' || true)
    if [ "$comp_encoding" = "gzip" ]; then
        echo "  PASS [compression Content-Encoding: gzip]"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [compression]: expected Content-Encoding gzip, got '$comp_encoding'"
        FAIL=$((FAIL + 1))
    fi

    # Verify compressed response is valid JSON with items and totals
    comp_response=$(curl -s --compressed -H "Accept-Encoding: gzip" "http://localhost:$PORT/compression")
    comp_result=$(echo "$comp_response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_total = all('total' in item for item in items) if items else False
print(f'{count} {has_total}')
" 2>/dev/null || echo "0 False")
    comp_count=$(echo "$comp_result" | cut -d' ' -f1)
    comp_total=$(echo "$comp_result" | cut -d' ' -f2)

    if [ "$comp_count" = "6000" ] && [ "$comp_total" = "True" ]; then
        echo "  PASS [compression response] (6000 items with totals)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [compression response]: count=$comp_count, has_total=$comp_total"
        FAIL=$((FAIL + 1))
    fi

    # Verify compressed size is reasonable (should be well under 1MB uncompressed ~1MB)
    comp_size=$(curl -s -o /dev/null -w '%{size_download}' -H "Accept-Encoding: gzip" "http://localhost:$PORT/compression")
    if [ "$comp_size" -lt 500000 ]; then
        echo "  PASS [compression size] ($comp_size bytes < 500KB)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [compression size]: $comp_size bytes — compression not effective"
        FAIL=$((FAIL + 1))
    fi
fi

# ───── Caching (GET /caching with ETag) ─────

if has_test "caching"; then
    echo "[test] caching endpoint"

    # Without If-None-Match: should return 200 with body "OK" and ETag header
    check_status "GET /caching without If-None-Match" "200" \
        "http://localhost:$PORT/caching"

    check "GET /caching body" "OK" \
        "http://localhost:$PORT/caching"

    check_header "GET /caching ETag header" "ETag" '"AOK"' \
        "http://localhost:$PORT/caching"

    # With matching If-None-Match: should return 304
    check_status "GET /caching with matching If-None-Match" "304" \
        -H 'If-None-Match: "AOK"' "http://localhost:$PORT/caching"

    # 304 should have ETag header
    check_header "GET /caching 304 ETag header" "ETag" '"AOK"' \
        -H 'If-None-Match: "AOK"' "http://localhost:$PORT/caching"

    # 304 should have no body
    caching_304_body=$(curl -s -H 'If-None-Match: "AOK"' "http://localhost:$PORT/caching")
    if [ -z "$caching_304_body" ]; then
        echo "  PASS [GET /caching 304 no body]"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [GET /caching 304 no body]: got body '$caching_304_body'"
        FAIL=$((FAIL + 1))
    fi

    # With non-matching If-None-Match: should return 200
    check_status "GET /caching with non-matching If-None-Match" "200" \
        -H 'If-None-Match: "WRONG"' "http://localhost:$PORT/caching"
fi

# ───── Baseline H2 (GET /baseline2 over HTTP/2 + TLS) ─────

if has_test "baseline-h2"; then
    echo "[test] baseline-h2 endpoint"
    if wait_h2; then
        check "GET /baseline2?a=13&b=42 over HTTP/2" "55" \
            -sk "https://localhost:$H2PORT/baseline2?a=13&b=42"

        # Anti-cheat: randomized query params
        A3=$((RANDOM % 900 + 100))
        B3=$((RANDOM % 900 + 100))
        check "GET /baseline2?a=$A3&b=$B3 over HTTP/2 (random)" "$((A3 + B3))" \
            -sk "https://localhost:$H2PORT/baseline2?a=$A3&b=$B3"
    fi
fi

# ───── Static Files H2 (GET /static/* over HTTP/2 + TLS) ─────

if has_test "static-h2"; then
    echo "[test] static-h2 endpoint"
    if wait_h2; then
        # Check a few static files exist and return correct Content-Type
        check_header "GET /static/reset.css Content-Type" "Content-Type" "text/css" \
            -sk "https://localhost:$H2PORT/static/reset.css"

        check_header "GET /static/app.js Content-Type" "Content-Type" "application/javascript" \
            -sk "https://localhost:$H2PORT/static/app.js"

        check_header "GET /static/manifest.json Content-Type" "Content-Type" "application/json" \
            -sk "https://localhost:$H2PORT/static/manifest.json"

        # Check response size is non-zero
        static_size=$(curl -sk -o /dev/null -w '%{size_download}' "https://localhost:$H2PORT/static/reset.css")
        if [ "$static_size" -gt 0 ]; then
            echo "  PASS [static-h2 response size] ($static_size bytes)"
            PASS=$((PASS + 1))
        else
            echo "  FAIL [static-h2 response size]: empty response"
            FAIL=$((FAIL + 1))
        fi

        # 404 for missing files
        check_status "GET /static/nonexistent.txt" "404" \
            -sk "https://localhost:$H2PORT/static/nonexistent.txt"
    fi
fi

# ───── Summary ─────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
