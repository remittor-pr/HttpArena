using Microsoft.Extensions.FileProviders;

using ServiceStack;
using ServiceStack.Benchmarks;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls("http://*:8080");
builder.Logging.ClearProviders();

var app = builder.Build();

if (Directory.Exists("/data/static"))
{
    app.UseStaticFiles(new StaticFileOptions
    {
        FileProvider = new PhysicalFileProvider("/data/static"),
        RequestPath = "/static"
    });
}

app.UseServiceStack(new AppHost(), options => {
    options.MapEndpoints();
});

await app.RunAsync();