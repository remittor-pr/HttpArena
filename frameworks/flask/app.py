import json
import os
import gzip
import sqlite3
import zlib
from flask import Flask, request, make_response
import psycopg_pool
import psycopg.rows

app = Flask(__name__)
app.config['JSONIFY_PRETTYPRINT_REGULAR'] = False

# Load raw dataset for per-request processing
dataset_items = None
dataset_path = os.environ.get('DATASET_PATH', '/data/dataset.json')
try:
    with open(dataset_path) as f:
        dataset_items = json.load(f)
except Exception:
    pass

# Large dataset for compression
large_json_buf = None
try:
    with open('/data/dataset-large.json') as f:
        raw = json.load(f)
    items = []
    for d in raw:
        item = dict(d)
        item['total'] = round(d['price'] * d['quantity'] * 100) / 100
        items.append(item)
    large_json_buf = json.dumps({'items': items, 'count': len(items)}).encode()
except Exception:
    pass

# SQLite
db_available = os.path.exists('/data/benchmark.db')
DB_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'

def get_db():
    if not hasattr(get_db, '_local'):
        import threading
        get_db._local = threading.local()
    local = get_db._local
    if not hasattr(local, 'conn'):
        local.conn = sqlite3.connect('/data/benchmark.db', uri=True)
        local.conn.execute('PRAGMA mmap_size=268435456')
        local.conn.row_factory = sqlite3.Row
    return local.conn

# Postgres (sync via psycopg)
pg_pool = None
PG_QUERY = (
    'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count '
    'FROM items WHERE price BETWEEN %s AND %s LIMIT 50'
)
_pg_url = os.environ.get('DATABASE_URL')
if _pg_url:
    try:
        pg_pool = psycopg_pool.ConnectionPool(
            conninfo=_pg_url,
            min_size=2,
            max_size=4,
            kwargs={'row_factory': psycopg.rows.dict_row},
        )
    except Exception:
        pg_pool = None


@app.route('/pipeline')
def pipeline():
    resp = make_response(b'ok')
    resp.content_type = 'text/plain'
    resp.headers['Server'] = 'flask'
    return resp


@app.route('/baseline11', methods=['GET', 'POST'])
def baseline11():
    total = 0
    for v in request.args.values():
        try:
            total += int(v)
        except ValueError:
            pass
    if request.method == 'POST' and request.data:
        try:
            total += int(request.data.strip())
        except ValueError:
            pass
    resp = make_response(str(total))
    resp.content_type = 'text/plain'
    resp.headers['Server'] = 'flask'
    return resp


@app.route('/baseline2')
def baseline2():
    total = 0
    for v in request.args.values():
        try:
            total += int(v)
        except ValueError:
            pass
    resp = make_response(str(total))
    resp.content_type = 'text/plain'
    resp.headers['Server'] = 'flask'
    return resp


@app.route('/json')
def json_endpoint():
    if dataset_items:
        items = []
        for d in dataset_items:
            item = dict(d)
            item['total'] = round(d['price'] * d['quantity'] * 100) / 100
            items.append(item)
        resp = make_response(json.dumps({'items': items, 'count': len(items)}))
        resp.content_type = 'application/json'
        resp.headers['Server'] = 'flask'
        return resp
    return 'No dataset', 500


@app.route('/compression')
def compression_endpoint():
    if large_json_buf:
        compressed = gzip.compress(large_json_buf, compresslevel=1)
        resp = make_response(compressed)
        resp.content_type = 'application/json'
        resp.headers['Content-Encoding'] = 'gzip'
        resp.headers['Server'] = 'flask'
        return resp
    return 'No dataset', 500


@app.route('/db')
def db_endpoint():
    if not db_available:
        resp = make_response('{"items":[],"count":0}')
        resp.content_type = 'application/json'
        resp.headers['Server'] = 'flask'
        return resp
    min_val = request.args.get('min', 10, type=float)
    max_val = request.args.get('max', 50, type=float)
    conn = get_db()
    rows = conn.execute(DB_QUERY, (min_val, max_val)).fetchall()
    items = []
    for r in rows:
        items.append({
            'id': r['id'], 'name': r['name'], 'category': r['category'],
            'price': r['price'], 'quantity': r['quantity'], 'active': bool(r['active']),
            'tags': json.loads(r['tags']),
            'rating': {'score': r['rating_score'], 'count': r['rating_count']}
        })
    body = json.dumps({'items': items, 'count': len(items)})
    resp = make_response(body)
    resp.content_type = 'application/json'
    resp.headers['Server'] = 'flask'
    return resp


@app.route('/async-db')
def async_db_endpoint():
    if pg_pool is None:
        resp = make_response('{"items":[],"count":0}')
        resp.content_type = 'application/json'
        resp.headers['Server'] = 'flask'
        return resp
    min_val = request.args.get('min', 10, type=float)
    max_val = request.args.get('max', 50, type=float)
    try:
        with pg_pool.connection() as conn:
            rows = conn.execute(PG_QUERY, (min_val, max_val)).fetchall()
        items = []
        for r in rows:
            items.append({
                'id': r['id'], 'name': r['name'], 'category': r['category'],
                'price': r['price'], 'quantity': r['quantity'], 'active': r['active'],
                'tags': r['tags'],
                'rating': {'score': r['rating_score'], 'count': r['rating_count']}
            })
        body = json.dumps({'items': items, 'count': len(items)})
        resp = make_response(body)
        resp.content_type = 'application/json'
        resp.headers['Server'] = 'flask'
        return resp
    except Exception:
        resp = make_response('{"items":[],"count":0}')
        resp.content_type = 'application/json'
        resp.headers['Server'] = 'flask'
        return resp


@app.route('/upload', methods=['POST'])
def upload_endpoint():
    data = request.get_data()
    resp = make_response(str(len(data)))
    resp.content_type = 'text/plain'
    resp.headers['Server'] = 'flask'
    return resp
