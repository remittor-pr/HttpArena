package com.httparena;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.annotation.PostConstruct;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;

import java.io.File;
import java.io.IOException;
import java.util.*;

@RestController
public class BenchmarkController {

    private final ObjectMapper mapper = new ObjectMapper();
    private List<Map<String, Object>> dataset;

    @PostConstruct
    public void init() throws IOException {
        String path = System.getenv("DATASET_PATH");
        if (path == null) path = "/data/dataset.json";
        File f = new File(path);
        if (f.exists()) {
            dataset = mapper.readValue(f, new TypeReference<>() {});
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
