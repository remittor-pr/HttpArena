import os
import sys
import asyncio
import json
import threading
import zlib
import sqlite3
from urllib.parse import parse_qs

import orjson

# -- Dataset ----------------------------------------------------------

dataset_items = None
dataset_path = os.environ.get("DATASET_PATH", "/data/dataset.json")
try:
    with open(dataset_path) as file:
        dataset_items = json.load(file)
except Exception:
    pass

# Large dataset for compression (pre-serialised)
large_json_buf: bytes | None = None
try:
    with open("/data/dataset-large.json") as file:
        raw = json.load(file)
    items = [ ]
    for d in raw:
        item = dict(d)
        item["total"] = round(d["price"] * d["quantity"] * 100) / 100
        items.append(item)
    large_json_buf = orjson.dumps( { "items": items, "count": len(items) } )
except Exception:
    pass

# -- SQLite (thread-local, sync — runs in threadpool via run_in_executor) --

db_available = os.path.exists("/data/benchmark.db")
DB_QUERY = (
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count"
    "  FROM items"
    " WHERE price BETWEEN ? AND ? LIMIT 50"
)
_local = threading.local()

def _get_db() -> sqlite3.Connection:
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = sqlite3.connect("/data/benchmark.db", uri = True, check_same_thread = False)
        conn.execute("PRAGMA mmap_size=268435456")
        conn.row_factory = sqlite3.Row
        _local.conn = conn
    return conn

# -- Helpers ----------------------------------------------------------

DEF_TEXT_HEADERS = [[ b'Content-Type', b'text/plain; charset=utf-8' ]]

def text_resp(body: str | bytes, status: int = 200):
    if isinstance(body, str):
        body = body.encode('utf-8')
    return status, DEF_TEXT_HEADERS, body

def json_resp(body: dict | str, status: int = 200, gzip: bool = False):
    if gzip:
        headers = [[ b'Content-Type', b'application/json'], [ b'Content-Encoding', b'gzip' ]]
    else:
        headers = [[ b'Content-Type', b'application/json' ]]
    if isinstance(body, dict):
        body = orjson.dumps(body)
    if isinstance(body, str):
        body = body.encode('utf-8')
    return status, headers, body

# -- Routes -----------------------------------------------------------

async def pipeline(scope, receive, send):
    return text_resp(b'ok')

async def baseline11(scope, receive, send):
    req_method = scope.get('method', '')
    query_params = parse_qs(scope.get('query_string', b'').decode())
    total = 0
    for v in query_params.values():
        try:
            total += int(v[0])
        except ValueError:
            pass
    if req_method == "POST":
        body = b''
        while True:
            message = await receive()
            body += message.get('body', b'')
            if not message.get('more_body', False):
                break
        if body:
            try:
                total += int(body.decode().strip())
            except UnicodeDecodeError:
                pass
            except ValueError:
                pass
    return text_resp(str(total))

async def baseline2(scope, receive, send):
    query_params = parse_qs(scope.get('query_string', b'').decode())
    total = 0
    for v in query_params.values():
        try:
            total += int(v[0])
        except ValueError:
            pass
    return text_resp(str(total))

async def json_endpoint(scope, receive, send):
    if dataset_items is None:
        return text_resp("No dataset", 500)
    items = [ ]
    for d in dataset_items:
        item = dict(d)
        item["total"] = round(d["price"] * d["quantity"] * 100) / 100
        items.append(item)
    return json_resp( { "items": items, "count": len(items) } )

async def compression_endpoint(scope, receive, send):
    if large_json_buf is None:
        return text_resp("No dataset", 500)
    compressed = zlib.compress(large_json_buf, level = 1, wbits = 31)
    return json_resp(compressed, gzip = True)

async def db_endpoint(scope, receive, send):
    query_params = parse_qs(scope.get('query_string', b'').decode())
    if not db_available:
        return json_resp( { "items": [ ], "count": 0 } )
    min_val = float(query_params.get("min", [10])[0])
    max_val = float(query_params.get("max", [50])[0])
    conn = _get_db()
    rows = conn.execute(DB_QUERY, (min_val, max_val)).fetchall()
    items = [ ]
    for row in rows:
        items.append(
            {
                "id"      : row["id"],
                "name"    : row["name"],
                "category": row["category"],
                "price"   : row["price"],
                "quantity": row["quantity"],
                "active"  : bool(row["active"]),
                "tags"    : json.loads(row["tags"]),
                "rating"  : { "score": row["rating_score"], "count": row["rating_count"] },
            }
        )
    return json_resp( { "items": items, "count": len(items) } )

async def upload_endpoint(scope, receive, send):
    size = 0
    while True:
        message = await receive()
        chunk = message.get('body', b'')
        size += len(chunk)
        if not message.get('more_body', False):
            break
    return text_resp(str(size))

ROUTES = {
    '/pipeline': pipeline,
    '/baseline11': baseline11,
    '/baseline2': baseline2,
    '/json': json_endpoint,
    '/compression': compression_endpoint,
    '/db': db_endpoint,
    '/upload': upload_endpoint,
}

async def handle_404(scope, receive, send):
    return text_resp(b'Not found', status = 404)

async def handle_405(scope, receive, send):
    return text_resp(b'Method Not Allowed', status = 405)

# -- ASGI app -----------------------------------------------------------

async def app(scope, receive, send):
    if scope['type'] == 'lifespan':
        while True:
            message = await receive()
            if message['type'] == 'lifespan.startup':
                # nothing
                await send({'type': 'lifespan.startup.complete'})
            elif message['type'] == 'lifespan.shutdown':
                # nothing
                await send({'type': 'lifespan.shutdown.complete'})
                return
        return
    req_method = scope.get('method', '')
    if req_method not in [ 'GET', 'POST' ]:
        await send( { 'type': 'http.response.start', 'status': 405, 'headers': DEF_TEXT_HEADERS } )
        await send( { 'type': 'http.response.body', 'body': b'Method Not Allowed', 'more_body': False } )
        return
    path = scope['path']
    app_handler = ROUTES.get(path, handle_404)
    status, headers, body = await app_handler(scope, receive, None)
    await send( { 'type': 'http.response.start', 'status': status, 'headers': headers } )
    await send( { 'type': 'http.response.body', 'body': body, 'more_body': False } )

# -----------------------------------------------------------------------

if __name__ == "__main__":
    import multiprocessing
    import fastpysgi

    workers = int(multiprocessing.cpu_count())
    host = '0.0.0.0'
    port = 8080

    def run_app():
        #loop = asyncio.get_event_loop()
        #loop.run_until_complete(db_setup())
        fastpysgi.server.read_buffer_size = 256*1024
        fastpysgi.server.backlog = 4096
        fastpysgi.server.loop_timeout = 1
        fastpysgi.run(app, host, port, loglevel = 0)
        sys.exit(0)

    processes = [ ]
    # fork limiting the cpu count - 1
    for i in range(1, workers):
        try:
            pid = os.fork()
            if pid == 0:
                run_app()
            else:
                processes.append(pid)
        except OSError as e:
            print("Failed to fork:", e)

    # run app on the main process too :)
    run_app()
