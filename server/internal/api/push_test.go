package api_test

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"hanashi/server/internal/protocol"
	"hanashi/server/internal/push"
)

// pushService stands in for a UnifiedPush distributor or FCM: it records
// the pushes it gets and decrypts them with the devices' keys.
type pushService struct {
	*httptest.Server
	t      *testing.T
	auth   []byte
	keys   map[string]*ecdh.PrivateKey
	mu     sync.Mutex
	pushes []pushReceived
	// headers are the pushes' headers, in the same order.
	headers []http.Header
}

type pushReceived struct {
	device  string
	urgency string
	payload string
}

func newPushService(t *testing.T) *pushService {
	s := &pushService{t: t, auth: make([]byte, 16), keys: map[string]*ecdh.PrivateKey{}}
	_, _ = rand.Read(s.auth)
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		device := strings.TrimPrefix(r.URL.Path, "/")
		body, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		defer s.mu.Unlock()
		payload, err := push.Decrypt(body, s.keys[device], s.auth)
		if err != nil {
			t.Errorf("push for %s: %v", device, err)
		}
		if !strings.HasPrefix(r.Header.Get("Authorization"), "vapid t=") {
			t.Errorf("push without VAPID: %q", r.Header.Get("Authorization"))
		}
		s.pushes = append(s.pushes, pushReceived{device, r.Header.Get("Urgency"), string(payload)})
		s.headers = append(s.headers, r.Header.Clone())
		w.WriteHeader(http.StatusCreated)
	}))
	t.Cleanup(s.Close)
	return s
}

// subscribe registers d for pushes under name.
func (s *pushService) subscribe(d *device, name string) {
	key, _ := ecdh.P256().GenerateKey(rand.Reader)
	s.mu.Lock()
	s.keys[name] = key
	s.mu.Unlock()
	d.must("PUT", "/push/subscription", map[string]any{
		"endpoint": s.URL + "/" + name,
		"keys": map[string]string{
			"p256dh": base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()),
			"auth":   base64.RawURLEncoding.EncodeToString(s.auth),
		},
	}, nil)
}

// waitFor waits until n pushes arrived, then makes sure no more follow.
func (s *pushService) waitFor(n int) []pushReceived {
	s.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		s.mu.Lock()
		got := append([]pushReceived(nil), s.pushes...)
		s.mu.Unlock()
		if len(got) > n {
			s.t.Fatalf("expected %d pushes, got %+v", n, got)
		}
		if len(got) == n {
			time.Sleep(150 * time.Millisecond)
			s.mu.Lock()
			defer s.mu.Unlock()
			if len(s.pushes) != n {
				s.t.Fatalf("expected %d pushes, got %+v", n, s.pushes)
			}
			return got
		}
		if time.Now().After(deadline) {
			s.t.Fatalf("expected %d pushes, got %+v", n, got)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestPushSubscriptionValidation(t *testing.T) {
	base := startServer(t)
	a := register(t, base, "a")

	var info protocol.ServerInfo
	a.must("GET", "/server", nil, &info)
	if key, err := base64.RawURLEncoding.DecodeString(info.VAPIDKey); err != nil || len(key) != 65 || key[0] != 4 {
		t.Fatalf("vapidKey %q", info.VAPIDKey)
	}
	point := func() string {
		key, _ := ecdh.P256().GenerateKey(rand.Reader)
		return base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes())
	}
	auth := base64.RawURLEncoding.EncodeToString(make([]byte, 16))
	for name, body := range map[string]map[string]any{
		"not http":       {"endpoint": "ftp://push.example.org/x"},
		"no host":        {"endpoint": "https:///x"},
		"too long":       {"endpoint": "https://push.example.org/" + strings.Repeat("x", 2048)},
		"short auth":     {"endpoint": "https://push.example.org/x", "keys": map[string]string{"p256dh": point(), "auth": "AAAA"}},
		"not a point":    {"endpoint": "https://push.example.org/x", "keys": map[string]string{"p256dh": auth, "auth": auth}},
		"padded base64":  {"endpoint": "https://push.example.org/x", "keys": map[string]string{"p256dh": point() + "=", "auth": auth}},
		"missing fields": {},
	} {
		if err := a.do("PUT", "/push/subscription", body, nil); statusOf(err) != 400 {
			t.Errorf("%s: %v", name, err)
		}
	}
	a.must("PUT", "/push/subscription", map[string]any{"endpoint": "https://push.example.org/x"}, nil)
	a.must("PUT", "/push/subscription", map[string]any{
		"endpoint": "https://push.example.org/y", "keys": map[string]string{"p256dh": point(), "auth": auth},
	}, nil)
	a.must("DELETE", "/push/subscription", nil, nil)
}

// A request wakes the one asked, not the one asking; so does its acceptance.
func TestContactRequestsWakeOthers(t *testing.T) {
	base := startServer(t)
	service := newPushService(t)
	a, b := register(t, base, "a"), register(t, base, "b")
	service.subscribe(a, "a")
	service.subscribe(b, "b")
	a.request(b.UserID)
	if got := service.waitFor(1); got[0].device != "b" || got[0].urgency != "high" {
		t.Fatalf("request push %+v", got[0])
	}
	if err := b.accept(a.UserID); err != nil {
		t.Fatal(err)
	}
	if got := service.waitFor(2); got[1].device != "a" || got[1].urgency != "high" {
		t.Fatalf("acceptance push %+v", got[1])
	}
}

// A commit without the group's state asks others to seal it, gently.
func TestCommitsWithoutStateWakeMembers(t *testing.T) {
	base := startServer(t)
	service := newPushService(t)
	a, b := register(t, base, "a"), register(t, base, "b")
	conv := a.createConversation("Club", b.UserID)
	service.subscribe(a, "a")
	service.subscribe(b, "b")

	leaseID, epoch := a.lease(conv.ID)
	commit := commitBody(leaseID, epoch)
	commit["state"] = b64([]byte("sealed"))
	a.must("POST", "/conversations/"+conv.ID+"/commits", commit, nil)
	service.waitFor(0)

	leaseID, epoch = a.lease(conv.ID)
	a.must("POST", "/conversations/"+conv.ID+"/commits", commitBody(leaseID, epoch), nil)
	if got := service.waitFor(1); got[0].device != "b" || got[0].urgency != "normal" {
		t.Fatalf("push %+v", got[0])
	}
}

func TestOfflineDevicesAreWoken(t *testing.T) {
	base := startServer(t)
	service := newPushService(t)
	a := register(t, base, "a")
	phone := register(t, base, "b")
	laptop := login(t, base, "b", "laptop")
	conv := a.createConversation("", phone.UserID)
	service.subscribe(a, "a")
	service.subscribe(phone, "phone")
	service.subscribe(laptop, "laptop")
	laptop.connect() // Online: it gets the event over its socket instead.

	seq := a.sendREST(conv.ID, "hi")
	// Only B's offline phone: not the sender, not the connected laptop.
	got := service.waitFor(1)
	if got[0] != (pushReceived{"phone", "high", `{"type":"sync"}`}) {
		t.Fatalf("push %+v", got[0])
	}

	// Reading on the laptop wakes the phone (gently) to clear its notification.
	laptop.must("POST", "/conversations/"+conv.ID+"/read", map[string]any{"upTo": seq}, nil)
	if got := service.waitFor(2); got[1].device != "phone" || got[1].urgency != "normal" {
		t.Fatalf("read push %+v", got[1])
	}

	// A signed-out device is never woken again.
	phone.must("POST", "/auth/logout", map[string]any{}, nil)
	a.sendREST(conv.ID, "still there?")
	service.waitFor(2)
}
