use serde::Serialize;
use wtx::{
  codec::i64_string,
  collection::{ArrayVectorU8, Vector},
  http::{
    Header, KnownHeaderName, ReqResBuffer, StatusCode,
    server_framework::{
      JsonReply, PathOwned, Router, ServerFrameworkBuilder, State, VerbatimParams, get,
    },
  },
  misc::Wrapper,
  rng::{ChaCha20, CryptoSeedableRng},
  sync::Arc,
};

#[derive(Clone, wtx::ConnAux)]
struct ConnAux {
  dataset: Arc<Vector<DatasetItem>>,
}

#[tokio::main]
async fn main() -> wtx::Result<()> {
  let dataset = load_dataset();
  let router = Router::paths(wtx::paths!(
    ("/baseline2", get(endpoint_baseline2)),
    ("/health", get(endpoint_health)),
    ("/json/{count}", get(endpoint_json)),
  ))?;
  // HttpArena's baseline-h2c / json-h2c profiles run h2load against
  // http://localhost:8082 with prior-knowledge h2c — no TLS. wtx's .tokio
  // entrypoint routes through http2_tokio(), which speaks HTTP/2 cleartext
  // from the connection preface and rejects HTTP/1.1 by construction. That
  // satisfies validate.sh's anti-cheat: the h2c port must not dual-serve h1.
  ServerFrameworkBuilder::new(ChaCha20::from_std_random()?, router)
    .with_conn_aux(move |_| Ok(ConnAux { dataset: dataset.clone() }))
    .tokio(
      "0.0.0.0:8082",
      |_error| {},
      |_| Ok(()),
      |_| Ok(()),
      |_error| {},
    )
    .await
}

async fn endpoint_baseline2(
  state: State<'_, ConnAux, (), ReqResBuffer>,
) -> wtx::Result<VerbatimParams> {
  // h2load sends GET /baseline2?a=1&b=1 with empty body. Sum integer
  // values from the query string; non-integer values silently skip
  // (matches the reference nginx/h2o/actix contracts).
  let mut sum: i64 = 0;
  for (_k, v) in state.req.rrd.uri.query_params() {
    if let Ok(n) = v.parse::<i64>() {
      sum = sum.wrapping_add(n);
    }
  }
  state.req.rrd.clear();
  state.req.rrd.body.extend_from_copyable_slice(i64_string(sum).as_bytes())?;
  state.req.rrd.headers.push_from_iter(Header::from_name_and_value(
    KnownHeaderName::Server.into(),
    ["wtx"],
  ))?;
  state.req.rrd.headers.push_from_iter(Header::from_name_and_value(
    KnownHeaderName::ContentType.into(),
    ["text/plain"],
  ))?;
  Ok(VerbatimParams(StatusCode::Ok))
}

async fn endpoint_health() {}

async fn endpoint_json(
  state: State<'_, ConnAux, (), ReqResBuffer>,
  PathOwned(count): PathOwned<usize>,
) -> wtx::Result<JsonReply> {
  // Contract: GET /json/{count}?m={multiplier}
  //   - Take first `count` items from /data/dataset.json (clamped to len)
  //   - For each item, compute total = price × quantity × m
  //   - Serialize {items, count} as JSON per request (no cache — tuned
  //     rules in docs/test-profiles/h1/isolated/json-processing forbid
  //     pre-computed response caches).
  let m: i64 = state
    .req
    .rrd
    .uri
    .query_params()
    .find(|(k, _)| *k == "m")
    .and_then(|(_, v)| v.parse().ok())
    .unwrap_or(1);
  let dataset_len = state.conn_aux.dataset.len();
  let clamped = if count > dataset_len { dataset_len } else { count };
  let m_f = m as f64;
  // Drop the request headers/body before composing the response so client
  // request headers (user-agent, accept, …) don't echo back to the caller.
  state.req.rrd.clear();
  let items = state.conn_aux.dataset.iter().take(clamped).map(move |el| {
    Ok(ProcessedItem {
      id: el.id,
      name: &el.name,
      category: &el.category,
      price: el.price,
      quantity: el.quantity,
      active: el.active,
      tags: ArrayVectorU8::from_iterator(el.tags.iter().map(|el| el.as_str()))?,
      rating: RatingOut { score: el.rating.score, count: el.rating.count },
      total: el.price * (el.quantity as f64) * m_f,
    })
  });
  let resp = JsonResponse { count: clamped, items: Wrapper(items) };
  serde_json::to_writer(&mut state.req.rrd.body, &resp).unwrap_or_default();
  state.req.rrd.headers.push_from_iter(Header::from_name_and_value(
    KnownHeaderName::Server.into(),
    ["wtx"],
  ))?;
  Ok(JsonReply(StatusCode::Ok))
}

fn load_dataset() -> Arc<Vector<DatasetItem>> {
  let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
  Arc::new(match std::fs::read_to_string(&path) {
    Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
    Err(_) => Vector::new(),
  })
}

#[derive(serde::Deserialize)]
struct DatasetItem {
  id: i64,
  name: String,
  category: String,
  price: f64,
  quantity: i64,
  active: bool,
  tags: ArrayVectorU8<String, 6>,
  rating: Rating,
}

#[derive(serde::Serialize)]
#[serde(bound = "E: Serialize")]
struct JsonResponse<E, I>
where
  I: Clone + Iterator<Item = wtx::Result<E>>,
  E: Serialize,
{
  items: Wrapper<I>,
  count: usize,
}

#[derive(serde::Serialize)]
struct ProcessedItem<'any> {
  id: i64,
  name: &'any str,
  category: &'any str,
  price: f64,
  quantity: i64,
  active: bool,
  tags: ArrayVectorU8<&'any str, 6>,
  rating: RatingOut,
  total: f64,
}

#[derive(serde::Deserialize)]
struct Rating {
  score: f64,
  count: i64,
}

#[derive(serde::Serialize)]
struct RatingOut {
  score: f64,
  count: i64,
}
