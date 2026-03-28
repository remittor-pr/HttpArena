const std = @import("std");
const mem = std.mem;
const blitz = @import("blitz");

// ── Handlers ────────────────────────────────────────────────────────

fn handlePipeline(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.rawResponse("HTTP/1.1 200 OK\r\nServer: blitz\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok");
}

fn handleBaseline(req: *blitz.Request, res: *blitz.Response) void {
    var sum: i64 = 0;
    if (req.query) |q| sum = parseQuerySum(q);
    if (req.method == .POST) {
        if (req.body) |body| {
            const trimmed = mem.trim(u8, body, " \t\r\n");
            sum += std.fmt.parseInt(i64, trimmed, 10) catch 0;
        }
    }
    var nb: [32]u8 = undefined;
    _ = res.textBuf(blitz.writeI64(&nb, sum));
}

fn handleUpload(req: *blitz.Request, res: *blitz.Response) void {
    // Must actually read the body — spec requires reading the entire request body
    if (req.body) |body| {
        var nb: [32]u8 = undefined;
        _ = res.textBuf(blitz.writeUsize(&nb, body.len));
    } else {
        _ = res.text("0");
    }
}

fn handleWsUpgrade(req: *blitz.Request, res: *blitz.Response) void {
    if (!blitz.websocket.isUpgradeRequest(req)) {
        _ = res.text("WebSocket endpoint");
        return;
    }
    res.ws_upgraded = true;
}

// ── Helpers ─────────────────────────────────────────────────────────

fn parseQuerySum(query: []const u8) i64 {
    var sum: i64 = 0;
    var it = mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (mem.indexOfScalar(u8, pair, '=')) |eq| {
            sum += std.fmt.parseInt(i64, pair[eq + 1 ..], 10) catch continue;
        }
    }
    return sum;
}

// ── Main ────────────────────────────────────────────────────────────

pub fn main() !void {
    // Set up router
    const alloc = std.heap.c_allocator;
    var router = blitz.Router.init(alloc);

    router.get("/pipeline", handlePipeline);
    router.get("/baseline11", handleBaseline);
    router.post("/baseline11", handleBaseline);
    router.post("/upload", handleUpload);
    router.get("/ws", handleWsUpgrade);

    // Check if io_uring backend is requested
    const use_uring = if (std.posix.getenv("BLITZ_URING")) |val| mem.eql(u8, val, "1") else false;

    if (use_uring) {
        var uring_server = blitz.UringServer.init(&router, .{
            .port = 8080,
            .compression = false,
        });
        uring_server.listen() catch {
            _ = std.posix.write(2, "uring: init failed, falling back to epoll\n") catch {};
            var server = blitz.Server.init(&router, .{
                .port = 8080,
                .keep_alive_timeout = 0,
                .compression = false,
            });
            try server.listen();
            return;
        };
    } else {
        var server = blitz.Server.init(&router, .{
            .port = 8080,
            .keep_alive_timeout = 0,
            .compression = false,
        });
        try server.listen();
    }
}
