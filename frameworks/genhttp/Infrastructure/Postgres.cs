using Npgsql;

namespace genhttp.Infrastructure;

public static class Postgres
{

    public static NpgsqlDataSource? OpenPool()
    {
        var dbUrl = Environment.GetEnvironmentVariable("DATABASE_URL");
        if (string.IsNullOrEmpty(dbUrl)) return null;
        try
        {
            var uri = new Uri(dbUrl);
            var userInfo = uri.UserInfo.Split(':');
            var connStr = $"Host={uri.Host};Port={uri.Port};Username={userInfo[0]};Password={userInfo[1]};Database={uri.AbsolutePath.TrimStart('/')};Maximum Pool Size=256;Minimum Pool Size=64;Multiplexing=true;No Reset On Close=true;Max Auto Prepare=4;Auto Prepare Min Usages=1";
            var builder = new NpgsqlDataSourceBuilder(connStr);
            return builder.Build();
        }
        catch { return null; }
    }

}
