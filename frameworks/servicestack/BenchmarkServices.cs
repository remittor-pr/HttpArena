namespace ServiceStack.Benchmarks;

using System.Text.Json;
using Microsoft.Data.Sqlite;
using Npgsql;
using ServiceStack;

public class BenchmarkServices : Service
{
    private static readonly List<DatasetItem>? Items = LoadItems();
    
    private static readonly byte[]? LargeJson = LoadLargeJsonBytes();
    
    static List<DatasetItem>? LoadItems()
    {
        var path = Resolve("/data/dataset.json", "../../../../../../data/dataset.json");
        if (path == null) return null;
        
        return JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(path));
    }

    static byte[]? LoadLargeJsonBytes()
    {      
        var jsonOptions = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        };
        
        var largePath = "/data/dataset-large.json";
        
        if (File.Exists(largePath))
        {
            var largeItems = JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(largePath), jsonOptions);
            
            if (largeItems != null)
            {
                var processed = largeItems.Select(d => new ProcessedItem
                {
                    Id = d.Id, Name = d.Name, Category = d.Category,
                    Price = d.Price, Quantity = d.Quantity, Active = d.Active,
                    Tags = d.Tags, Rating = d.Rating,
                    Total = Math.Round(d.Price * d.Quantity, 2)
                }).ToList();
                
                return JsonSerializer.SerializeToUtf8Bytes(new { items = processed, count = processed.Count }, jsonOptions);
            }
        }

        return null;
    }

    static string? Resolve(string primary, string fallback)
        => File.Exists(primary) ? primary : File.Exists(fallback) ? fallback : null;

    // ── /baseline11 ───────────────────────────────────────────────────────────────
    public HttpResult Get(Baseline11Get req) => ToResult(req.A + req.B);

    public async Task<HttpResult> Post(Baseline11Post req)
    {
        return ToResult(req.A + req.B + int.Parse(await Request!.GetRawBodyAsync()));
    }

    public HttpResult Get(Baseline2Get req) => ToResult(req.A + req.B);

    // ── /pipeline ─────────────────────────────────────────────────────────────
    public object Get(PipelineGet _)
    {
        Response!.ContentType = "text/plain";
        return "ok";
    }

    // ── /upload ───────────────────────────────────────────────────────────────
    public async Task<HttpResult> Post(UploadPost _)
    {
        using var ms = new MemoryStream();
        await Request!.InputStream.CopyToAsync(ms);
        return ToResult(ms.Length.ToString());
    }

    // ── /compression ──────────────────────────────────────────────────────────
    public byte[] Get(CompressionGet _)
    {
        Response!.ContentType = "application/json";
        return LargeJson;
    }

    // ── /json ─────────────────────────────────────────────────────────────────
    public object Get(JsonGet _)
    {
        if (Items == null) return new ListWithCount<ProcessedItem>(new());

        var processed = Items.ConvertAll(d => d.ToProcessed());
        return new ListWithCount<ProcessedItem>(processed);
    }

    // ── /db (SQLite) ──────────────────────────────────────────────────────────
    public ListWithCount<ProcessedItem> Get(DbGet req)
    {
        var conn = TryResolve<SqliteConnection>();
        if (conn == null) return new ListWithCount<ProcessedItem>(new());

        using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE price BETWEEN @min AND @max LIMIT 50";
        cmd.Parameters.AddWithValue("@min", req.Min);
        cmd.Parameters.AddWithValue("@max", req.Max);

        using var reader = cmd.ExecuteReader();
        var items = new List<ProcessedItem>();

        while (reader.Read())
        {
            items.Add(new ProcessedItem
            {
                Id       = reader.GetInt32(0),
                Name     = reader.GetString(1),
                Category = reader.GetString(2),
                Price    = reader.GetDouble(3),
                Quantity = reader.GetInt32(4),
                Active   = reader.GetInt32(5) == 1,
                Tags     = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
                Rating   = new RatingInfo
                {
                    Score = reader.GetDouble(7),
                    Count = reader.GetInt32(8)
                }
            });
        }

        return new ListWithCount<ProcessedItem>(items);
    }

    // ── /async-db (PostgreSQL) ────────────────────────────────────────────────
    public async Task<ListWithCount<object>> Get(AsyncDbGet req)
    {
        var ds = TryResolve<NpgsqlDataSource>();
        if (ds == null) return new ListWithCount<object>(new());

        await using var cmd = ds.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50");
        cmd.Parameters.AddWithValue((double)req.Min);
        cmd.Parameters.AddWithValue((double)req.Max);

        await using var reader = await cmd.ExecuteReaderAsync();
        var items = new List<object>();

        while (await reader.ReadAsync())
        {
            items.Add(new
            {
                id       = reader.GetInt32(0),
                name     = reader.GetString(1),
                category = reader.GetString(2),
                price    = reader.GetDouble(3),
                quantity = reader.GetInt32(4),
                active   = reader.GetBoolean(5),
                tags     = JsonSerializer.Deserialize<List<string>>(reader.GetString(6)),
                rating   = new { score = reader.GetDouble(7), count = reader.GetInt32(8) }
            });
        }

        return new ListWithCount<object>(items);
    }

    private HttpResult ToResult<T>(T data)
    {
        return new HttpResult(data.ToString(), MimeTypes.PlainText);
    }
    
}