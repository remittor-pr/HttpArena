package com.httparena;

import io.vertx.core.*;
import io.vertx.core.buffer.Buffer;
import io.vertx.core.http.*;
import io.vertx.core.net.PemKeyCertOptions;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.ext.web.handler.BodyHandler;

import java.io.*;
import java.nio.file.Files;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

public class MainVerticle extends AbstractVerticle {

    private static final Buffer OK_BUFFER = Buffer.buffer("ok");

    // Shared pre-computed data (loaded once, shared across verticle instances)
    private static final Map<String, byte[]> staticFiles = new ConcurrentHashMap<>();
    private static final Map<String, String> MIME_TYPES = Map.ofEntries(
        Map.entry(".css", "text/css"),
        Map.entry(".js", "application/javascript"),
        Map.entry(".html", "text/html"),
        Map.entry(".woff2", "font/woff2"),
        Map.entry(".svg", "image/svg+xml"),
        Map.entry(".webp", "image/webp"),
        Map.entry(".json", "application/json")
    );

    private static final Object INIT_LOCK = new Object();
    private static volatile boolean dataInitialized = false;

    public static void main(String[] args) {
        int instances = Runtime.getRuntime().availableProcessors();
        VertxOptions vertxOpts = new VertxOptions()
            .setPreferNativeTransport(true)
            .setEventLoopPoolSize(instances);

        Vertx vertx = Vertx.vertx(vertxOpts);

        // Pre-load shared data before deploying verticles
        initSharedData();

        DeploymentOptions deployOpts = new DeploymentOptions().setInstances(instances);
        vertx.deployVerticle(MainVerticle.class.getName(), deployOpts)
            .onSuccess(id -> System.out.println("Deployed " + instances + " instances"))
            .onFailure(err -> {
                err.printStackTrace();
                System.exit(1);
            });
    }

    private static void initSharedData() {
        if (dataInitialized) return;
        synchronized (INIT_LOCK) {
            if (dataInitialized) return;
            try {
                // Static files
                File staticDir = new File("/data/static");
                if (staticDir.isDirectory()) {
                    File[] files = staticDir.listFiles();
                    if (files != null) {
                        for (File sf : files) {
                            if (sf.isFile()) {
                                staticFiles.put(sf.getName(), Files.readAllBytes(sf.toPath()));
                            }
                        }
                    }
                }
            } catch (Exception e) {
                e.printStackTrace();
            }
            dataInitialized = true;
        }
    }

    @Override
    public void start(Promise<Void> startPromise) {
        Router router = Router.router(vertx);

        // Body handler for POST requests — 25MB limit, no disk writes
        router.post().handler(BodyHandler.create()
            .setHandleFileUploads(false)
            .setBodyLimit(25 * 1024 * 1024));

        // Routes
        router.get("/pipeline").handler(this::handlePipeline);
        router.get("/baseline11").handler(this::handleBaselineGet);
        router.post("/baseline11").handler(this::handleBaselinePost);
        router.get("/baseline2").handler(this::handleBaseline2);
        router.get("/static/:filename").handler(this::handleStatic);

        // Catch-all: return 404 for unmatched routes
        router.route().handler(ctx -> ctx.response().setStatusCode(404).end());

        // HTTP/1.1 on port 8080
        HttpServerOptions httpOpts = new HttpServerOptions()
            .setPort(8080)
            .setHost("0.0.0.0")
            .setTcpNoDelay(true)
            .setTcpFastOpen(true)
            .setCompressionSupported(false)
            .setIdleTimeout(0);

        vertx.createHttpServer(httpOpts)
            .requestHandler(router)
            .listen()
            .compose(http -> {
                // HTTP/2 + TLS on port 8443 (if certs exist)
                File cert = new File("/certs/server.crt");
                File key = new File("/certs/server.key");
                if (cert.exists() && key.exists()) {
                    HttpServerOptions httpsOpts = new HttpServerOptions()
                        .setPort(8443)
                        .setHost("0.0.0.0")
                        .setSsl(true)
                        .setUseAlpn(true)
                        .setKeyCertOptions(new PemKeyCertOptions()
                            .setCertPath("/certs/server.crt")
                            .setKeyPath("/certs/server.key"))
                        .setTcpNoDelay(true)
                        .setTcpFastOpen(true)
                        .setCompressionSupported(false)
                        .setIdleTimeout(0);

                    return vertx.createHttpServer(httpsOpts)
                        .requestHandler(router)
                        .listen();
                }
                return Future.succeededFuture();
            })
            .onSuccess(v -> startPromise.complete())
            .onFailure(startPromise::fail);
    }

    private void handlePipeline(RoutingContext ctx) {
        ctx.response()
            .putHeader("content-type", "text/plain")
            .end(OK_BUFFER);
    }

    private void handleBaselineGet(RoutingContext ctx) {
        int sum = sumParams(ctx);
        ctx.response()
            .putHeader("content-type", "text/plain")
            .end(String.valueOf(sum));
    }

    private void handleBaselinePost(RoutingContext ctx) {
        int sum = sumParams(ctx);
        String body = ctx.body().asString();
        if (body != null && !body.isEmpty()) {
            try {
                sum += Integer.parseInt(body.trim());
            } catch (NumberFormatException ignored) {}
        }
        ctx.response()
            .putHeader("content-type", "text/plain")
            .end(String.valueOf(sum));
    }

    private void handleBaseline2(RoutingContext ctx) {
        int sum = sumParams(ctx);
        ctx.response()
            .putHeader("content-type", "text/plain")
            .end(String.valueOf(sum));
    }

    private void handleStatic(RoutingContext ctx) {
        String filename = ctx.pathParam("filename");
        byte[] data = staticFiles.get(filename);
        if (data == null) {
            ctx.response().setStatusCode(404).end();
            return;
        }
        int dot = filename.lastIndexOf('.');
        String ext = dot >= 0 ? filename.substring(dot) : "";
        String ct = MIME_TYPES.getOrDefault(ext, "application/octet-stream");
        ctx.response()
            .putHeader("content-type", ct)
            .end(Buffer.buffer(data));
    }

    private int sumParams(RoutingContext ctx) {
        int sum = 0;
        String a = ctx.request().getParam("a");
        String b = ctx.request().getParam("b");
        if (a != null) try { sum += Integer.parseInt(a); } catch (NumberFormatException ignored) {}
        if (b != null) try { sum += Integer.parseInt(b); } catch (NumberFormatException ignored) {}
        return sum;
    }
}
