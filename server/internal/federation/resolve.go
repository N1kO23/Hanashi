package federation

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	wellKnownPath = "/.well-known/hanashi/server"
	// How long an address is used before it is looked up again; after a
	// failed look-up, not as long.
	addressTTL       = time.Hour
	failedAddressTTL = 5 * time.Minute
	// Keys of a server are fetched at most this often, so that requests naming
	// keys it does not have cannot make this server fetch again and again.
	keyFetchInterval = time.Minute
)

type address struct {
	base    string
	client  *http.Client
	expires time.Time
}

// address is where host's server answers: as Resolve says, or as
// https://<host>/.well-known/hanashi/server says ({"server": "https://..."}),
// or else at https://<host> itself. A user's host need not be where their
// server runs.
func (f *Federation) address(ctx context.Context, host string) (string, *http.Client) {
	if base, ok := f.opts.Resolve[host]; ok {
		return base, f.trusted
	}
	f.mu.Lock()
	cached, ok := f.addresses[host]
	f.mu.Unlock()
	if ok && time.Now().Before(cached.expires) {
		return cached.base, cached.client
	}
	base, err := f.lookUp(ctx, host)
	ttl := addressTTL
	if err != nil {
		f.log.Debug("federation: no address given, using the host's", "host", host, "err", err)
		base, ttl = "https://"+host, failedAddressTTL
	}
	f.mu.Lock()
	f.addresses[host] = address{base, f.public, time.Now().Add(ttl)}
	f.mu.Unlock()
	return base, f.public
}

// lookUp reads host's well-known file. Answering 404 is saying the server is
// at the host itself.
func (f *Federation) lookUp(ctx context.Context, host string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, queryTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+host+wellKnownPath, nil)
	if err != nil {
		return "", err
	}
	resp, err := f.public.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return "https://" + host, nil
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%s answered %d", wellKnownPath, resp.StatusCode)
	}
	var doc struct {
		Server string `json:"server"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&doc); err != nil {
		return "", err
	}
	u, err := url.Parse(doc.Server)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("%s gave %q, not an https:// address", wellKnownPath, doc.Server)
	}
	return strings.TrimSuffix(doc.Server, "/"), nil
}

// serverKey is host's key with ID keyID, fetched from its server if this one
// does not have it yet. Fetching over TLS from the host's own address is what
// vouches for it.
func (f *Federation) serverKey(ctx context.Context, host, keyID string) (ed25519.PublicKey, error) {
	f.mu.Lock()
	key, ok := f.keys[host][keyID]
	fetched := f.keysFetch[host]
	f.mu.Unlock()
	if ok {
		return key, nil
	}
	if time.Since(fetched) < keyFetchInterval {
		return nil, errors.New("unknown key")
	}
	f.mu.Lock()
	known := len(f.keys[host]) > 0
	f.mu.Unlock()
	if !known {
		if _, ok := f.limits.newKeys.take("", time.Now()); !ok {
			return nil, errors.New("too many servers not seen before ask at once")
		}
	}
	f.mu.Lock()
	f.keysFetch[host] = time.Now()
	f.mu.Unlock()
	base, client := f.address(ctx, host)
	ctx, cancel := context.WithTimeout(ctx, queryTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+keyPath, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("its key: %d", resp.StatusCode)
	}
	var doc struct {
		Host, KeyID, Key string
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&doc); err != nil {
		return nil, err
	}
	raw, err := base64.StdEncoding.DecodeString(doc.Key)
	if err != nil || len(raw) != ed25519.PublicKeySize || doc.Host != host || doc.KeyID != keyIDOf(raw) {
		return nil, errors.New("its key is not a key of that host")
	}
	f.mu.Lock()
	if f.keys[host] == nil {
		f.keys[host] = map[string]ed25519.PublicKey{}
	}
	f.keys[host][doc.KeyID] = raw
	f.mu.Unlock()
	if doc.KeyID != keyID {
		return nil, errors.New("unknown key")
	}
	return raw, nil
}
