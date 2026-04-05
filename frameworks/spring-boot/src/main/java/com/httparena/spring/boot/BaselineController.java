package com.httparena.spring.boot;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class BaselineController {
    @GetMapping("/baseline11")
    public String baseline(@RequestParam("a") int a, @RequestParam("b") int b) {
        return String.valueOf(a + b);
    }

    @PostMapping("/baseline11")
    public String baselinePost(@RequestParam("a") int a, @RequestParam("b") int b, @RequestBody String body) {
        int bodyNumber = Integer.parseInt(body);
        return String.valueOf(a + b + bodyNumber);
    }

    @GetMapping("/baseline2")
    public String baseline2(@RequestParam("a") int a, @RequestParam("b") int b) {
        return String.valueOf(a + b);
    }
}
