package api_test

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"testing"

	"hanashi/server/internal/protocol"
)

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func newKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

type userKeys struct {
	UserID          string
	IdentityKey     string
	IdentityVersion int
	Devices         []struct {
		DeviceID      string
		MLSSigKey     string
		Signature     *string
		SignedVersion *int
	}
}

func (d *device) keysOf(userID string) userKeys {
	d.t.Helper()
	var k userKeys
	d.must("GET", "/keys/users/"+userID, nil, &k)
	return k
}

// setUpDevice registers an MLS key for d and returns it.
func (d *device) setUpDevice() ed25519.PublicKey {
	d.t.Helper()
	pub, _ := newKey(d.t)
	d.must("PUT", "/keys/device", map[string]any{"mlsSigKey": b64(pub)}, nil)
	return pub
}

// setUpIdentity gives d's user an identity key and verifies d with it, as
// the app does on sign-up.
func (d *device) setUpIdentity() ed25519.PrivateKey {
	d.t.Helper()
	pub, priv := newKey(d.t)
	d.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(pub)}, nil)
	if err := d.sign(priv, d.DeviceID, d.setUpDevice()); err != nil {
		d.t.Fatal(err)
	}
	return priv
}

func (d *device) sign(identity ed25519.PrivateKey, deviceID string, mlsKey ed25519.PublicKey) error {
	sig := ed25519.Sign(identity, protocol.DeviceRecordMessage(d.UserID, deviceID, b64(mlsKey)))
	return d.do("PUT", "/keys/devices/"+deviceID+"/signature", map[string]any{"signature": b64(sig)}, nil)
}

func TestIdentityLifecycle(t *testing.T) {
	base := startServer(t)
	a := register(t, base, "a")
	idPub, idPriv := newKey(t)

	if err := a.do("PUT", "/keys/identity", map[string]any{"identityKey": "short"}, nil); statusOf(err) != 400 {
		t.Fatalf("bad key: %v", err)
	}
	a.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(idPub)}, nil)
	a.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(idPub)}, nil) // Idempotent.
	if k := a.keysOf(a.UserID); k.IdentityKey != b64(idPub) || k.IdentityVersion != 1 {
		t.Fatalf("keys %+v", k)
	}

	mls := a.setUpDevice()
	if err := a.sign(idPriv, a.DeviceID, mls); err != nil {
		t.Fatal(err)
	}
	a.must("PUT", "/keys/secret-storage", map[string]any{"data": "opaque", "identityVersion": 1}, nil)

	otherPub, _ := newKey(t)
	if err := a.do("PUT", "/keys/identity", map[string]any{"identityKey": b64(otherPub)}, nil); codeOf(err) != "identity_exists" {
		t.Fatalf("replacing without reset: %v", err)
	}
	a.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(otherPub), "reset": true}, nil)
	k := a.keysOf(a.UserID)
	if k.IdentityVersion != 2 || k.Devices[0].Signature != nil {
		t.Fatalf("reset must void device signatures: %+v", k)
	}
	if err := a.do("GET", "/keys/secret-storage", nil, nil); statusOf(err) != 404 {
		t.Fatalf("reset must drop secret storage: %v", err)
	}
}

func TestDeviceKeysAndSignatures(t *testing.T) {
	base := startServer(t)
	a := register(t, base, "a")
	a2 := login(t, base, "a", "laptop")
	b := register(t, base, "b")
	idPub, idPriv := newKey(t)

	if err := a.do("PUT", "/keys/device", map[string]any{"mlsSigKey": "x"}, nil); statusOf(err) != 400 {
		t.Fatalf("bad device key: %v", err)
	}
	mls := a.setUpDevice()
	a.must("PUT", "/keys/device", map[string]any{"mlsSigKey": b64(mls)}, nil) // Same key again is fine.
	if err := a.do("PUT", "/keys/device", map[string]any{"mlsSigKey": b64(freshKey(t))}, nil); codeOf(err) != "device_key_exists" {
		t.Fatalf("changing a device key: %v", err)
	}

	if err := a.sign(idPriv, a.DeviceID, mls); codeOf(err) != "no_identity" {
		t.Fatalf("signing before an identity exists: %v", err)
	}
	a.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(idPub)}, nil)
	_, wrongPriv := newKey(t)
	if err := a.sign(wrongPriv, a.DeviceID, mls); codeOf(err) != "bad_signature" {
		t.Fatalf("forged signature: %v", err)
	}
	if err := a.sign(idPriv, a.DeviceID, mls); err != nil {
		t.Fatal(err)
	}

	// The laptop is listed but unverified until signed.
	mls2 := a2.setUpDevice()
	k := b.keysOf(a.UserID)
	if len(k.Devices) != 2 || k.Devices[0].Signature == nil || k.Devices[1].Signature != nil {
		t.Fatalf("device list %+v", k.Devices)
	}
	// Another user cannot sign a's devices.
	bID, bPriv := newKey(t)
	b.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(bID)}, nil)
	if err := b.sign(bPriv, a2.DeviceID, mls2); statusOf(err) != 404 {
		t.Fatalf("signing someone else's device: %v", err)
	}
	// a's verified phone signs the laptop.
	if err := a.sign(idPriv, a2.DeviceID, mls2); err != nil {
		t.Fatal(err)
	}

	// Revoking a device removes its keys.
	a.must("DELETE", "/devices/"+a2.DeviceID, nil, nil)
	if k := b.keysOf(a.UserID); len(k.Devices) != 1 {
		t.Fatalf("revoked device still listed: %+v", k.Devices)
	}
}

// freshKey returns a new public key without registering it.
func freshKey(t *testing.T) ed25519.PublicKey {
	pub, _ := newKey(t)
	return pub
}

func TestSecretStorage(t *testing.T) {
	base := startServer(t)
	a := register(t, base, "a")
	if err := a.do("GET", "/keys/secret-storage", nil, nil); statusOf(err) != 404 {
		t.Fatalf("before upload: %v", err)
	}
	if err := a.do("PUT", "/keys/secret-storage", map[string]any{"data": "x", "identityVersion": 1}, nil); codeOf(err) != "identity_changed" {
		t.Fatalf("without an identity: %v", err)
	}
	idPub, _ := newKey(t)
	a.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(idPub)}, nil)
	if err := a.do("PUT", "/keys/secret-storage", map[string]any{"data": string(make([]byte, 17*1024)), "identityVersion": 1}, nil); statusOf(err) != 400 {
		t.Fatalf("oversized: %v", err)
	}
	a.must("PUT", "/keys/secret-storage", map[string]any{"data": "sealed-blob", "identityVersion": 1}, nil)
	var got struct {
		Data            string
		IdentityVersion int
	}
	login(t, base, "a", "new phone").must("GET", "/keys/secret-storage", nil, &got)
	if got.Data != "sealed-blob" || got.IdentityVersion != 1 {
		t.Fatalf("secret storage %+v", got)
	}
}

func TestKeyChangesReachContacts(t *testing.T) {
	base := startServer(t)
	a, b, stranger := register(t, base, "a"), register(t, base, "b"), register(t, base, "stranger")
	a.createConversation("", b.UserID)
	cursors := map[*device]int64{a: a.syncSince(0).Cursor, b: b.syncSince(0).Cursor, stranger: stranger.syncSince(0).Cursor}

	a.setUpDevice()
	for _, d := range []*device{a, b} {
		events := d.syncSince(cursors[d]).Events
		if len(events) != 1 || events[0].Type != protocol.EventDeviceKeysChanged || events[0].Conv != "" {
			t.Fatalf("%s got %+v", d.UserID, events)
		}
	}
	if events := stranger.syncSince(cursors[stranger]).Events; len(events) != 0 {
		t.Fatalf("stranger got %+v", events)
	}
	// Live too.
	sb := b.connect()
	idPub, _ := newKey(t)
	a.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(idPub)}, nil)
	if ev := sb.nextEvent(); ev.Type != protocol.EventDeviceKeysChanged {
		t.Fatalf("live event %+v", ev)
	}
}
