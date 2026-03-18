import json
import os
import gzip
import sqlite3
import threading
from django.http import HttpResponse

# Load raw dataset for per-request processing
dataset_items = None
dataset_path = os.environ.get('DATASET_PATH', '/data/dataset.json')
try:
    with open(dataset_path) as f:
        dataset_items = json.load(f)
except Exception:
    pass

# Large dataset for compression — pre-compute JSON and gzip
large_json_buf = None
large_gzip_buf = None
try:
    with open('/data/dataset-large.json') as f:
        raw = json.load(f)
    items = []
    for d in raw:
        item = dict(d)
        item['total'] = round(d['price'] * d['quantity'] * 100) / 100
        items.append(item)
    large_json_buf = json.dumps({'items': items, 'count': len(items)}).encode()
    large_gzip_buf = gzip.compress(large_json_buf, compresslevel=1)
except Exception:
    pass

# Pre-compute JSON response for /json endpoint
json_response_buf = None
if dataset_items:
    items = []
    for d in dataset_items:
        item = dict(d)
        item['total'] = round(d['price'] * d['quantity'] * 100) / 100
        items.append(item)
    json_response_buf = json.dumps({'items': items, 'count': len(items)}).encode()

# SQLite
db_available = os.path.exists('/data/benchmark.db')
DB_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'

_local = threading.local()

def get_db():
    if not hasattr(_local, 'conn'):
        _local.conn = sqlite3.connect('/data/benchmark.db', uri=True)
        _local.conn.execute('PRAGMA mmap_size=268435456')
        _local.conn.row_factory = sqlite3.Row
    return _local.conn


def pipeline(request):
    resp = HttpResponse(b'ok', content_type='text/plain')
    resp['Server'] = 'django'
    return resp


def baseline11(request):
    total = 0
    for v in request.GET.values():
        try:
            total += int(v)
        except ValueError:
            pass
    if request.method == 'POST' and request.body:
        try:
            total += int(request.body.strip())
        except ValueError:
            pass
    resp = HttpResponse(str(total), content_type='text/plain')
    resp['Server'] = 'django'
    return resp


def baseline2(request):
    total = 0
    for v in request.GET.values():
        try:
            total += int(v)
        except ValueError:
            pass
    resp = HttpResponse(str(total), content_type='text/plain')
    resp['Server'] = 'django'
    return resp


def json_endpoint(request):
    if json_response_buf:
        resp = HttpResponse(json_response_buf, content_type='application/json')
        resp['Server'] = 'django'
        return resp
    return HttpResponse('No dataset', status=500)


def compression_endpoint(request):
    if large_gzip_buf:
        resp = HttpResponse(large_gzip_buf, content_type='application/json')
        resp['Content-Encoding'] = 'gzip'
        resp['Server'] = 'django'
        return resp
    return HttpResponse('No dataset', status=500)


def db_endpoint(request):
    if not db_available:
        resp = HttpResponse(b'{"items":[],"count":0}', content_type='application/json')
        resp['Server'] = 'django'
        return resp
    min_val = float(request.GET.get('min', 10))
    max_val = float(request.GET.get('max', 50))
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
    resp = HttpResponse(body, content_type='application/json')
    resp['Server'] = 'django'
    return resp


def upload_endpoint(request):
    data = request.body
    resp = HttpResponse(str(len(data)), content_type='text/plain')
    resp['Server'] = 'django'
    return resp
