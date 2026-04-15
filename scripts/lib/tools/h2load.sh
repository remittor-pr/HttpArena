# scripts/lib/tools/h2load.sh — h2load dispatch + parse.
#
# Used for: HTTP/2 (baseline-h2, static-h2), gRPC unary (unary-grpc,
# unary-grpc-tls), gateway-64. Supports both native binary and docker-wrapped
# mode via H2LOAD_CMD — set once at driver startup based on LOADGEN_DOCKER.

# Set by the driver during startup — either ("h2load") or (docker run ...).
# If unset, fall back to native.
: "${H2LOAD_CMD:=}"

_h2load_cmd() {
    if [ -n "$H2LOAD_CMD" ]; then
        printf '%s\n' $H2LOAD_CMD
    else
        printf '%s\n' "$H2LOAD"
    fi
}

# ── Build arguments ─────────────────────────────────────────────────────────

h2load_build_args() {
    local endpoint="$1" conns="$2" pipeline="$3" duration="$4"
    local -a cmd
    mapfile -t cmd < <(_h2load_cmd)

    case "$endpoint" in
        h2)
            cmd+=("https://localhost:$H2PORT/baseline2?a=1&b=1"
                  -c "$conns" -m 100 -t "$H2THREADS" -D "$duration")
            ;;
        static-h2)
            cmd+=(-i "$REQUESTS_DIR/static-h2-uris.txt"
                  -H "Accept-Encoding: br;q=1, gzip;q=0.8"
                  -c "$conns" -m 32 -t "$H2THREADS" -D "$duration")
            ;;
        gateway-64)
            cmd+=(-i "$REQUESTS_DIR/gateway-64-uris.txt"
                  -H "Accept-Encoding: br;q=1, gzip;q=0.8"
                  -c "$conns" -m 32 -t "$H2THREADS" -D "$duration")
            ;;
        grpc)
            cmd+=("http://localhost:$PORT/benchmark.BenchmarkService/GetSum"
                  -d "$REQUESTS_DIR/grpc-sum.bin"
                  -H 'content-type: application/grpc'
                  -H 'te: trailers'
                  -c "$conns" -m 100 -t "$H2THREADS" -D "$duration")
            ;;
        grpc-tls)
            cmd+=("https://localhost:$H2PORT/benchmark.BenchmarkService/GetSum"
                  -d "$REQUESTS_DIR/grpc-sum.bin"
                  -H 'content-type: application/grpc'
                  -H 'te: trailers'
                  -c "$conns" -m 100 -t "$H2THREADS" -D "$duration")
            ;;
        *)
            fail "h2load_build_args: unknown endpoint '$endpoint'"
            ;;
    esac

    printf '%s\n' "${cmd[@]}"
}

# ── Execute ─────────────────────────────────────────────────────────────────

h2load_run() {
    timeout 45 taskset -c "$GCANNON_CPUS" "$@" 2>&1 || true
}

# ── Parse output ────────────────────────────────────────────────────────────

h2load_parse() {
    local output="$2"  # $1 = endpoint (unused for h2load, shape is uniform)

    # rps = successful 2xx responses divided by wall duration. h2load's
    # own "finished in Xs, Y req/s" number counts all completed requests
    # including 4xx/5xx, which silently inflates rps when the server is
    # broken — a stale image serving 404s would look like a throughput win.
    # Computing from 2xx + the reported duration makes that impossible.
    local duration_secs ok
    duration_secs=$(echo "$output" | grep -oP 'finished in \K[\d.]+' | head -1)
    duration_secs=${duration_secs:-1}
    ok=$(echo "$output" | grep -oP '\d+(?= 2xx)' | head -1)
    ok=${ok:-0}
    echo "rps=$(awk -v ok="$ok" -v dur="$duration_secs" \
        'BEGIN { if (dur+0 > 0) printf "%d", ok/dur; else print 0 }' 2>/dev/null || echo 0)"

    # Latency — h2 mode uses "time for request:" one-liner,
    # h3 (not used here) uses a tabular "request :" row.
    echo "avg_lat=$(echo "$output" | awk '/time for request:/{print $6}' | head -1)"
    echo "p99_lat=$(echo "$output" | awk '/time for request:/{print $6}' | head -1)"

    echo "reconnects=0"
    echo "bandwidth=$(echo "$output" | grep -oP 'finished in [\d.]+s, [\d.]+ req/s, \K[\d.]+[KMGT]?B/s' | head -1 || echo 0)"

    echo "status_2xx=$(echo "$output" | grep -oP '\d+(?= 2xx)' | head -1 || echo 0)"
    echo "status_3xx=$(echo "$output" | grep -oP '\d+(?= 3xx)' | head -1 || echo 0)"
    echo "status_4xx=$(echo "$output" | grep -oP '\d+(?= 4xx)' | head -1 || echo 0)"
    echo "status_5xx=$(echo "$output" | grep -oP '\d+(?= 5xx)' | head -1 || echo 0)"
}
