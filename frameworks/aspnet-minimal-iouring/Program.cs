using System.Security.Cryptography.X509Certificates;

using Microsoft.AspNetCore.ResponseCompression;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.Caching.Memory;

// Turn on the io_uring socket engine with kernel-side SQPOLL before the
// runtime wires up System.Net.Sockets. This AppContext switch must be
// set before any Socket is created — doing it at the very top of Main
// guarantees ordering.
AppContext.SetSwitch("System.Net.Sockets.UseIoUringSqPoll", true);

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Services.AddMemoryCache();

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

builder.WebHost.ConfigureKestrel(options =>
{
    options.Limits.Http2.MaxStreamsPerConnection = 256;
    options.Limits.Http2.InitialConnectionWindowSize = 2 * 1024 * 1024;
    options.Limits.Http2.InitialStreamWindowSize = 1024 * 1024;

    options.ListenAnyIP(8080, lo =>
    {
        lo.Protocols = HttpProtocols.Http1;
    });

    if (hasCert)
    {
        options.ListenAnyIP(8443, lo =>
        {
            lo.Protocols = HttpProtocols.Http1AndHttp2AndHttp3;
            lo.UseHttps(X509Certificate2.CreateFromPemFile(certPath, keyPath));
        });

        // HTTP/1.1-only TLS listener for the json-tls profile. Kestrel
        // advertises http/1.1 via ALPN so HTTP/1.1-only clients (wrk) negotiate
        // correctly and never upgrade to h2.
        options.ListenAnyIP(8081, lo =>
        {
            lo.Protocols = HttpProtocols.Http1;
            lo.UseHttps(X509Certificate2.CreateFromPemFile(certPath, keyPath));
        });
    }
});

// Explicit provider registration — the custom benaadams/runtime io_uring
// branch is based on a .NET 11 snapshot that predates ZstandardCompressionOptions
// in System.IO.Compression. AddResponseCompression()'s default factory tries
// to instantiate all three providers (Brotli, Gzip, Zstandard) and throws
// TypeLoadException at startup when Zstandard's type is missing. Register
// only the two providers the json-comp profile exercises to avoid that.
builder.Services.AddResponseCompression(options =>
{
    options.Providers.Add<BrotliCompressionProvider>();
    options.Providers.Add<GzipCompressionProvider>();
});

var app = builder.Build();

app.UseResponseCompression();

app.Use((ctx, next) =>
{
    ctx.Response.Headers.Server = "aspnet-minimal-iouring";
    return next();
});

AppData.Load();

// Report whether the custom io_uring runtime overlay is actually in effect,
// visible in `docker logs httparena-bench-aspnet-minimal-iouring` for sanity.
var ioUringEnv = Environment.GetEnvironmentVariable("DOTNET_SYSTEM_NET_SOCKETS_IO_URING");
Console.WriteLine($"[io_uring] DOTNET_SYSTEM_NET_SOCKETS_IO_URING={ioUringEnv ?? "(not set)"}");
var socketAsm = typeof(System.Net.Sockets.Socket).Assembly;
var ioUringType = socketAsm.GetTypes()
    .FirstOrDefault(t => t.Name.Contains("IOUring", StringComparison.OrdinalIgnoreCase));
Console.WriteLine(ioUringType != null
    ? $"[io_uring] Runtime type found: {ioUringType.FullName} — io_uring is ACTIVE"
    : "[io_uring] No io_uring types in runtime — falling back to epoll");

app.MapGet("/pipeline", Handlers.Text);

app.MapGet("/baseline11", Handlers.Sum);
app.MapPost("/baseline11", Handlers.SumBody);
app.MapGet("/baseline2", Handlers.Sum);

app.MapPost("/upload", Handlers.Upload);
app.MapGet("/json/{count}", Handlers.Json);
app.MapGet("/async-db", Handlers.AsyncDatabase);

// ── CRUD endpoints ─────────────────────────────────────────────────────────
// Realistic REST API: paginated list, cached single-item read, create, update.
// In-process IMemoryCache with 1s TTL on single-item reads, invalidated on PUT.

app.MapGet("/crud/items", Handlers.CrudList);
app.MapGet("/crud/items/{id:int}", Handlers.CrudRead);
app.MapPost("/crud/items", Handlers.CrudCreate);
app.MapPut("/crud/items/{id:int}", Handlers.CrudUpdate);

app.MapStaticAssets();

app.Run();
