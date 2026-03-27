package com.httparena;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.annotation.PostConstruct;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.file.Files;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.Properties;

@RestController
public class BenchmarkController {

    private final ObjectMapper mapper = new ObjectMapper();
    private List<Map<String, Object>> dataset;
    private byte[] largeJsonResponse;
    private boolean dbAvailable = false;
    private final Map<String, byte[]> staticFiles = new ConcurrentHashMap<>();
    private static final String DB_QUERY = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50";
    private static final String PG_QUERY = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50";
    private static final ThreadLocal<Connection> tlConn = new ThreadLocal<>();
    private HikariDataSource pgPool;
    private static final Map<String, String> MIME_TYPES = Map.of(
        ".css", "text/css", ".js", "application/javascript", ".html", "text/html",
        ".woff2", "font/woff2", ".svg", "image/svg+xml", ".webp", "image/webp", ".json", "application/json"
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
        dbAvailable = new File("/data/benchmark.db").exists();
        // Initialize PostgreSQL connection pool from DATABASE_URL
        String dbUrl = System.getenv("DATABASE_URL");
        if (dbUrl != null && !dbUrl.isEmpty()) {
            try {
                URI uri = new URI(dbUrl.replace("postgres://", "postgresql://"));
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

    @GetMapping(value = "/pipeline", produces = MediaType.TEXT_PLAIN_VALUE)
    public String pipeline() {
        return "ok";
    }

    @GetMapping(value = "/baseline11", produces = MediaType.TEXT_PLAIN_VALUE)
    public String baselineGet(@RequestParam Map<String, String> params) {
        return String.valueOf(sumParams(params));
    }

    @PostMapping(value = "/baseline11", produces = MediaType.TEXT_PLAIN_VALUE)
    public String baselinePost(@RequestParam Map<String, String> params, @RequestBody String body) {
        int sum = sumParams(params);
        try {
            sum += Integer.parseInt(body.trim());
        } catch (NumberFormatException ignored) {}
        return String.valueOf(sum);
    }

    @GetMapping(value = "/baseline2", produces = MediaType.TEXT_PLAIN_VALUE)
    public String baseline2(@RequestParam Map<String, String> params) {
        return String.valueOf(sumParams(params));
    }

    @GetMapping(value = "/compression", produces = MediaType.APPLICATION_JSON_VALUE)
    public org.springframework.http.ResponseEntity<byte[]> compression() throws IOException {
        java.io.ByteArrayOutputStream baos = new java.io.ByteArrayOutputStream();
        java.util.zip.GZIPOutputStream gzip = new java.util.zip.GZIPOutputStream(baos) {{
            def.setLevel(java.util.zip.Deflater.BEST_SPEED);
        }};
        gzip.write(largeJsonResponse);
        gzip.close();
        return org.springframework.http.ResponseEntity.ok()
            .header("Content-Type", "application/json")
            .header("Content-Encoding", "gzip")
            .body(baos.toByteArray());
    }

    @GetMapping(value = "/json", produces = MediaType.APPLICATION_JSON_VALUE)
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

    @PostMapping(value = "/upload", produces = MediaType.TEXT_PLAIN_VALUE)
    public String upload(InputStream body) throws IOException {
        byte[] buf = new byte[65536];
        long total = 0;
        int n;
        while ((n = body.read(buf)) != -1) {
            total += n;
        }
        return String.valueOf(total);
    }

    @GetMapping(value = "/db", produces = MediaType.APPLICATION_JSON_VALUE)
    public byte[] db(@RequestParam(defaultValue = "10") double min, @RequestParam(defaultValue = "50") double max) throws IOException {
        if (!dbAvailable) {
            return "{\"items\":[],\"count\":0}".getBytes();
        }
        Connection conn = getDbConnection();
        List<Map<String, Object>> items = new ArrayList<>();
        try {
            PreparedStatement stmt = conn.prepareStatement(DB_QUERY);
            stmt.setDouble(1, min);
            stmt.setDouble(2, max);
            ResultSet rs = stmt.executeQuery();
            while (rs.next()) {
                Map<String, Object> item = new LinkedHashMap<>();
                item.put("id", rs.getLong("id"));
                item.put("name", rs.getString("name"));
                item.put("category", rs.getString("category"));
                item.put("price", rs.getDouble("price"));
                item.put("quantity", rs.getInt("quantity"));
                item.put("active", rs.getInt("active") == 1);
                item.put("tags", mapper.readValue(rs.getString("tags"), new TypeReference<List<String>>() {}));
                item.put("rating", Map.of("score", rs.getDouble("rating_score"), "count", rs.getInt("rating_count")));
                items.add(item);
            }
            rs.close();
            stmt.close();
        } catch (SQLException e) {
            return "{\"items\":[],\"count\":0}".getBytes();
        }
        return mapper.writeValueAsBytes(Map.of("items", items, "count", items.size()));
    }

    private Connection getDbConnection() {
        Connection conn = tlConn.get();
        if (conn == null) {
            try {
                Properties props = new Properties();
                props.setProperty("open_mode", "1");  // SQLITE_OPEN_READONLY
                conn = DriverManager.getConnection("jdbc:sqlite:/data/benchmark.db", props);
                conn.createStatement().execute("PRAGMA mmap_size=268435456");
                tlConn.set(conn);
            } catch (SQLException e) {
                throw new RuntimeException(e);
            }
        }
        return conn;
    }

    @GetMapping(value = "/async-db", produces = MediaType.APPLICATION_JSON_VALUE)
    public byte[] asyncDb(@RequestParam(defaultValue = "10") double min, @RequestParam(defaultValue = "50") double max) throws IOException {
        if (pgPool == null) {
            return "{\"items\":[],\"count\":0}".getBytes();
        }
        try (Connection conn = pgPool.getConnection()) {
            PreparedStatement stmt = conn.prepareStatement(PG_QUERY);
            stmt.setDouble(1, min);
            stmt.setDouble(2, max);
            ResultSet rs = stmt.executeQuery();
            List<Map<String, Object>> items = new ArrayList<>();
            while (rs.next()) {
                Map<String, Object> item = new LinkedHashMap<>();
                item.put("id", rs.getLong("id"));
                item.put("name", rs.getString("name"));
                item.put("category", rs.getString("category"));
                item.put("price", rs.getDouble("price"));
                item.put("quantity", rs.getInt("quantity"));
                item.put("active", rs.getBoolean("active"));
                item.put("tags", mapper.readValue(rs.getString("tags"), new TypeReference<List<String>>() {}));
                item.put("rating", Map.of("score", rs.getDouble("rating_score"), "count", rs.getInt("rating_count")));
                items.add(item);
            }
            rs.close();
            stmt.close();
            return mapper.writeValueAsBytes(Map.of("items", items, "count", items.size()));
        } catch (SQLException e) {
            return "{\"items\":[],\"count\":0}".getBytes();
        }
    }

    @GetMapping("/static/{filename}")
    public org.springframework.http.ResponseEntity<byte[]> staticFile(@PathVariable String filename) {
        byte[] data = staticFiles.get(filename);
        if (data == null) {
            return org.springframework.http.ResponseEntity.notFound().build();
        }
        int dot = filename.lastIndexOf('.');
        String ext = dot >= 0 ? filename.substring(dot) : "";
        String ct = MIME_TYPES.getOrDefault(ext, "application/octet-stream");
        return org.springframework.http.ResponseEntity.ok()
            .header("Content-Type", ct)
            .body(data);
    }

    private int sumParams(Map<String, String> params) {
        int sum = 0;
        for (String v : params.values()) {
            try {
                sum += Integer.parseInt(v);
            } catch (NumberFormatException ignored) {}
        }
        return sum;
    }
}
