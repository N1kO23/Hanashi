package federation

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"math"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// server is a Federation of host behind a test HTTP server that answers its
// key, and queries with who asked and what.
type server struct {
	fed *Federation
	url string
}

func newServer(t *testing.T, host string, resolve map[string]string, edit func(*Options)) *server {
	t.Helper()
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	opts := Options{Host: host, Enabled: true, AnyServer: true, Resolve: resolve}
	if edit != nil {
		edit(&opts)
	}
	s := &server{fed: New(opts, key, "01JB2Y8Q3M7W2V6T0Q9X4C5D6E", nil, slog.New(slog.DiscardHandler))}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == keyPath {
			_ = json.NewEncoder(w).Encode(s.fed.KeyDocument())
			return
		}
		origin, body, err := s.fed.Verify(r)
		var e *Error
		if errors.As(err, &e) {
			if e.RetryAfter > 0 {
				w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(e.RetryAfter.Seconds()))))
			}
			w.WriteHeader(e.Status)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": e.Code, "message": e.Message})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"origin": origin, "body": string(body)})
	}))
	t.Cleanup(srv.Close)
	s.url = srv.URL
	resolve[host] = srv.URL
	return s
}

func TestQueriesAreSignedAndChecked(t *testing.T) {
	resolve := map[string]string{}
	a := newServer(t, "a.test", resolve, nil)
	newServer(t, "b.test", resolve, nil)
	var answer struct{ Origin, Body string }
	if err := a.fed.Query(context.Background(), "b.test", "user", map[string]any{"user": "kumiko@b.test"}, &answer); err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	_ = json.Unmarshal([]byte(answer.Body), &body)
	if answer.Origin != "a.test" || body["destination"] != "b.test" || body["user"] != "kumiko@b.test" {
		t.Fatalf("answer %+v", answer)
	}

	// Its own host, and hosts no other server could have, are not asked.
	for _, host := range []string{"a.test", "localhost", "10.0.0.1", "c.local"} {
		if err := a.fed.Query(context.Background(), host, "user", nil, nil); !errors.Is(err, ErrNotAllowed) {
			t.Errorf("%s: %v", host, err)
		}
	}
	// One that cannot be reached says so.
	resolve["gone.test"] = "http://127.0.0.1:1"
	var unreachable *Unreachable
	if err := a.fed.Query(context.Background(), "gone.test", "user", nil, nil); !errors.As(err, &unreachable) {
		t.Fatalf("gone: %v", err)
	}
}

func TestRequestsNotSignedRightAreRefused(t *testing.T) {
	resolve := map[string]string{}
	a := newServer(t, "a.test", resolve, nil)
	b := newServer(t, "b.test", resolve, nil)
	send := func(body map[string]any, headers func(h http.Header, data []byte)) (int, string) {
		data, _ := json.Marshal(body)
		req, _ := http.NewRequest(http.MethodPost, b.url+Prefix+"query/user", strings.NewReader(string(data)))
		req.Header.Set(headerOrigin, "a.test")
		req.Header.Set(headerKeyID, a.fed.keyID)
		req.Header.Set(headerSignature, base64.StdEncoding.EncodeToString(ed25519.Sign(a.fed.key, data)))
		if headers != nil {
			headers(req.Header, data)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var e struct{ Error string }
		_ = json.NewDecoder(resp.Body).Decode(&e)
		return resp.StatusCode, e.Error
	}
	now := time.Now().UnixMilli()
	good := map[string]any{"origin": "a.test", "destination": "b.test", "ts": now}
	if status, _ := send(good, nil); status != http.StatusOK {
		t.Fatalf("signed right: %d", status)
	}
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	for name, c := range map[string]struct {
		body    map[string]any
		headers func(h http.Header, data []byte)
	}{
		"for another server":                {map[string]any{"origin": "a.test", "destination": "c.test", "ts": now}, nil},
		"sent long ago":                     {map[string]any{"origin": "a.test", "destination": "b.test", "ts": now - 10*60*1000}, nil},
		"from another than the header says": {map[string]any{"origin": "c.test", "destination": "b.test", "ts": now}, nil},
		"unsigned":                          {good, func(h http.Header, _ []byte) { h.Del(headerSignature) }},
		"signed with another key": {good, func(h http.Header, data []byte) {
			h.Set(headerSignature, base64.StdEncoding.EncodeToString(ed25519.Sign(other, data)))
		}},
		"naming a key it does not have": {good, func(h http.Header, _ []byte) { h.Set(headerKeyID, "ed25519:AAAAAAAAAAA") }},
	} {
		if status, code := send(c.body, c.headers); status != http.StatusUnauthorized || code != "not_signed" {
			t.Errorf("%s: %d %s", name, status, code)
		}
	}

	// A server that federates only with others, or not at all.
	resolve2 := map[string]string{"a.test": a.url}
	picky := newServer(t, "b.test", resolve2, func(o *Options) { o.AnyServer, o.Servers = false, map[string]bool{"c.test": true} })
	off := newServer(t, "b.test", map[string]string{"a.test": a.url}, func(o *Options) { o.Enabled = false })
	for name, c := range map[string]struct {
		url    string
		status int
		code   string
	}{
		"not allowed":    {picky.url, http.StatusForbidden, "not_allowed"},
		"federation off": {off.url, http.StatusNotFound, "federation_off"},
	} {
		resolve["b.test"] = c.url
		var e *Error
		err := a.fed.Query(context.Background(), "b.test", "user", nil, nil)
		if !errors.As(err, &e) || e.Status != c.status || e.Code != c.code {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestAddresses(t *testing.T) {
	var answer func(w http.ResponseWriter)
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != wellKnownPath {
			w.WriteHeader(http.StatusTeapot)
			return
		}
		answer(w)
	}))
	defer srv.Close()
	host := strings.TrimPrefix(srv.URL, "https://")
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	for name, c := range map[string]struct {
		answer func(w http.ResponseWriter)
		want   string
		ttl    time.Duration
	}{
		"given": {func(w http.ResponseWriter) {
			_, _ = io.WriteString(w, `{"server": "https://chat.example.org/"}`)
		}, "https://chat.example.org", addressTTL},
		"none, so at the host": {func(w http.ResponseWriter) { w.WriteHeader(http.StatusNotFound) }, srv.URL, addressTTL},
		"not https":            {func(w http.ResponseWriter) { _, _ = io.WriteString(w, `{"server": "http://x.org"}`) }, srv.URL, failedAddressTTL},
		"broken":               {func(w http.ResponseWriter) { w.WriteHeader(http.StatusBadGateway) }, srv.URL, failedAddressTTL},
	} {
		answer = c.answer
		f := New(Options{Host: "a.test", Enabled: true}, key, "", nil, slog.New(slog.DiscardHandler))
		f.public = srv.Client()
		got, _ := f.address(context.Background(), host)
		if got != c.want {
			t.Errorf("%s: %s, want %s", name, got, c.want)
		}
		if ttl := time.Until(f.addresses[host].expires); ttl > c.ttl || ttl < c.ttl-time.Minute {
			t.Errorf("%s: kept for %v", name, ttl)
		}
	}
	// Named in Resolve: not looked up.
	f := New(Options{Host: "a.test", Resolve: map[string]string{"b.test": "http://10.0.0.2:8080"}}, key, "", nil,
		slog.New(slog.DiscardHandler))
	if got, client := f.address(context.Background(), "b.test"); got != "http://10.0.0.2:8080" || client != f.trusted {
		t.Errorf("resolved: %s", got)
	}
}

func TestRetries(t *testing.T) {
	for failures, want := range map[int]time.Duration{
		1: time.Second, 2: 2 * time.Second, 3: 4 * time.Second, 12: 2048 * time.Second, 13: time.Hour, 100: time.Hour,
	} {
		if got := retryAfter(failures); got != want {
			t.Errorf("after %d: %v, want %v", failures, got, want)
		}
	}
}

func TestLimiter(t *testing.T) {
	l := newLimiter(2, 3) // Two a second, three saved up.
	now := time.Now()
	for i := range 3 {
		if _, ok := l.take("a.test", now); !ok {
			t.Fatalf("refused the %dth of a burst", i+1)
		}
	}
	wait, ok := l.take("a.test", now)
	if ok || wait != 500*time.Millisecond {
		t.Fatalf("the fourth: %v, %v", wait, ok)
	}
	// Each server has its own; and they fill up again.
	if _, ok := l.take("b.test", now); !ok {
		t.Fatal("another server refused")
	}
	if _, ok := l.take("a.test", now.Add(600*time.Millisecond)); !ok {
		t.Fatal("refused after waiting")
	}
}

func TestRequestsOverTheLimit(t *testing.T) {
	resolve := map[string]string{}
	a := newServer(t, "a.test", resolve, nil)
	newServer(t, "b.test", resolve, func(o *Options) { o.Rate, o.Burst = 0.5, 2 })
	query := func() error { return a.fed.Query(context.Background(), "b.test", "user", nil, nil) }
	for range 2 {
		if err := query(); err != nil {
			t.Fatal(err)
		}
	}
	var e *Error
	if err := query(); !errors.As(err, &e) || e.Status != http.StatusTooManyRequests || e.RetryAfter < time.Second {
		t.Fatalf("over the limit: %v", err)
	}

	// So many under way at once, and no more.
	f := New(Options{Host: "c.test", Enabled: true, InFlight: 1}, a.fed.key, "", nil, slog.New(slog.DiscardHandler))
	release, err := f.Admit()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Admit(); !errors.As(err, &e) || e.Status != http.StatusServiceUnavailable {
		t.Fatalf("the second at once: %v", err)
	}
	release()
	if _, err := f.Admit(); err != nil {
		t.Fatalf("after the first: %v", err)
	}
}

func TestOnlyListedServers(t *testing.T) {
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	listed := Options{Host: "a.test", Enabled: true, Servers: map[string]bool{"b.test": true}}
	f := New(listed, key, "", nil, slog.New(slog.DiscardHandler))
	for host, want := range map[string]bool{"b.test": true, "c.test": false, "a.test": false} {
		if got := f.Allowed(host); got != want {
			t.Errorf("%s: %v", host, got)
		}
	}
	// Any server only when asked for; never with federation off.
	any := New(Options{Host: "a.test", Enabled: true, AnyServer: true}, key, "", nil, slog.New(slog.DiscardHandler))
	off := New(Options{Host: "a.test", AnyServer: true}, key, "", nil, slog.New(slog.DiscardHandler))
	if !any.Allowed("c.test") || off.Allowed("c.test") {
		t.Errorf("any server: %v, off: %v", any.Allowed("c.test"), off.Allowed("c.test"))
	}
}
