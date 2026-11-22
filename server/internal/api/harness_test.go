package api_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/oklog/ulid/v2"

	"hanashi/server/internal/api"
	"hanashi/server/internal/config"
	"hanashi/server/internal/federation"
	"hanashi/server/internal/hub"
	"hanashi/server/internal/media"
	"hanashi/server/internal/protocol"
	"hanashi/server/internal/push"
	"hanashi/server/internal/store"
	"hanashi/server/internal/testdb"
)

const testHost = "test.local"

type serverOption func(*config.Config)

func withLeaseDuration(d time.Duration) serverOption {
	return func(c *config.Config) { c.LeaseDuration = d }
}

func withRegistration(mode config.Registration, codes ...string) serverOption {
	return func(c *config.Config) {
		c.Registration = mode
		for _, code := range codes {
			c.InviteCodes[code] = true
		}
	}
}

func withKlipyAPIKey(key string) serverOption {
	return func(c *config.Config) { c.KlipyAPIKey = key }
}

// stores holds each running test server's store (by base URL), for tests that
// are not about how people became contacts.
var stores sync.Map

// databases holds each running test server's DSN (by base URL), for tests that
// look at or set up its database directly.
var databases sync.Map

// startServer runs the API on a real HTTP server backed by a fresh database.
func startServer(t *testing.T, opts ...serverOption) string {
	t.Helper()
	return startServerWithLog(t, slog.New(slog.DiscardHandler), opts...)
}

// logBuffer collects log output; the server writes from many goroutines.
type logBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *logBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *logBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// startServerLogging is startServer with everything logged, at debug level.
func startServerLogging(t *testing.T, opts ...serverOption) (string, *logBuffer) {
	t.Helper()
	logs := &logBuffer{}
	log := slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	return startServerWithLog(t, log, opts...), logs
}

func startServerWithLog(t *testing.T, log *slog.Logger, opts ...serverOption) string {
	t.Helper()
	dsn := testdb.NewDatabase(t)
	st, err := store.Open(context.Background(), dsn, false, 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		Host:           testHost,
		DataDir:        t.TempDir(),
		Registration:   config.RegistrationOpen,
		InviteCodes:    map[string]bool{},
		MaxUploadBytes: 1000,
		DatabaseDSN:    dsn,
		SourceURL:      config.DefaultSourceURL,
	}
	for _, opt := range opts {
		opt(&cfg)
	}
	ms, err := media.NewStore(cfg.MediaDir())
	if err != nil {
		t.Fatal(err)
	}
	h := hub.New()
	// Test push services run on loopback.
	pusher, err := push.Setup(context.Background(), st, h, "mailto:admin@"+testHost, log,
		push.Options{AllowPrivate: true, MinInterval: 10 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	fedOpts := federation.OptionsOf(cfg)
	fedOpts.AllowPrivate = true
	fed, err := federation.Setup(context.Background(), st, fedOpts, log)
	if err != nil {
		t.Fatal(err)
	}
	handler := api.New(cfg, st, h, ms, pusher, fed, log)
	srv := httptest.NewServer(handler)
	ctx, stop := context.WithCancel(context.Background())
	go fed.Run(ctx)
	go handler.Run(ctx)
	stores.Store(srv.URL, st)
	databases.Store(srv.URL, dsn)
	t.Cleanup(func() {
		stop()
		stores.Delete(srv.URL)
		databases.Delete(srv.URL)
		h.CloseAll()
		srv.Close()
		st.Close()
	})
	return srv.URL
}

// apiError is a non-200 response.
type apiError struct {
	Status int
	Code   string `json:"error"`
	// Server is the other server it is about, if it says.
	Server string `json:"server"`
}

func (e *apiError) Error() string { return fmt.Sprintf("%d %s", e.Status, e.Code) }

func statusOf(err error) int {
	if e, ok := err.(*apiError); ok {
		return e.Status
	}
	return 0
}

func codeOf(err error) string {
	if e, ok := err.(*apiError); ok {
		return e.Code
	}
	return ""
}

// device is one signed-in device of one user.
type device struct {
	t        *testing.T
	base     string
	UserID   string
	Token    string
	DeviceID string
}

func register(t *testing.T, base, name string) *device {
	t.Helper()
	d := &device{t: t, base: base}
	if err := d.auth("/auth/register", name, "laptop"); err != nil {
		t.Fatalf("register %s: %v", name, err)
	}
	return d
}

func login(t *testing.T, base, name, deviceName string) *device {
	t.Helper()
	d := &device{t: t, base: base}
	if err := d.auth("/auth/login", name, deviceName); err != nil {
		t.Fatalf("login %s: %v", name, err)
	}
	return d
}

func (d *device) auth(path, name, deviceName string) error {
	var res protocol.AuthResult
	err := d.do("POST", path, map[string]any{
		"name": name, "password": "password123", "deviceName": deviceName, "platform": "test",
	}, &res)
	d.UserID, d.Token, d.DeviceID = res.UserID, res.Token, res.DeviceID
	return err
}

func (d *device) do(method, path string, body, out any) error {
	var reader io.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		reader = bytes.NewReader(data)
	}
	req, _ := http.NewRequest(method, d.base+path, reader)
	req.Header.Set("Content-Type", "application/json")
	if d.Token != "" {
		req.Header.Set("Authorization", "Bearer "+d.Token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		d.t.Fatal(err)
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(res.Body)
	if res.StatusCode != http.StatusOK {
		e := &apiError{Status: res.StatusCode}
		_ = json.Unmarshal(data, e)
		return e
	}
	if out != nil {
		if err := json.Unmarshal(data, out); err != nil {
			d.t.Fatalf("decoding %s: %v (%s)", path, err, data)
		}
	}
	return nil
}

func (d *device) must(method, path string, body, out any) {
	d.t.Helper()
	if err := d.do(method, path, body, out); err != nil {
		d.t.Fatalf("%s %s: %v", method, path, err)
	}
}

// fakeMLS stands in for MLS bytes: the server never parses them.
var fakeMLS = base64.StdEncoding.EncodeToString([]byte("opaque mls bytes"))

// setContactStates writes contact rows directly, with no events.
func (d *device) setContactStates(rows ...[3]string) {
	d.t.Helper()
	st, _ := stores.Load(d.base)
	err := st.(*store.Store).AppendEvents(context.Background(), func(tx *store.Tx) (func(), error) {
		for _, row := range rows {
			if err := tx.SetContactState(row[0], row[1], row[2]); err != nil {
				return nil, err
			}
		}
		return nil, nil
	})
	if err != nil {
		d.t.Fatal(err)
	}
}

// makeContact makes d and user contacts, as if it had happened long ago.
func (d *device) makeContact(user string) {
	d.t.Helper()
	d.setContactStates([3]string{d.UserID, user, store.ContactAccepted}, [3]string{user, d.UserID, store.ContactAccepted})
}

func newGroupBody() map[string]any {
	return map[string]any{"epoch": 1, "groupInfo": fakeMLS}
}

// createConversation makes a group of d and members, or with an empty name,
// the direct chat of d and one other person. They become d's contacts first.
// The server keeps no name.
func (d *device) createConversation(name string, members ...string) protocol.ConversationInfo {
	d.t.Helper()
	for _, m := range members {
		d.makeContact(m)
	}
	body := map[string]any{"id": ulid.Make().String(), "members": members, "mls": newGroupBody()}
	if name == "" {
		body["direct"] = true
	}
	var info protocol.ConversationInfo
	d.must("POST", "/conversations", body, &info)
	return info
}

// lease acquires the commit lease for conv and returns its ID and epoch.
func (d *device) lease(conv string) (string, int64) {
	d.t.Helper()
	var l struct {
		LeaseID string
		Epoch   int64
	}
	d.must("POST", "/conversations/"+conv+"/lease", map[string]any{}, &l)
	return l.LeaseID, l.Epoch
}

func commitBody(leaseID string, epoch int64, welcomes ...map[string]any) map[string]any {
	return map[string]any{"leaseId": leaseID, "epoch": epoch, "mls": fakeMLS, "groupInfo": fakeMLS, "welcomes": welcomes}
}

// addMember adds user to a group the way clients do: under a lease, with a commit.
func (d *device) addMember(conv, user string) error {
	d.makeContact(user)
	leaseID, epoch := d.lease(conv)
	return d.do("POST", "/conversations/"+conv+"/members", map[string]any{"user": user, "commit": commitBody(leaseID, epoch)}, nil)
}

// envelope builds an encrypted-looking v3 envelope. Tests put the text in
// "ct" as plain base64; the server cannot tell the difference.
func envelope(conv, from, device, text string) map[string]any {
	return map[string]any{
		"v": 3, "id": ulid.Make().String(), "conv": conv, "from": from, "device": device,
		"ts": time.Now().UnixMilli(), "type": "mls.app",
		"body": map[string]any{"epoch": 1, "mls": fakeMLS, "ct": base64.StdEncoding.EncodeToString([]byte(text))},
	}
}

// textEnvelope makes a message for the conversation's current epoch (when
// the device can see it).
func (d *device) textEnvelope(conv, text string) map[string]any {
	env := envelope(conv, d.UserID, d.DeviceID, text)
	var group struct{ Epoch int64 }
	if d.do("GET", "/conversations/"+conv+"/group-info", nil, &group) == nil {
		env["body"].(map[string]any)["epoch"] = group.Epoch
	}
	return env
}

// sendREST posts a message over HTTP (the bot/script path) and returns its seq.
func (d *device) sendREST(conv, text string) int64 {
	d.t.Helper()
	var res struct{ Seq int64 }
	d.must("POST", "/messages", d.textEnvelope(conv, text), &res)
	return res.Seq
}

func (d *device) syncSince(cursor int64) protocol.SyncPage {
	d.t.Helper()
	var page protocol.SyncPage
	d.must("GET", fmt.Sprintf("/sync?since=%d", cursor), nil, &page)
	return page
}

func (d *device) snapshot() protocol.SyncSnapshot {
	d.t.Helper()
	var snap protocol.SyncSnapshot
	d.must("GET", "/sync", nil, &snap)
	return snap
}

// socket is an authenticated WebSocket with a queue of received frames.
type socket struct {
	t      *testing.T
	ws     *websocket.Conn
	frames chan map[string]any
	closed chan struct{}
	// Presence frames come and go with every connection; tests that are
	// not about them never see them.
	presence chan map[string]any
	pending  []map[string]any // Frames skipped while waiting for an ack.
}

func (d *device) connect() *socket {
	d.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(d.base, "http")+"/ws", nil)
	if err != nil {
		d.t.Fatal(err)
	}
	ws.SetReadLimit(1 << 20)
	s := &socket{
		t: d.t, ws: ws, frames: make(chan map[string]any, 1000), closed: make(chan struct{}),
		presence: make(chan map[string]any, 1000),
	}
	go func() {
		defer close(s.closed)
		for {
			_, data, err := ws.Read(context.Background())
			if err != nil {
				return
			}
			var frame map[string]any
			if json.Unmarshal(data, &frame) != nil {
				continue
			}
			if frame["type"] == "presence" {
				select {
				case s.presence <- frame:
				default:
				}
				continue
			}
			s.frames <- frame
		}
	}()
	s.send(map[string]any{"type": "auth", "token": d.Token})
	if f := s.next(); f["type"] != "ready" {
		d.t.Fatalf("expected ready, got %v", f)
	}
	d.t.Cleanup(func() { ws.CloseNow() })
	return s
}

func (s *socket) send(frame map[string]any) {
	data, _ := json.Marshal(frame)
	if err := s.ws.Write(context.Background(), websocket.MessageText, data); err != nil {
		s.t.Fatal(err)
	}
}

func (s *socket) next() map[string]any {
	s.t.Helper()
	if len(s.pending) > 0 {
		f := s.pending[0]
		s.pending = s.pending[1:]
		return f
	}
	select {
	case f := <-s.frames:
		return f
	case <-time.After(5 * time.Second):
		s.t.Fatal("timed out waiting for a frame")
		return nil
	}
}

// nextOfType skips frames of other types (e.g. an event arriving before its ack).
func (s *socket) nextOfType(typ string) map[string]any {
	s.t.Helper()
	for {
		if f := s.next(); f["type"] == typ {
			return f
		}
	}
}

func (s *socket) nextEvent() protocol.SyncEvent {
	s.t.Helper()
	f := s.nextOfType("event")
	data, _ := json.Marshal(f["event"])
	var ev protocol.SyncEvent
	_ = json.Unmarshal(data, &ev)
	return ev
}

func (s *socket) expectSilence() {
	s.t.Helper()
	select {
	case f := <-s.frames:
		s.t.Fatalf("unexpected frame %v", f)
	case <-time.After(300 * time.Millisecond):
	}
}

// sendWS sends a message over the WebSocket and returns the ack or nack.
func (s *socket) sendWS(envelope map[string]any) map[string]any {
	s.t.Helper()
	rid := fmt.Sprint(envelope["id"])
	s.send(map[string]any{"type": "send", "rid": rid, "envelope": envelope})
	var skipped []map[string]any
	defer func() { s.pending = append(skipped, s.pending...) }()
	for {
		f := s.next()
		if (f["type"] == "ack" || f["type"] == "nack") && f["rid"] == rid {
			return f
		}
		skipped = append(skipped, f)
	}
}

func envelopeText(ev protocol.SyncEvent) string {
	var env struct {
		Body struct{ CT string } `json:"body"`
	}
	_ = json.Unmarshal(ev.Data, &env)
	text, _ := base64.StdEncoding.DecodeString(env.Body.CT)
	return string(text)
}
