import { Elysia } from "elysia";
import { Database } from "bun:sqlite";
import { readFileSync, readdirSync } from "fs";

const MIME_TYPES: Record<string, string> = {
  ".css": "text/css", ".js": "application/javascript", ".html": "text/html",
  ".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp", ".json": "application/json",
};

// Load datasets
const datasetItems: any[] = JSON.parse(readFileSync("/data/dataset.json", "utf8"));

const largeData = JSON.parse(readFileSync("/data/dataset-large.json", "utf8"));
const largeItems = largeData.map((d: any) => ({
  id: d.id, name: d.name, category: d.category,
  price: d.price, quantity: d.quantity, active: d.active,
  tags: d.tags, rating: d.rating,
  total: Math.round(d.price * d.quantity * 100) / 100,
}));
const largeJsonBuf = Buffer.from(JSON.stringify({ items: largeItems, count: largeItems.length }));

// Open SQLite database read-only
let dbStmt: any = null;
for (let attempt = 0; attempt < 3 && !dbStmt; attempt++) {
  try {
    const db = new Database("/data/benchmark.db", { readonly: true });
    db.exec("PRAGMA mmap_size=268435456");
    dbStmt = db.prepare("SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50");
  } catch (e) {
    console.error(`SQLite open attempt ${attempt + 1} failed:`, e);
    if (attempt < 2) Bun.sleepSync(50);
  }
}

// PostgreSQL pool for async-db
let pgPool: any = null;
{
  const dbUrl = process.env.DATABASE_URL;
  if (dbUrl) {
    try {
      const { Pool } = require("pg");
      pgPool = new Pool({ connectionString: dbUrl, max: 4 });
    } catch (_) {}
  }
}

// Pre-load static files
const staticFiles: Record<string, { buf: Buffer; ct: string }> = {};
try {
  for (const name of readdirSync("/data/static")) {
    const buf = readFileSync(`/data/static/${name}`);
    const ext = name.slice(name.lastIndexOf("."));
    staticFiles[name] = { buf: Buffer.from(buf), ct: MIME_TYPES[ext] || "application/octet-stream" };
  }
} catch (_) {}

function sumQuery(url: string): number {
  const q = url.indexOf("?");
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
    if (!isNaN(n)) sum += n;
    i = amp + 1;
  }
  return sum;
}

// Build route handlers as a reusable plugin
function addRoutes(app: Elysia) {
  return app
    .get("/pipeline", () => new Response("ok", { headers: { "content-type": "text/plain" } }))

    .all("/baseline11", async ({ request }) => {
      const querySum = sumQuery(request.url);
      if (request.method === "POST") {
        const body = await request.text();
        let total = querySum;
        const n = parseInt(body.trim(), 10);
        if (!isNaN(n)) total += n;
        return new Response(String(total), { headers: { "content-type": "text/plain" } });
      }
      return new Response(String(querySum), { headers: { "content-type": "text/plain" } });
    })

    .get("/json", () => {
      const items = datasetItems.map((d: any) => ({
        id: d.id, name: d.name, category: d.category,
        price: d.price, quantity: d.quantity, active: d.active,
        tags: d.tags, rating: d.rating,
        total: Math.round(d.price * d.quantity * 100) / 100,
      }));
      const body = JSON.stringify({ items, count: items.length });
      return new Response(body, {
        headers: { "content-type": "application/json", "content-length": String(Buffer.byteLength(body)) },
      });
    })

    .get("/compression", () => {
      const compressed = Bun.gzipSync(largeJsonBuf, { level: 1 });
      return new Response(compressed, {
        headers: {
          "content-type": "application/json",
          "content-encoding": "gzip",
          "content-length": String(compressed.length),
        },
      });
    })

    .get("/db", ({ request }) => {
      if (!dbStmt) return new Response("DB not available", { status: 500 });
      try {
        let min = 10, max = 50;
        const url = request.url;
        const qIdx = url.indexOf("?");
        if (qIdx !== -1) {
          const qs = url.slice(qIdx + 1);
          for (const pair of qs.split("&")) {
            const eq = pair.indexOf("=");
            if (eq === -1) continue;
            const k = pair.slice(0, eq), v = pair.slice(eq + 1);
            if (k === "min") min = parseFloat(v) || 10;
            else if (k === "max") max = parseFloat(v) || 50;
          }
        }
        const rows = dbStmt.all(min, max) as any[];
        const items = rows.map((r: any) => ({
          id: r.id, name: r.name, category: r.category,
          price: r.price, quantity: r.quantity, active: r.active === 1,
          tags: JSON.parse(r.tags),
          rating: { score: r.rating_score, count: r.rating_count },
        }));
        const body = JSON.stringify({ items, count: items.length });
        return new Response(body, {
          headers: { "content-type": "application/json", "content-length": String(Buffer.byteLength(body)) },
        });
      } catch (e: any) {
        return new Response(e.message || "db error", { status: 500 });
      }
    })

    .get("/async-db", async ({ request }) => {
      if (!pgPool) {
        return new Response('{"items":[],"count":0}', {
          headers: { "content-type": "application/json" },
        });
      }
      let min = 10, max = 50;
      const url = request.url;
      const qIdx = url.indexOf("?");
      if (qIdx !== -1) {
        const qs = url.slice(qIdx + 1);
        for (const pair of qs.split("&")) {
          const eq = pair.indexOf("=");
          if (eq === -1) continue;
          const k = pair.slice(0, eq), v = pair.slice(eq + 1);
          if (k === "min") min = parseFloat(v) || 10;
          else if (k === "max") max = parseFloat(v) || 50;
        }
      }
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
        return new Response(body, {
          headers: { "content-type": "application/json", "content-length": String(Buffer.byteLength(body)) },
        });
      } catch (e) {
        return new Response('{"items":[],"count":0}', {
          headers: { "content-type": "application/json" },
        });
      }
    })

    .post("/upload", async ({ request }) => {
      const ab = await request.arrayBuffer();
      return new Response(String(ab.byteLength), {
        headers: { "content-type": "text/plain" },
      });
    })

    .get("/static/:filename", ({ params: { filename } }) => {
      const sf = staticFiles[filename];
      if (sf) {
        return new Response(sf.buf, {
          headers: { "content-type": sf.ct, "content-length": String(sf.buf.length) },
        });
      }
      return new Response("Not found", { status: 404 });
    })

    // Catch-all for unknown routes
    .all("*", () => new Response("Not found", { status: 404 }));
}

// HTTP server on port 8080
const httpApp = addRoutes(new Elysia());
httpApp.listen({ port: 8080, reusePort: true });
