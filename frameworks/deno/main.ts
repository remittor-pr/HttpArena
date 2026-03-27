import { Database } from "jsr:@db/sqlite@0.12";
import { gzipSync } from "node:zlib";

const datasetPath = Deno.env.get("DATASET_PATH") || "/data/dataset.json";
let datasetItems: any[] | undefined;

try {
    datasetItems = JSON.parse(Deno.readTextFileSync(datasetPath));
} catch { /* dataset not available */ }

// Pre-serialized large dataset for compression
let largeJsonBuf: Uint8Array | undefined;
try {
    const raw = JSON.parse(Deno.readTextFileSync("/data/dataset-large.json"));
    const items = raw.map((d: any) => ({
        id: d.id, name: d.name, category: d.category,
        price: d.price, quantity: d.quantity, active: d.active,
        tags: d.tags, rating: d.rating,
        total: Math.round(d.price * d.quantity * 100) / 100,
    }));
    largeJsonBuf = new TextEncoder().encode(JSON.stringify({ items, count: items.length }));
} catch { /* large dataset not available */ }

// SQLite
let dbStmt: any = null;
try {
    const db = new Database("/data/benchmark.db", { readonly: true });
    db.exec("PRAGMA mmap_size=268435456");
    dbStmt = db.prepare("SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50");
} catch { /* db not available */ }

// PostgreSQL pool for async-db
let pgPool: any = null;
{
    const dbUrl = Deno.env.get("DATABASE_URL");
    if (dbUrl) {
        try {
            const pg = await import("npm:pg");
            pgPool = new pg.Pool({ connectionString: dbUrl, max: 4 });
        } catch { /* pg not available */ }
    }
}

const PLAIN = { "content-type": "text/plain", "server": "deno" };
const JSON_HDR = { "content-type": "application/json", "server": "deno" };

function sumQuery(url: string, pathEnd: number): number {
    const q = url.indexOf("?", pathEnd);
    if (q === -1) return 0;
    let sum = 0;
    const qs = url.slice(q + 1);
    let i = 0;
    while (i < qs.length) {
        const eq = qs.indexOf("=", i);
        if (eq === -1) break;
        let amp = qs.indexOf("&", eq);
        if (amp === -1) amp = qs.length;
        const n = parseInt(qs.slice(eq + 1, amp), 10);
        if (n === n) sum += n;
        i = amp + 1;
    }
    return sum;
}

function parseQueryParam(url: string, queryStart: number, key: string, def: number): number {
    if (queryStart === -1) return def;
    const qs = url.slice(queryStart + 1);
    for (const pair of qs.split("&")) {
        const eq = pair.indexOf("=");
        if (eq === -1) continue;
        if (pair.slice(0, eq) === key) {
            const v = parseFloat(pair.slice(eq + 1));
            return isNaN(v) ? def : v;
        }
    }
    return def;
}

export default {
    async fetch(req: Request): Promise<Response> {
        const url = req.url;
        const pathStart = url.indexOf("/", 8);
        const queryStart = url.indexOf("?", pathStart);
        const path = queryStart === -1 ? url.slice(pathStart) : url.slice(pathStart, queryStart);

        if (path === "/pipeline") {
            return new Response("ok", { headers: PLAIN });
        }

        if (path === "/json") {
            if (datasetItems) {
                const items = datasetItems.map((d: any) => ({
                    id: d.id, name: d.name, category: d.category,
                    price: d.price, quantity: d.quantity, active: d.active,
                    tags: d.tags, rating: d.rating,
                    total: Math.round(d.price * d.quantity * 100) / 100,
                }));
                const body = JSON.stringify({ items, count: items.length });
                return new Response(body, { headers: JSON_HDR });
            }
            return new Response("No dataset", { status: 500 });
        }

        if (path === "/compression") {
            if (largeJsonBuf) {
                const compressed = gzipSync(largeJsonBuf, { level: 1 });
                return new Response(compressed, {
                    headers: {
                        "content-type": "application/json",
                        "content-encoding": "gzip",
                        "content-length": String(compressed.length),
                        "server": "deno",
                    },
                });
            }
            return new Response("No dataset", { status: 500 });
        }

        if (path === "/db") {
            if (!dbStmt) {
                return new Response('{"items":[],"count":0}', { headers: JSON_HDR });
            }
            const min = parseQueryParam(url, queryStart, "min", 10);
            const max = parseQueryParam(url, queryStart, "max", 50);
            const rows = dbStmt.all(min, max) as any[];
            const items = rows.map((r: any) => ({
                id: r.id, name: r.name, category: r.category,
                price: r.price, quantity: r.quantity, active: r.active === 1,
                tags: JSON.parse(r.tags),
                rating: { score: r.rating_score, count: r.rating_count },
            }));
            const body = JSON.stringify({ items, count: items.length });
            return new Response(body, { headers: JSON_HDR });
        }

        if (path === "/async-db") {
            if (!pgPool) {
                return new Response('{"items":[],"count":0}', { headers: JSON_HDR });
            }
            const min = parseQueryParam(url, queryStart, "min", 10);
            const max = parseQueryParam(url, queryStart, "max", 50);
            try {
                const result = await pgPool.query(
                    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50",
                    [min, max]
                );
                const items = result.rows.map((r: any) => ({
                    id: r.id, name: r.name, category: r.category,
                    price: r.price, quantity: r.quantity, active: r.active,
                    tags: r.tags,
                    rating: { score: r.rating_score, count: r.rating_count },
                }));
                const body = JSON.stringify({ items, count: items.length });
                return new Response(body, { headers: JSON_HDR });
            } catch {
                return new Response('{"items":[],"count":0}', { headers: JSON_HDR });
            }
        }

        if (path === "/upload" && req.method === "POST") {
            const buf = new Uint8Array(await req.arrayBuffer());
            return new Response(String(buf.byteLength), { headers: PLAIN });
        }

        // /baseline11
        let sum = sumQuery(url, pathStart);
        if (req.method === "POST") {
            const body = (await req.text()).trim();
            const n = parseInt(body, 10);
            if (n === n) sum += n;
        }
        return new Response(String(sum), { headers: PLAIN });
    },
};
