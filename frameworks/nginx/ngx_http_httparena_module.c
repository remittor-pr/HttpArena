#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

/* ---------- Pre-loaded data ---------- */

#define MAX_STATIC 32
typedef struct {
    char name[64];
    char ct[64];
    u_char *data;
    size_t len;
} sfile_t;
static sfile_t g_sf[MAX_STATIC];
static ngx_int_t g_sf_n = 0;

/* ---------- Integer parser ---------- */

static int64_t
parse_int(u_char *start, u_char *end)
{
    int64_t n = 0;
    int neg = 0;
    u_char *p = start;
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    if (p < end && *p == '-') { neg = 1; p++; }
    while (p < end && *p >= '0' && *p <= '9') {
        n = n * 10 + (*p - '0');
        p++;
    }
    return neg ? -n : n;
}

/* ---------- Query string sum ---------- */

static int64_t
sum_args(ngx_str_t *args)
{
    if (!args->len) return 0;
    int64_t sum = 0;
    u_char *p = args->data, *end = p + args->len;
    while (p < end) {
        u_char *eq = ngx_strlchr(p, end, '=');
        if (!eq) break;
        u_char *v = eq + 1;
        u_char *amp = ngx_strlchr(v, end, '&');
        if (!amp) amp = end;
        sum += parse_int(v, amp);
        p = (amp < end) ? amp + 1 : end;
    }
    return sum;
}

/* ---------- Response helper ---------- */

static ngx_int_t
send_resp(ngx_http_request_t *r, ngx_uint_t status,
          u_char *ct, size_t ct_len,
          u_char *body, size_t body_len, ngx_int_t copy)
{
    ngx_buf_t *b;
    ngx_chain_t out;

    r->headers_out.status = status;
    r->headers_out.content_type.data = ct;
    r->headers_out.content_type.len = ct_len;
    r->headers_out.content_type_len = ct_len;
    r->headers_out.content_length_n = body_len;

    if (r->method == NGX_HTTP_HEAD) {
        return ngx_http_send_header(r);
    }

    if (copy) {
        b = ngx_create_temp_buf(r->pool, body_len);
        if (!b) return NGX_HTTP_INTERNAL_SERVER_ERROR;
        b->last = ngx_copy(b->last, body, body_len);
    } else {
        b = ngx_calloc_buf(r->pool);
        if (!b) return NGX_HTTP_INTERNAL_SERVER_ERROR;
        b->pos = body;
        b->last = body + body_len;
        b->memory = 1;
    }
    b->last_buf = 1;

    out.buf = b;
    out.next = NULL;

    ngx_int_t rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) return rc;
    return ngx_http_output_filter(r, &out);
}

/* ---------- POST body handler for /baseline11 ---------- */

static void
baseline11_post_handler(ngx_http_request_t *r)
{
    int64_t sum = sum_args(&r->args);

    if (r->request_body && r->request_body->bufs) {
        ngx_buf_t *buf = r->request_body->bufs->buf;
        if (buf && !buf->in_file && buf->pos < buf->last) {
            sum += parse_int(buf->pos, buf->last);
        }
    }

    u_char resp[32];
    u_char *last = ngx_snprintf(resp, sizeof(resp), "%L", sum);

    ngx_int_t rc = send_resp(r, 200,
                              (u_char *)"text/plain", 10,
                              resp, last - resp, 1);
    ngx_http_finalize_request(r, rc);
}

/* ---------- Main request handler ---------- */

static ngx_int_t
ngx_http_httparena_handler(ngx_http_request_t *r)
{
    u_char *uri = r->uri.data;
    size_t uri_len = r->uri.len;

    /* Reject unknown HTTP methods — only allow GET, HEAD, POST */
    if (!(r->method & (NGX_HTTP_GET | NGX_HTTP_POST | NGX_HTTP_HEAD))) {
        ngx_http_discard_request_body(r);
        return send_resp(r, 405,
                         (u_char *)"text/plain", 10,
                         (u_char *)"Method Not Allowed", 18, 1);
    }

    /* /pipeline */
    if (uri_len == 9 && ngx_strncmp(uri, "/pipeline", 9) == 0) {
        ngx_http_discard_request_body(r);
        return send_resp(r, 200,
                         (u_char *)"text/plain", 10,
                         (u_char *)"ok", 2, 0);
    }

    /* /baseline2 */
    if (uri_len == 10 && ngx_strncmp(uri, "/baseline2", 10) == 0) {
        ngx_http_discard_request_body(r);
        int64_t sum = sum_args(&r->args);
        u_char buf[32];
        u_char *last = ngx_snprintf(buf, sizeof(buf), "%L", sum);
        return send_resp(r, 200,
                         (u_char *)"text/plain", 10,
                         buf, last - buf, 1);
    }

    /* /baseline11 */
    if (uri_len == 11 && ngx_strncmp(uri, "/baseline11", 11) == 0) {
        if (r->method == NGX_HTTP_POST) {
            r->request_body_in_single_buf = 1;
            ngx_int_t rc = ngx_http_read_client_request_body(r,
                                                              baseline11_post_handler);
            if (rc >= NGX_HTTP_SPECIAL_RESPONSE) return rc;
            return NGX_DONE;
        }
        ngx_http_discard_request_body(r);
        int64_t sum = sum_args(&r->args);
        u_char buf[32];
        u_char *last = ngx_snprintf(buf, sizeof(buf), "%L", sum);
        return send_resp(r, 200,
                         (u_char *)"text/plain", 10,
                         buf, last - buf, 1);
    }

    /* /static/<filename> */
    if (uri_len > 8 && ngx_strncmp(uri, "/static/", 8) == 0) {
        ngx_http_discard_request_body(r);
        u_char *fname = uri + 8;
        size_t fname_len = uri_len - 8;
        for (ngx_int_t i = 0; i < g_sf_n; i++) {
            size_t nlen = ngx_strlen(g_sf[i].name);
            if (nlen == fname_len &&
                ngx_strncmp(g_sf[i].name, fname, nlen) == 0) {
                return send_resp(r, 200,
                                 (u_char *)g_sf[i].ct, ngx_strlen(g_sf[i].ct),
                                 g_sf[i].data, g_sf[i].len, 0);
            }
        }
        return send_resp(r, 404,
                         (u_char *)"text/plain", 10,
                         (u_char *)"Not Found", 9, 0);
    }

    /* Unknown path — return 404 instead of falling through to nginx default */
    ngx_http_discard_request_body(r);
    return send_resp(r, 404,
                     (u_char *)"text/plain", 10,
                     (u_char *)"Not Found", 9, 1);
}

static void
load_static_files(void)
{
    static const struct { const char *name; const char *ct; } entries[] = {
        {"reset.css",       "text/css"},
        {"layout.css",      "text/css"},
        {"theme.css",       "text/css"},
        {"components.css",  "text/css"},
        {"utilities.css",   "text/css"},
        {"analytics.js",    "application/javascript"},
        {"helpers.js",      "application/javascript"},
        {"app.js",          "application/javascript"},
        {"vendor.js",       "application/javascript"},
        {"router.js",       "application/javascript"},
        {"header.html",     "text/html"},
        {"footer.html",     "text/html"},
        {"regular.woff2",   "font/woff2"},
        {"bold.woff2",      "font/woff2"},
        {"logo.svg",        "image/svg+xml"},
        {"icon-sprite.svg", "image/svg+xml"},
        {"hero.webp",       "image/webp"},
        {"thumb1.webp",     "image/webp"},
        {"thumb2.webp",     "image/webp"},
        {"manifest.json",   "application/json"},
    };
    int n = sizeof(entries) / sizeof(entries[0]);
    for (int i = 0; i < n && g_sf_n < MAX_STATIC; i++) {
        char path[256];
        snprintf(path, sizeof(path), "/data/static/%s", entries[i].name);
        FILE *f = fopen(path, "rb");
        if (!f) continue;
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        u_char *data = malloc(sz);
        if (!data) { fclose(f); continue; }
        fread(data, 1, sz, f);
        fclose(f);
        strncpy(g_sf[g_sf_n].name, entries[i].name, sizeof(g_sf[g_sf_n].name) - 1);
        strncpy(g_sf[g_sf_n].ct, entries[i].ct, sizeof(g_sf[g_sf_n].ct) - 1);
        g_sf[g_sf_n].data = data;
        g_sf[g_sf_n].len = sz;
        g_sf_n++;
    }
}

/* ---------- Module boilerplate ---------- */

static char *
ngx_http_httparena(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_core_loc_conf_t *clcf;
    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
    clcf->handler = ngx_http_httparena_handler;
    return NGX_CONF_OK;
}

static ngx_int_t
ngx_http_httparena_init_module(ngx_cycle_t *cycle)
{
    load_static_files();
    return NGX_OK;
}

static ngx_command_t ngx_http_httparena_commands[] = {
    {
        ngx_string("httparena"),
        NGX_HTTP_LOC_CONF | NGX_CONF_NOARGS,
        ngx_http_httparena,
        0,
        0,
        NULL
    },
    ngx_null_command
};

static ngx_http_module_t ngx_http_httparena_module_ctx = {
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
};

ngx_module_t ngx_http_httparena_module = {
    NGX_MODULE_V1,
    &ngx_http_httparena_module_ctx,
    ngx_http_httparena_commands,
    NGX_HTTP_MODULE,
    NULL,                                /* init master */
    ngx_http_httparena_init_module,      /* init module */
    NULL,                                /* init process */
    NULL,                                /* init thread */
    NULL,                                /* exit thread */
    NULL,                                /* exit process */
    NULL,                                /* exit master */
    NGX_MODULE_V1_PADDING
};
