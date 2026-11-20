package api_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"testing"

	"github.com/oklog/ulid/v2"
)

func hashOf(b []byte) string {
	sum := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func (d *device) upload(body []byte, mime string) (*http.Response, map[string]any) {
	req, _ := http.NewRequest("POST", d.base+"/media", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+d.Token)
	req.Header.Set("Content-Type", mime)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		d.t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res, out
}

func (d *device) download(hash, rangeHeader string, auth bool) (*http.Response, []byte) {
	req, _ := http.NewRequest("GET", d.base+"/media/"+hash, nil)
	if auth {
		req.Header.Set("Authorization", "Bearer "+d.Token)
	}
	if rangeHeader != "" {
		req.Header.Set("Range", rangeHeader)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		d.t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return res, body
}

var hundredBytes = func() []byte {
	b := make([]byte, 100)
	for i := range b {
		b[i] = byte(i)
	}
	return b
}()

func TestUploadIsContentAddressed(t *testing.T) {
	a := register(t, startServer(t), "a")
	res, first := a.upload(hundredBytes, "image/png")
	if res.StatusCode != 200 || first["hash"] != hashOf(hundredBytes) || first["size"] != 100.0 || first["mime"] != "image/png" {
		t.Fatalf("upload: %d %v", res.StatusCode, first)
	}
	if _, second := a.upload(hundredBytes, "image/png"); second["hash"] != first["hash"] {
		t.Fatal("same bytes must get the same hash")
	}
	if res, _ := a.upload(make([]byte, 1001), "image/png"); res.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized upload: %d", res.StatusCode)
	}
}

func TestDownloadAndRanges(t *testing.T) {
	a := register(t, startServer(t), "a")
	hash := hashOf(hundredBytes)
	a.upload(hundredBytes, "image/png")

	res, body := a.download(hash, "", true)
	if res.StatusCode != 200 || !bytes.Equal(body, hundredBytes) || res.Header.Get("Content-Type") != "image/png" {
		t.Fatalf("full download: %d %q", res.StatusCode, res.Header.Get("Content-Type"))
	}
	if res.Header.Get("Accept-Ranges") != "bytes" || res.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("headers %v", res.Header)
	}
	cases := []struct {
		header string
		want   []byte
		rng    string
	}{
		{"bytes=2-5", []byte{2, 3, 4, 5}, "bytes 2-5/100"},
		{"bytes=97-", []byte{97, 98, 99}, "bytes 97-99/100"},
		{"bytes=-2", []byte{98, 99}, "bytes 98-99/100"},
	}
	for _, c := range cases {
		res, body := a.download(hash, c.header, true)
		if res.StatusCode != http.StatusPartialContent || !bytes.Equal(body, c.want) || res.Header.Get("Content-Range") != c.rng {
			t.Fatalf("%s: %d %v %q", c.header, res.StatusCode, body, res.Header.Get("Content-Range"))
		}
	}
	if res, _ := a.download(hash, "bytes=500-", true); res.StatusCode != http.StatusRequestedRangeNotSatisfiable ||
		res.Header.Get("Content-Range") != "bytes */100" {
		t.Fatalf("unsatisfiable range: %d %q", res.StatusCode, res.Header.Get("Content-Range"))
	}
}

func TestDownloadNeedsAuthAndAKnownHash(t *testing.T) {
	a := register(t, startServer(t), "a")
	hash := hashOf(hundredBytes)
	a.upload(hundredBytes, "image/png")
	if res, _ := a.download(hash, "", false); res.StatusCode != 401 {
		t.Fatalf("anonymous: %d", res.StatusCode)
	}
	if res, _ := a.download(hashOf([]byte{1, 2, 3}), "", true); res.StatusCode != 404 {
		t.Fatalf("unknown hash: %d", res.StatusCode)
	}
	if res, _ := a.download("not-a-hash", "", true); res.StatusCode != 404 {
		t.Fatalf("malformed hash: %d", res.StatusCode)
	}
}

func TestPlaintextMessagesAreRejected(t *testing.T) {
	base := startServer(t)
	a, b := register(t, base, "a"), register(t, base, "b")
	conv := a.createConversation("", b.UserID)
	plaintext := map[string]any{
		"v": 1, "id": ulid.Make().String(), "conv": conv.ID, "from": a.UserID, "ts": 1, "type": "text",
		"body": map[string]any{"text": "hello"},
	}
	if err := a.do("POST", "/messages", plaintext, nil); statusOf(err) != 400 {
		t.Fatalf("plaintext over HTTP: %v", err)
	}
	if ack := a.connect().sendWS(plaintext); ack["type"] != "nack" || ack["error"] != "bad_request" {
		t.Fatalf("plaintext over WebSocket: %v", ack)
	}
}
