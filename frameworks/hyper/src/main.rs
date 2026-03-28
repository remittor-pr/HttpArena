use std::collections::HashMap;
use std::convert::Infallible;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::{io, thread};

use http::header::{CONTENT_TYPE, SERVER};
use http::{HeaderValue, Request, Response, StatusCode};
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Empty, Full};
use hyper::body::{Bytes, Incoming};
use hyper::server::conn::{http1, http2};
use hyper::service::service_fn;
use hyper_util::rt::{TokioIo, TokioExecutor};
use rustls::ServerConfig;

use socket2::{Domain, SockAddr, Socket};
use tokio::net::TcpListener;
use tokio::runtime;
use tokio_rustls::TlsAcceptor;

static SERVER_HEADER: HeaderValue = HeaderValue::from_static("hyper");
static TEXT_PLAIN: HeaderValue = HeaderValue::from_static("text/plain");
static OK_BODY: &[u8] = b"ok";

struct StaticFile {
    data: Bytes,
    content_type: HeaderValue,
}

fn load_static_files() -> HashMap<String, StaticFile> {
    let mime_types: HashMap<&str, &str> = [
        (".css", "text/css"), (".js", "application/javascript"), (".html", "text/html"),
        (".woff2", "font/woff2"), (".svg", "image/svg+xml"), (".webp", "image/webp"), (".json", "application/json"),
    ].into();
    let mut files = HashMap::new();
    if let Ok(entries) = std::fs::read_dir("/data/static") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if let Ok(data) = std::fs::read(entry.path()) {
                let ext = name.rfind('.').map(|i| &name[i..]).unwrap_or("");
                let ct = mime_types.get(ext).unwrap_or(&"application/octet-stream");
                files.insert(name, StaticFile {
                    data: Bytes::from(data),
                    content_type: HeaderValue::from_str(ct).unwrap(),
                });
            }
        }
    }
    files
}

fn parse_query_params(query: Option<&str>) -> i64 {
    let mut sum: i64 = 0;
    if let Some(q) = query {
        for pair in q.split('&') {
            if let Some(val) = pair.split('=').nth(1) {
                if let Ok(n) = val.parse::<i64>() {
                    sum += n;
                }
            }
        }
    }
    sum
}

fn pipeline_response() -> Result<Response<BoxBody<Bytes, Infallible>>, http::Error> {
    Response::builder()
        .header(SERVER, SERVER_HEADER.clone())
        .header(CONTENT_TYPE, TEXT_PLAIN.clone())
        .body(Full::from(OK_BODY).boxed())
}

fn baseline_get(query: Option<&str>) -> Result<Response<BoxBody<Bytes, Infallible>>, http::Error> {
    let sum = parse_query_params(query);
    let body = sum.to_string();
    Response::builder()
        .header(SERVER, SERVER_HEADER.clone())
        .header(CONTENT_TYPE, TEXT_PLAIN.clone())
        .body(Full::from(body).boxed())
}

async fn baseline_post(
    query: Option<&str>,
    req: Request<Incoming>,
) -> Result<Response<BoxBody<Bytes, Infallible>>, http::Error> {
    let mut sum = parse_query_params(query);
    let body_bytes = req.collect().await.map(|b| b.to_bytes()).unwrap_or_default();
    if let Ok(s) = std::str::from_utf8(&body_bytes) {
        if let Ok(n) = s.trim().parse::<i64>() {
            sum += n;
        }
    }
    let body = sum.to_string();
    Response::builder()
        .header(SERVER, SERVER_HEADER.clone())
        .header(CONTENT_TYPE, TEXT_PLAIN.clone())
        .body(Full::from(body).boxed())
}

fn not_found() -> Result<Response<BoxBody<Bytes, Infallible>>, http::Error> {
    Response::builder()
        .status(StatusCode::NOT_FOUND)
        .body(Empty::new().boxed())
}

fn create_socket(addr: SocketAddr) -> io::Result<Socket> {
    let domain = Domain::IPV4;
    let socket = Socket::new(domain, socket2::Type::STREAM, None)?;
    #[cfg(unix)]
    socket.set_reuse_port(true)?;
    socket.set_reuse_address(true)?;
    socket.set_nodelay(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&SockAddr::from(addr))?;
    socket.listen(4096)?;
    Ok(socket)
}

fn load_tls_config() -> Option<Arc<ServerConfig>> {
    let cert_path = std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
    let key_path = std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());
    let cert_file = std::fs::File::open(&cert_path).ok()?;
    let key_file = std::fs::File::open(&key_path).ok()?;
    let certs: Vec<_> = rustls_pemfile::certs(&mut io::BufReader::new(cert_file))
        .filter_map(|r| r.ok())
        .collect();
    let key = rustls_pemfile::private_key(&mut io::BufReader::new(key_file)).ok()??;
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .ok()?;
    config.alpn_protocols = vec![b"h2".to_vec()];
    Some(Arc::new(config))
}

fn main() -> io::Result<()> {
    let threads = num_cpus::get();
    let statics = Arc::new(load_static_files());
    let tls_config = load_tls_config();

    for _ in 1..threads {
        let sf = statics.clone();
        let tls = tls_config.clone();
        thread::spawn(move || {
            let rt = runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            let local = tokio::task::LocalSet::new();
            local.block_on(&rt, serve(sf, tls)).unwrap();
        });
    }

    let rt = runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let local = tokio::task::LocalSet::new();
    local.block_on(&rt, serve(statics, tls_config))
}

fn static_response(sf: &StaticFile) -> Result<Response<BoxBody<Bytes, Infallible>>, http::Error> {
    Response::builder()
        .header(SERVER, SERVER_HEADER.clone())
        .header(CONTENT_TYPE, sf.content_type.clone())
        .body(Full::from(sf.data.clone()).boxed())
}

fn make_service(statics: Arc<HashMap<String, StaticFile>>) -> impl Fn(Request<Incoming>) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<Response<BoxBody<Bytes, Infallible>>, http::Error>> + Send>> + Clone {
    move |req: Request<Incoming>| {
        let statics = statics.clone();
        Box::pin(async move {
            let path = req.uri().path();
            let query = req.uri().query().map(|q| q.to_string());
            match path {
                "/pipeline" => pipeline_response(),
                "/baseline11" => {
                    if req.method() == http::Method::POST {
                        baseline_post(query.as_deref(), req).await
                    } else {
                        baseline_get(query.as_deref())
                    }
                }
                "/baseline2" => baseline_get(query.as_deref()),
                p if p.starts_with("/static/") => {
                    let name = &p[8..];
                    match statics.get(name) {
                        Some(sf) => static_response(sf),
                        None => not_found(),
                    }
                }
                _ => not_found(),
            }
        })
    }
}

async fn serve(statics: Arc<HashMap<String, StaticFile>>, tls_config: Option<Arc<ServerConfig>>) -> io::Result<()> {
    let addr = SocketAddr::from((Ipv4Addr::UNSPECIFIED, 8080));
    let socket = create_socket(addr)?;
    let listener = TcpListener::from_std(socket.into())?;

    let mut http = http1::Builder::new();
    http.pipeline_flush(true);

    // Spawn H2 TLS listener if certs available
    if let Some(tls_cfg) = tls_config {
        let acceptor = TlsAcceptor::from(tls_cfg);
        let h2_addr = SocketAddr::from((Ipv4Addr::UNSPECIFIED, 8443));
        let h2_socket = create_socket(h2_addr)?;
        let h2_listener = TcpListener::from_std(h2_socket.into())?;
        let sf = statics.clone();
        tokio::task::spawn_local(async move {
            loop {
                let (stream, _) = match h2_listener.accept().await {
                    Ok(s) => s,
                    Err(_) => continue,
                };
                let acceptor = acceptor.clone();
                let sf = sf.clone();
                tokio::task::spawn_local(async move {
                    let tls_stream = match acceptor.accept(stream).await {
                        Ok(s) => s,
                        Err(_) => return,
                    };
                    let io = TokioIo::new(tls_stream);
                    let svc = make_service(sf);
                    let _ = http2::Builder::new(TokioExecutor::new())
                        .serve_connection(io, service_fn(svc))
                        .await;
                });
            }
        });
    }

    loop {
        let (stream, _) = listener.accept().await?;
        let http = http.clone();
        let sf = statics.clone();
        tokio::task::spawn_local(async move {
            let io = TokioIo::new(stream);
            let svc = make_service(sf);
            let _ = http.serve_connection(io, service_fn(svc)).await;
        });
    }
}
