package httparenahandler

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/caddyserver/caddy/v2/caddyconfig/httpcaddyfile"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
)

func init() {
	caddy.RegisterModule(Handler{})
	httpcaddyfile.RegisterHandlerDirective("httparena", parseCaddyfile)
}

type staticFile struct {
	data        []byte
	contentType string
}

type Handler struct {
	staticFiles map[string]staticFile
}

func (Handler) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID:  "http.handlers.httparena",
		New: func() caddy.Module { return new(Handler) },
	}
}

func (h *Handler) Provision(ctx caddy.Context) error {
	// Load static files
	mimeTypes := map[string]string{
		".css": "text/css", ".js": "application/javascript", ".html": "text/html",
		".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp", ".json": "application/json",
	}
	h.staticFiles = make(map[string]staticFile)
	entries, err := os.ReadDir("/data/static")
	if err == nil {
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			d, err := os.ReadFile(filepath.Join("/data/static", e.Name()))
			if err != nil {
				continue
			}
			ext := filepath.Ext(e.Name())
			ct, ok := mimeTypes[ext]
			if !ok {
				ct = "application/octet-stream"
			}
			h.staticFiles[e.Name()] = staticFile{data: d, contentType: ct}
		}
	}

	return nil
}

func sumQuery(r *http.Request) int64 {
	var sum int64
	for _, vals := range r.URL.Query() {
		for _, v := range vals {
			if n, err := strconv.ParseInt(v, 10, 64); err == nil {
				sum += n
			}
		}
	}
	return sum
}

func rejectBadMethod(w http.ResponseWriter, r *http.Request) bool {
	switch r.Method {
	case http.MethodGet, http.MethodHead, http.MethodPost:
		return false
	default:
		w.Header().Set("Allow", "GET, HEAD, POST")
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return true
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request, next caddyhttp.Handler) error {
	path := r.URL.Path

	// Reject unknown HTTP methods with 405
	if rejectBadMethod(w, r) {
		return nil
	}

	switch path {
	case "/pipeline":
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Server", "caddy")
		w.Write([]byte("ok"))
		return nil

	case "/baseline2":
		sum := sumQuery(r)
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Server", "caddy")
		fmt.Fprint(w, sum)
		return nil

	case "/baseline11":
		sum := sumQuery(r)
		if r.Method == "POST" && r.Body != nil {
			body, _ := io.ReadAll(r.Body)
			if n, err := strconv.ParseInt(string(body), 10, 64); err == nil {
				sum += n
			}
		}
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Server", "caddy")
		fmt.Fprint(w, sum)
		return nil

	}

	if strings.HasPrefix(path, "/static/") {
		name := path[8:]
		if sf, ok := h.staticFiles[name]; ok {
			w.Header().Set("Content-Type", sf.contentType)
			w.Header().Set("Server", "caddy")
			w.Header().Set("Content-Length", strconv.Itoa(len(sf.data)))
			w.Write(sf.data)
			return nil
		}
		http.NotFound(w, r)
		return nil
	}

	http.NotFound(w, r)
	return nil
}

func (h *Handler) UnmarshalCaddyfile(d *caddyfile.Dispenser) error {
	return nil
}

func parseCaddyfile(h httpcaddyfile.Helper) (caddyhttp.MiddlewareHandler, error) {
	var handler Handler
	err := handler.UnmarshalCaddyfile(h.Dispenser)
	return &handler, err
}

var (
	_ caddyhttp.MiddlewareHandler = (*Handler)(nil)
	_ caddyfile.Unmarshaler       = (*Handler)(nil)
)
