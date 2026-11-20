package push

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"hanashi/server/internal/store"
)

func decode(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base64.RawURLEncoding.DecodeString(strings.Join(strings.Fields(s), ""))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// The example from RFC 8291 section 5 and appendix A.
func TestEncryptMatchesRFC8291(t *testing.T) {
	plaintext := []byte("When I grow up, I want to be a watermelon")
	sender, err := ecdh.P256().NewPrivateKey(decode(t, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
	if err != nil {
		t.Fatal(err)
	}
	receiver, err := ecdh.P256().NewPrivateKey(decode(t, "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(receiver.PublicKey().Bytes(), decode(t, `BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-
		JvLexhqUzORcx aOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4`)) {
		t.Fatal("receiver key does not match the RFC")
	}
	auth := decode(t, "BTBZMqHH6r4Tts7J_aSIgg")
	salt := decode(t, "DGv6ra1nlYgDCS1FRnbzlw")

	got, err := encrypt(plaintext, receiver.PublicKey().Bytes(), auth, sender, salt)
	if err != nil {
		t.Fatal(err)
	}
	want := append(decode(t, `DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z 9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml
		mlMoZIIgDll6e3vCYLocInmYWAmS6Tlz AC8wEqKK6PBru3jl7A8`), decode(t, `8pfeW0KbunFT06SuDKoJH9Ql87S1QUrd irN6GcG7sFz1y1sqLgVi1VhjVkHsUoEs
		bI_0LpXMuGvnzQ`)...)
	if !bytes.Equal(got, want) {
		t.Fatalf("encrypt:\n got %x\nwant %x", got, want)
	}

	opened, err := Decrypt(got, receiver, auth)
	if err != nil || !bytes.Equal(opened, plaintext) {
		t.Fatalf("decrypt: %q, %v", opened, err)
	}
	tampered := bytes.Clone(got)
	tampered[len(tampered)-1] ^= 1
	if _, err := Decrypt(tampered, receiver, auth); err == nil {
		t.Fatal("tampered message decrypted")
	}
}

func TestVAPIDAuthorization(t *testing.T) {
	pkcs8, err := NewVAPIDKey()
	if err != nil {
		t.Fatal(err)
	}
	vapid, err := NewVAPID(pkcs8, "mailto:admin@test.local")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	header, err := vapid.Authorization("https://push.example.org:8443/wpush/abc?x=1", now)
	if err != nil {
		t.Fatal(err)
	}
	token, key, ok := strings.Cut(strings.TrimPrefix(header, "vapid t="), ", k=")
	if !ok || key != vapid.PublicKey() {
		t.Fatalf("header %q", header)
	}
	claims := verifyJWT(t, token, key)
	if claims["aud"] != "https://push.example.org:8443" || claims["sub"] != "mailto:admin@test.local" {
		t.Fatalf("claims %v", claims)
	}
	if exp := int64(claims["exp"].(float64)); exp <= now.Unix() || exp > now.Add(24*time.Hour).Unix() {
		t.Fatalf("exp %d must be within 24 hours (RFC 8292)", exp)
	}
}

// verifyJWT checks an ES256 JWT against a base64url public key and returns
// its claims.
func verifyJWT(t *testing.T, token, key string) map[string]any {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token %q", token)
	}
	point := decode(t, key)
	x, y := elliptic.Unmarshal(elliptic.P256(), point) //nolint:staticcheck // Only to verify in tests.
	if x == nil {
		t.Fatal("bad public key")
	}
	signature := decode(t, parts[2])
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])
	if len(signature) != 64 || !ecdsa.Verify(&ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, digest[:], r, s) {
		t.Fatal("bad signature")
	}
	var header, claims map[string]any
	if json.Unmarshal(decode(t, parts[0]), &header) != nil || header["alg"] != "ES256" {
		t.Fatalf("header %v", header)
	}
	if err := json.Unmarshal(decode(t, parts[1]), &claims); err != nil {
		t.Fatal(err)
	}
	return claims
}

// Fakes for the pusher.

type fakeStore struct {
	mu      sync.Mutex
	subs    []store.PushSubscription
	deleted []string
}

func (s *fakeStore) PushSubscriptions(_ context.Context, users []string) ([]store.PushSubscription, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []store.PushSubscription
	for _, sub := range s.subs {
		for _, u := range users {
			if sub.UserID == u {
				out = append(out, sub)
			}
		}
	}
	return out, nil
}

func (s *fakeStore) DeletePushSubscription(_ context.Context, device, _ string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.deleted = append(s.deleted, device)
	return nil
}

type fakePresence map[string]bool

func (p fakePresence) DeviceOnline(_, device string) bool { return p[device] }

type received struct {
	path    string
	header  http.Header
	payload []byte
}

// pushService records pushes, decrypting them with the subscriptions' keys.
type pushService struct {
	*httptest.Server
	mu     sync.Mutex
	pushes []received
	status int
}

func newPushService(t *testing.T, keys map[string]*ecdh.PrivateKey, auth []byte) *pushService {
	s := &pushService{status: http.StatusCreated}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		payload, err := Decrypt(body, keys[r.URL.Path], auth)
		if err != nil {
			t.Errorf("push to %s: %v", r.URL.Path, err)
		}
		s.mu.Lock()
		s.pushes = append(s.pushes, received{r.URL.Path, r.Header, payload})
		status := s.status
		s.mu.Unlock()
		w.WriteHeader(status)
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *pushService) received() []received {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]received(nil), s.pushes...)
}

func newTestPusher(t *testing.T, st Store, presence Presence, opts Options) *Pusher {
	pkcs8, err := NewVAPIDKey()
	if err != nil {
		t.Fatal(err)
	}
	vapid, err := NewVAPID(pkcs8, "mailto:admin@test.local")
	if err != nil {
		t.Fatal(err)
	}
	return New(st, presence, vapid, slog.New(slog.DiscardHandler), opts)
}

func TestPusherWakesOfflineDevicesOnly(t *testing.T) {
	auth := make([]byte, 16)
	_, _ = rand.Read(auth)
	keys := map[string]*ecdh.PrivateKey{}
	for _, d := range []string{"/phone", "/laptop", "/tablet"} {
		keys[d], _ = ecdh.P256().GenerateKey(rand.Reader)
	}
	service := newPushService(t, keys, auth)
	sub := func(device, user string) store.PushSubscription {
		return store.PushSubscription{
			DeviceID: device, UserID: user, Endpoint: service.URL + "/" + device,
			P256dh: base64.RawURLEncoding.EncodeToString(keys["/"+device].PublicKey().Bytes()),
			Auth:   base64.RawURLEncoding.EncodeToString(auth),
		}
	}
	st := &fakeStore{subs: []store.PushSubscription{sub("phone", "a"), sub("laptop", "a"), sub("tablet", "b")}}
	p := newTestPusher(t, st, fakePresence{"laptop": true}, Options{AllowPrivate: true, MinInterval: time.Millisecond})

	p.Notify([]string{"a", "b"}, "tablet", NewMessage)
	p.Wait()
	got := service.received()
	if len(got) != 1 || got[0].path != "/phone" {
		t.Fatalf("pushes %+v: want only the offline phone (laptop online, tablet caused it)", got)
	}
	h := got[0].header
	if string(got[0].payload) != `{"type":"sync"}` || h.Get("Content-Encoding") != "aes128gcm" ||
		h.Get("Urgency") != "high" || h.Get("TTL") == "" || h.Get("Topic") != "message" {
		t.Fatalf("push %q %v", got[0].payload, h)
	}
	token, key, _ := strings.Cut(strings.TrimPrefix(h.Get("Authorization"), "vapid t="), ", k=")
	if claims := verifyJWT(t, token, key); claims["aud"] != service.URL {
		t.Fatalf("aud %v", claims["aud"])
	}

	p.Notify([]string{"a"}, "laptop", ReadElsewhere)
	p.Wait()
	if got := service.received(); len(got) != 2 || got[1].header.Get("Urgency") != "normal" {
		t.Fatalf("read push %+v", got)
	}
}

func TestPusherCoalescesBursts(t *testing.T) {
	auth := make([]byte, 16)
	key, _ := ecdh.P256().GenerateKey(rand.Reader)
	service := newPushService(t, map[string]*ecdh.PrivateKey{"/phone": key}, auth)
	st := &fakeStore{subs: []store.PushSubscription{{
		DeviceID: "phone", UserID: "a", Endpoint: service.URL + "/phone",
		P256dh: base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()),
		Auth:   base64.RawURLEncoding.EncodeToString(auth),
	}}}
	p := newTestPusher(t, st, fakePresence{}, Options{AllowPrivate: true, MinInterval: 300 * time.Millisecond})
	for range 20 {
		p.Notify([]string{"a"}, "", NewMessage)
		time.Sleep(5 * time.Millisecond)
	}
	p.Wait()
	if n := len(service.received()); n < 1 || n > 2 {
		t.Fatalf("%d pushes for a burst of 20 messages; want 1 or 2", n)
	}
}

func TestPusherForgetsExpiredSubscriptions(t *testing.T) {
	service := newPushService(t, nil, nil)
	service.status = http.StatusGone
	st := &fakeStore{subs: []store.PushSubscription{{DeviceID: "phone", UserID: "a", Endpoint: service.URL + "/phone"}}}
	p := newTestPusher(t, st, fakePresence{}, Options{AllowPrivate: true, MinInterval: time.Millisecond})
	// Without keys the push is empty, which every push service accepts.
	service.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if body, _ := io.ReadAll(r.Body); len(body) != 0 || r.Header.Get("Content-Encoding") != "" {
			t.Errorf("keyless push carried %d bytes", len(body))
		}
		w.WriteHeader(http.StatusGone)
	})
	p.Notify([]string{"a"}, "", NewMessage)
	p.Wait()
	if len(st.deleted) != 1 || st.deleted[0] != "phone" {
		t.Fatalf("deleted %v", st.deleted)
	}
}

func TestPusherRefusesPrivateAddresses(t *testing.T) {
	var hits int
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits++ }))
	defer service.Close()
	st := &fakeStore{subs: []store.PushSubscription{{DeviceID: "phone", UserID: "a", Endpoint: service.URL + "/x"}}}
	p := newTestPusher(t, st, fakePresence{}, Options{MinInterval: time.Millisecond})
	p.Notify([]string{"a"}, "", NewMessage)
	p.Wait()
	if hits != 0 {
		t.Fatal("pushed to a loopback address")
	}
}
