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
import java.net.URI;
import java.nio.file.Files;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

@RestController
public class BenchmarkController {

    private final ObjectMapper mapper = new ObjectMapper();
    private List<Map<String, Object>> dataset;
    private byte[] largeJsonResponse;
    private Connection dbConn;
    private PreparedStatement dbStmt;
    private HikariDataSource pgPool;
    private static final String PG_QUERY = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50";
    private final Map<String, byte[]> staticFiles = new ConcurrentHashMap<>();
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
        // Open SQLite database
        File dbFile = new File("/data/benchmark.db");
        if (dbFile.exists()) {
            try {
                dbConn = DriverManager.getConnection("jdbc:sqlite:file:/data/benchmark.db?mode=ro&immutable=1");
                dbConn.createStatement().execute("PRAGMA mmap_size=268435456");
                dbStmt = dbConn.prepareStatement(
                    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50");
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

    @PostMapping(value = "/upload", produces = MediaType.TEXT_PLAIN_VALUE)
    public String upload(@RequestBody byte[] body) {
        return String.valueOf(body.length);
    }

    @GetMapping(value = "/baseline2", produces = MediaType.TEXT_PLAIN_VALUE)
    public String baseline2(@RequestParam Map<String, String> params) {
        return String.valueOf(sumParams(params));
    }

    @GetMapping(value = "/db", produces = MediaType.APPLICATION_JSON_VALUE)
    public org.springframework.http.ResponseEntity<byte[]> db(
            @RequestParam(value = "min", defaultValue = "10") double minPrice,
            @RequestParam(value = "max", defaultValue = "50") double maxPrice) {
        if (dbStmt == null)
            return org.springframework.http.ResponseEntity.status(500).build();
        try {
            List<Map<String, Object>> items;
            synchronized (dbStmt) {
                dbStmt.setDouble(1, minPrice);
                dbStmt.setDouble(2, maxPrice);
                ResultSet rs = dbStmt.executeQuery();
                com.fasterxml.jackson.core.type.TypeReference<List<String>> listType = new com.fasterxml.jackson.core.type.TypeReference<>() {};
                items = new ArrayList<>();
                while (rs.next()) {
                    List<String> tags = mapper.readValue(rs.getString(7), listType);
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
            }
            return org.springframework.http.ResponseEntity.ok()
                .header("Content-Type", "application/json")
                .body(mapper.writeValueAsBytes(Map.of("items", items, "count", items.size())));
        } catch (Exception e) {
            return org.springframework.http.ResponseEntity.status(500).build();
        }
    }

    @GetMapping(value = "/async-db", produces = MediaType.APPLICATION_JSON_VALUE)
    public org.springframework.http.ResponseEntity<byte[]> asyncDb(
            @RequestParam(value = "min", defaultValue = "10") double minPrice,
            @RequestParam(value = "max", defaultValue = "50") double maxPrice) {
        if (pgPool == null)
            return org.springframework.http.ResponseEntity.ok()
                .header("Content-Type", "application/json")
                .body("{\"items\":[],\"count\":0}".getBytes());
        try (Connection conn = pgPool.getConnection()) {
            PreparedStatement stmt = conn.prepareStatement(PG_QUERY);
            stmt.setDouble(1, minPrice);
            stmt.setDouble(2, maxPrice);
            ResultSet rs = stmt.executeQuery();
            com.fasterxml.jackson.core.type.TypeReference<List<String>> listType = new com.fasterxml.jackson.core.type.TypeReference<>() {};
            List<Map<String, Object>> items = new ArrayList<>();
            while (rs.next()) {
                List<String> tags = mapper.readValue(rs.getString(7), listType);
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
            return org.springframework.http.ResponseEntity.ok()
                .header("Content-Type", "application/json")
                .body(mapper.writeValueAsBytes(Map.of("items", items, "count", items.size())));
        } catch (Exception e) {
            return org.springframework.http.ResponseEntity.ok()
                .header("Content-Type", "application/json")
                .body("{\"items\":[],\"count\":0}".getBytes());
        }
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

    @GetMapping(value = "/compression", produces = MediaType.APPLICATION_JSON_VALUE)
    public byte[] compression() {
        return largeJsonResponse;
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
