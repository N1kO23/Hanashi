package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"

	"hanashi/server/internal/federation"
	"hanashi/server/internal/protocol"
	"hanashi/server/internal/store"
)

// Files across servers (see "Federation" in docs/protocol.md): a file stays on
// the server it was uploaded to. The server of someone who opens it fetches it
// from there once, passing it on while keeping it, and serves it itself from
// then on.

// fetchMedia gets the blob of hash from host's server for c, and keeps it.
// One fetch of a blob at a time: another asking meanwhile waits for it, then
// gets what it kept.
func (a *API) fetchMedia(w http.ResponseWriter, r *http.Request, c *Caller, hash, host string) error {
	if !a.fed.Allowed(host) {
		return errNotFound
	}
	done := make(chan struct{})
	if running, busy := a.mediaFetches.LoadOrStore(hash, done); busy {
		select {
		case <-running.(chan struct{}):
		case <-r.Context().Done():
			return r.Context().Err()
		}
		return a.serveMedia(w, r, hash)
	}
	defer func() {
		a.mediaFetches.Delete(hash)
		close(done)
	}()
	resp, err := a.fed.Fetch(r.Context(), host, federation.Prefix+"media", map[string]any{"hash": hash})
	if err != nil {
		var fedErr *federation.Error
		if errors.As(err, &fedErr) && fedErr.Status == http.StatusNotFound {
			return errNotFound
		}
		c.Log.Info("media not fetched", "hash", hash, "host", host, "err", err)
		return errServerUnreachable
	}
	defer resp.Body.Close()
	if resp.ContentLength > a.cfg.MaxUploadBytes {
		return errTooLarge
	}
	mime := strings.ToLower(strings.TrimSpace(strings.Split(resp.Header.Get("Content-Type"), ";")[0]))
	if !mimePattern.MatchString(mime) {
		mime = "application/octet-stream"
	}
	setMediaHeaders(w, mime)
	if resp.ContentLength >= 0 {
		w.Header().Set("Content-Length", strconv.FormatInt(resp.ContentLength, 10))
	}
	w.WriteHeader(http.StatusOK)
	// From here on the app has its answer: a failure only cuts it short, and
	// keeps nothing. (The app checks the hash too.)
	size, err := a.media.SaveAs(io.TeeReader(resp.Body, w), a.cfg.MaxUploadBytes, hash)
	if err != nil {
		c.Log.Info("media from another server not kept", "hash", hash, "host", host, "err", err)
		return nil
	}
	// Whoever opened it first stands for its uploader here.
	if err := a.store.AddMedia(context.WithoutCancel(r.Context()), store.Media{Hash: hash, Size: size, Mime: mime},
		c.UserID); err != nil {
		c.Log.Warn("media from another server not noted", "hash", hash, "err", err)
	}
	c.Log.Debug("media fetched", "hash", hash, "host", host, "size", size)
	return nil
}

// federationMedia gives another server a file this one has. Knowing its hash
// is what lets one have it, as for this server's own users.
func (a *API) federationMedia(w http.ResponseWriter, r *http.Request) {
	if err := a.giveMedia(w, r); err != nil {
		a.fail(w, r, err)
	}
}

func (a *API) giveMedia(w http.ResponseWriter, r *http.Request) error {
	origin, body, err := a.fed.Verify(r)
	if err != nil {
		return err
	}
	var req struct {
		Hash string `json:"hash"`
	}
	if json.Unmarshal(body, &req) != nil || !protocol.IsContentHash(req.Hash) {
		return errNotFound
	}
	row, err := a.store.Media(r.Context(), req.Hash)
	if err != nil {
		return err
	}
	f, err := os.Open(a.media.Path(req.Hash))
	if errors.Is(err, os.ErrNotExist) {
		return errNotFound
	} else if err != nil {
		return err
	}
	defer f.Close()
	w.Header().Set("Content-Type", row.Mime)
	w.Header().Set("Content-Length", strconv.FormatInt(row.Size, 10))
	w.WriteHeader(http.StatusOK)
	if _, err := io.Copy(w, f); err != nil {
		a.log.Debug("federation: media cut short", "origin", origin, "hash", req.Hash, "err", err)
	}
	return nil
}
