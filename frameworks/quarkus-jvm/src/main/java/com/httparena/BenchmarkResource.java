package com.httparena;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.smallrye.common.annotation.NonBlocking;
import io.vertx.core.buffer.Buffer;
import jakarta.annotation.PostConstruct;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

@Path("/")
public class BenchmarkResource {

    private static final Buffer OK_BUFFER = Buffer.buffer("ok".getBytes(StandardCharsets.UTF_8));

    private final ObjectMapper mapper = new ObjectMapper();
    private List<Map<String, Object>> dataset;
    private byte[] largeJsonResponse;
    private boolean dbAvailable = false;
    private static final String DB_QUERY = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50";
    private static final String PG_QUERY = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50";
    private static final ThreadLocal<Connection> tlConn = new ThreadLocal<>();
    private static final ThreadLocal<PreparedStatement> tlStmt = new ThreadLocal<>();
    private HikariDataSource pgPool;
    private final Map<String, byte[]> staticFiles = new ConcurrentHashMap<>();
    private static final Map<String, String> MIME_TYPES = Map.ofEntries(
        Map.entry(".css", "text/css"),
        Map.entry(".js", "application/javascript"),
        Map.entry(".html", "text/html"),
        Map.entry(".woff2", "font/woff2"),
        Map.entry(".svg", "image/svg+xml"),
        Map.entry(".webp", "image/webp"),
        Map.entry(".json", "application/json")
    );

    @PostConstruct
    public void init() throws IOException {
        String path = System.getenv("DATASET_PATH");
        if (path == null) path = "/data/dataset.json";
        File f = new File(path);
        if (f.exists()) {
            dataset = mapper.readValue(f, new TypeReference<>() {});
        }
        File largef = new File("/data/dataset-large.json");
        if (largef.exists()) {
            List<Map<String, Object>> largeDataset = mapper.readValue(largef, new TypeReference<>() {});
            List<Map<String, Object>> largeItems = new ArrayList<>(largeDataset.size());
            for (Map<String, Object> item : largeDataset) {
                Map<String, Object> processed = new LinkedHashMap<>(item);
                double price = ((Number) item.get("price")).doubleValue();
                int quantity = ((Number) item.get("quantity")).intValue();
                processed.put("total", Math.round(price * quantity * 100.0) / 100.0);
                largeItems.add(processed);
            }
            largeJsonResponse = mapper.writeValueAsBytes(Map.of("items", largeItems, "count", largeItems.size()));
        }
        // Check SQLite database availability
        File dbFile = new File("/data/benchmark.db");
        if (dbFile.exists()) {
            try {
                Connection test = DriverManager.getConnection("jdbc:sqlite:file:/data/benchmark.db?mode=ro&immutable=1");
                test.close();
                dbAvailable = true;
            } catch (Exception ignored) {}
        }
        // Initialize PostgreSQL connection pool from DATABASE_URL
        String pgUrl = System.getenv("DATABASE_URL");
        if (pgUrl != null && !pgUrl.isEmpty()) {
            try {
                URI uri = new URI(pgUrl.replace("postgres://", "postgresql://"));
                String host = uri.getHost();
                int port = uri.getPort() > 0 ? uri.getPort() : 5432;
                String database = uri.getPath().substring(1);
                String[] userInfo = uri.getUserInfo().split(":");
                HikariConfig config = new HikariConfig();
                config.setDriverClassName("org.postgresql.Driver");
                config.setJdbcUrl("jdbc:postgresql://" + host + ":" + port + "/" + database);
                config.setUsername(userInfo[0]);
                config.setPassword(userInfo.length > 1 ? userInfo[1] : "");
                config.setMaximumPoolSize(64);
                config.setMinimumIdle(16);
                pgPool = new HikariDataSource(config);
            } catch (Exception ignored) {}
        }
        // Pre-load static files
        File staticDir = new File("/data/static");
        if (staticDir.isDirectory()) {
            File[] files = staticDir.listFiles();
            if (files != null) {
                for (File sf : files) {
                    if (sf.isFile()) {
                        try {
                            staticFiles.put(sf.getName(), Files.readAllBytes(sf.toPath()));
                        } catch (IOException ignored) {}
                    }
                }
            }
        }
    }

    @GET
    @Path("/pipeline")
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public Buffer pipeline() {
        return OK_BUFFER;
    }

    @GET
    @Path("/baseline11")
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public String baselineGet(@QueryParam("a") String a, @QueryParam("b") String b) {
        return String.valueOf(sumParams(a, b));
    }

    @POST
    @Path("/baseline11")
    @Consumes(MediaType.TEXT_PLAIN)
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public String baselinePost(@QueryParam("a") String a, @QueryParam("b") String b, String body) {
        int sum = sumParams(a, b);
        try {
            sum += Integer.parseInt(body.trim());
        } catch (NumberFormatException ignored) {}
        return String.valueOf(sum);
    }

    @POST
    @Path("/upload")
    @Produces(MediaType.TEXT_PLAIN)
    public String upload(InputStream body) throws IOException {
        byte[] buf = new byte[65536];
        long total = 0;
        int n;
        while ((n = body.read(buf)) != -1) {
            total += n;
        }
        return String.valueOf(total);
    }

    @GET
    @Path("/baseline2")
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public String baseline2(@QueryParam("a") String a, @QueryParam("b") String b) {
        return String.valueOf(sumParams(a, b));
    }

    @GET
    @Path("/db")
    @Produces(MediaType.APPLICATION_JSON)
    public jakarta.ws.rs.core.Response db(@QueryParam("min") String minParam, @QueryParam("max") String maxParam) {
        if (!dbAvailable)
            return jakarta.ws.rs.core.Response.ok("{\"items\":[],\"count\":0}".getBytes())
                .header("Content-Type", "application/json").build();
        PreparedStatement stmt = getDbStmt();
        if (stmt == null)
            return jakarta.ws.rs.core.Response.ok("{\"items\":[],\"count\":0}".getBytes())
                .header("Content-Type", "application/json").build();
        double minPrice = 10.0, maxPrice = 50.0;
        if (minParam != null) try { minPrice = Double.parseDouble(minParam); } catch (NumberFormatException ignored) {}
        if (maxParam != null) try { maxPrice = Double.parseDouble(maxParam); } catch (NumberFormatException ignored) {}
        try {
            stmt.setDouble(1, minPrice);
            stmt.setDouble(2, maxPrice);
            ResultSet rs = stmt.executeQuery();
            List<Map<String, Object>> items = new ArrayList<>();
            while (rs.next()) {
                List<String> tags = mapper.readValue(rs.getString(7), new TypeReference<>() {});
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("id", rs.getInt(1));
                row.put("name", rs.getString(2));
                row.put("category", rs.getString(3));
                row.put("price", rs.getDouble(4));
                row.put("quantity", rs.getInt(5));
                row.put("active", rs.getInt(6) == 1);
                row.put("tags", tags);
                row.put("rating", Map.of("score", rs.getDouble(8), "count", rs.getInt(9)));
                items.add(row);
            }
            rs.close();
            return jakarta.ws.rs.core.Response.ok(mapper.writeValueAsBytes(Map.of("items", items, "count", items.size())))
                .header("Content-Type", "application/json").build();
        } catch (Exception e) {
            return jakarta.ws.rs.core.Response.ok("{\"items\":[],\"count\":0}".getBytes())
                .header("Content-Type", "application/json").build();
        }
    }

    @GET
    @Path("/async-db")
    @Produces(MediaType.APPLICATION_JSON)
    public jakarta.ws.rs.core.Response asyncDb(@QueryParam("min") String minParam, @QueryParam("max") String maxParam) {
        if (pgPool == null)
            return jakarta.ws.rs.core.Response.ok("{\"items\":[],\"count\":0}".getBytes())
                .header("Content-Type", "application/json").build();
        double minPrice = 10.0, maxPrice = 50.0;
        if (minParam != null) try { minPrice = Double.parseDouble(minParam); } catch (NumberFormatException ignored) {}
        if (maxParam != null) try { maxPrice = Double.parseDouble(maxParam); } catch (NumberFormatException ignored) {}
        try (Connection conn = pgPool.getConnection()) {
            PreparedStatement stmt = conn.prepareStatement(PG_QUERY);
            stmt.setDouble(1, minPrice);
            stmt.setDouble(2, maxPrice);
            ResultSet rs = stmt.executeQuery();
            List<Map<String, Object>> items = new ArrayList<>();
            while (rs.next()) {
                List<String> tags = mapper.readValue(rs.getString(7), new TypeReference<>() {});
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("id", rs.getInt(1));
                row.put("name", rs.getString(2));
                row.put("category", rs.getString(3));
                row.put("price", rs.getDouble(4));
                row.put("quantity", rs.getInt(5));
                row.put("active", rs.getBoolean(6));
                row.put("tags", tags);
                row.put("rating", Map.of("score", rs.getDouble(8), "count", rs.getInt(9)));
                items.add(row);
            }
            rs.close();
            stmt.close();
            return jakarta.ws.rs.core.Response.ok(mapper.writeValueAsBytes(Map.of("items", items, "count", items.size())))
                .header("Content-Type", "application/json").build();
        } catch (Exception e) {
            return jakarta.ws.rs.core.Response.ok("{\"items\":[],\"count\":0}".getBytes())
                .header("Content-Type", "application/json").build();
        }
    }

    @GET
    @Path("/json")
    @Produces(MediaType.APPLICATION_JSON)
    @NonBlocking
    public Map<String, Object> json() {
        List<Map<String, Object>> items = new ArrayList<>(dataset.size());
        for (Map<String, Object> item : dataset) {
            Map<String, Object> processed = new LinkedHashMap<>(item);
            double price = ((Number) item.get("price")).doubleValue();
            int quantity = ((Number) item.get("quantity")).intValue();
            processed.put("total", Math.round(price * quantity * 100.0) / 100.0);
            items.add(processed);
        }
        return Map.of("items", items, "count", items.size());
    }

    @GET
    @Path("/compression")
    @Produces(MediaType.APPLICATION_JSON)
    @NonBlocking
    public byte[] compression() {
        return largeJsonResponse;
    }

    @GET
    @Path("/static/{filename}")
    @NonBlocking
    public jakarta.ws.rs.core.Response staticFile(@PathParam("filename") String filename) {
        byte[] data = staticFiles.get(filename);
        if (data == null) {
            return jakarta.ws.rs.core.Response.status(404).build();
        }
        int dot = filename.lastIndexOf('.');
        String ext = dot >= 0 ? filename.substring(dot) : "";
        String ct = MIME_TYPES.getOrDefault(ext, "application/octet-stream");
        return jakarta.ws.rs.core.Response.ok(data).header("Content-Type", ct).build();
    }

    private PreparedStatement getDbStmt() {
        PreparedStatement stmt = tlStmt.get();
        if (stmt != null) return stmt;
        try {
            Connection conn = DriverManager.getConnection("jdbc:sqlite:file:/data/benchmark.db?mode=ro&immutable=1");
            conn.createStatement().execute("PRAGMA mmap_size=268435456");
            stmt = conn.prepareStatement(DB_QUERY);
            tlConn.set(conn);
            tlStmt.set(stmt);
        } catch (Exception e) {
            return null;
        }
        return stmt;
    }

    private int sumParams(String a, String b) {
        int sum = 0;
        if (a != null) try { sum += Integer.parseInt(a); } catch (NumberFormatException ignored) {}
        if (b != null) try { sum += Integer.parseInt(b); } catch (NumberFormatException ignored) {}
        return sum;
    }
}
