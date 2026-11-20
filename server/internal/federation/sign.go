package federation

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	"hanashi/server/internal/protocol"
)

// The headers of a request between servers. The signature is over the body
// alone, which says who it is from and for, and when: it means the same
// whatever carries it.
const (
	headerOrigin    = "X-Hanashi-Origin"
	headerKeyID     = "X-Hanashi-Key-Id"
	headerSignature = "X-Hanashi-Signature"
)

// Header is what every body between servers says, besides what it asks.
type Header struct {
	Origin      string `json:"origin"`
	Destination string `json:"destination"`
	// TS is when it was sent, in milliseconds.
	TS int64 `json:"ts"`
}

// Query asks host's server something it answers at once, and decodes the
// answer into out (unless nil).
func (f *Federation) Query(ctx context.Context, host, kind string, req map[string]any, out any) error {
	if !f.Allowed(host) {
		return ErrNotAllowed
	}
	ctx, cancel := context.WithTimeout(ctx, queryTimeout)
	defer cancel()
	return f.post(ctx, host, Prefix+"query/"+kind, req, out)
}

// post signs body (with the header added) and sends it to path of host's
// server, and decodes its JSON answer into out (unless nil).
func (f *Federation) post(ctx context.Context, host, path string, body map[string]any, out any) error {
	resp, err := f.request(ctx, host, path, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if out == nil {
		return nil
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, MaxBodyBytes)).Decode(out); err != nil {
		return &Unreachable{err}
	}
	return nil
}

// Fetch asks host's server for what it answers with other than JSON (a
// file); the caller reads the answer and closes its body.
func (f *Federation) Fetch(ctx context.Context, host, path string, body map[string]any) (*http.Response, error) {
	if !f.Allowed(host) {
		return nil, ErrNotAllowed
	}
	return f.request(ctx, host, path, body)
}

// Tell sends host's server what matters only now (typing, presence): at once,
// once, and without waiting. If it does not arrive, nothing is lost that will
// not come again.
func (f *Federation) Tell(host string, body map[string]any) {
	if !f.Allowed(host) {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), tellTimeout)
		defer cancel()
		if err := f.post(ctx, host, ephemeralPath, body, nil); err != nil {
			f.log.Debug("federation: not told", "to", host, "err", err)
		}
	}()
}

// request signs body (with the header added) and sends it to path of host's
// server. A success is answered as it came; anything else as an error.
func (f *Federation) request(ctx context.Context, host, path string, body map[string]any) (*http.Response, error) {
	full := map[string]any{"origin": f.opts.Host, "destination": host, "ts": time.Now().UnixMilli()}
	for k, v := range body {
		full[k] = v
	}
	data, err := json.Marshal(full)
	if err != nil {
		return nil, err
	}
	base, client := f.address(ctx, host)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+path, bytes.NewReader(data))
	if err != nil {
		return nil, &Unreachable{err}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(headerOrigin, f.opts.Host)
	req.Header.Set(headerKeyID, f.keyID)
	req.Header.Set(headerSignature, base64.StdEncoding.EncodeToString(ed25519.Sign(f.key, data)))
	resp, err := client.Do(req)
	if err != nil {
		return nil, &Unreachable{err}
	}
	if resp.StatusCode == http.StatusOK {
		return resp, nil
	}
	defer resp.Body.Close()
	var e struct {
		Error   string `json:"error"`
		Message string `json:"message"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, MaxBodyBytes)).Decode(&e) != nil || e.Error == "" {
		return nil, &Unreachable{errors.New(resp.Status)}
	}
	refused := &Error{Status: resp.StatusCode, Code: e.Error, Message: e.Message}
	if seconds, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && seconds > 0 {
		refused.RetryAfter = time.Duration(seconds) * time.Second
	}
	return nil, refused
}

// Verify checks that a request comes from the server it says, is meant for
// this one, and was sent lately; it answers who sent it, and its body.
func (f *Federation) Verify(r *http.Request) (string, []byte, error) {
	if !f.opts.Enabled {
		return "", nil, &Error{Status: http.StatusNotFound, Code: "federation_off", Message: "This server does not federate"}
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, MaxBodyBytes+1))
	if err != nil {
		return "", nil, &Error{Status: http.StatusBadRequest, Code: "bad_request", Message: "The body could not be read"}
	}
	if len(body) > MaxBodyBytes {
		return "", nil, &Error{Status: http.StatusRequestEntityTooLarge, Code: "too_large", Message: "The body is too large"}
	}
	refused := func(msg string) error {
		return &Error{Status: http.StatusUnauthorized, Code: "not_signed", Message: msg}
	}
	origin := r.Header.Get(headerOrigin)
	var h Header
	if json.Unmarshal(body, &h) != nil || h.Origin != origin || !protocol.ValidHost(origin) {
		return "", nil, refused("The body must say which server it is from, as the header does")
	}
	if h.Destination != f.opts.Host {
		return "", nil, refused("This is not " + h.Destination)
	}
	if skew := time.Since(time.UnixMilli(h.TS)); skew > maxClockSkew || skew < -maxClockSkew {
		return "", nil, refused("Sent too long ago, or the clocks differ")
	}
	if !f.Allowed(origin) {
		return "", nil, &Error{Status: http.StatusForbidden, Code: "not_allowed", Message: "This server does not federate with " + origin}
	}
	signature, err := base64.StdEncoding.DecodeString(r.Header.Get(headerSignature))
	if err != nil {
		return "", nil, refused("No signature")
	}
	key, err := f.serverKey(r.Context(), origin, r.Header.Get(headerKeyID))
	if err != nil {
		f.log.Info("federation: request not taken: the key could not be had", "origin", origin, "err", err)
		return "", nil, refused("The key could not be had from " + origin)
	}
	if !ed25519.Verify(key, body, signature) {
		return "", nil, refused("The signature is not " + origin + "'s")
	}
	if err := f.limits.allow(origin, r.URL.Path); err != nil {
		f.log.Debug("federation: request over the limit", "origin", origin, "path", r.URL.Path)
		return "", nil, err
	}
	return origin, body, nil
}
