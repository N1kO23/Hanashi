package api

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"

	"hanashi/server/internal/protocol"
	"hanashi/server/internal/store"
)

const maxProfileBytes = 16 * 1024

// profileJSON is a user's signed profile record, as GET /users/{id}/profile
// answers.
type profileJSON struct {
	User      string `json:"user"`
	Version   int64  `json:"version"`
	CT        string `json:"ct"`
	Signature string `json:"signature"`
}

// getProfile returns a user's signed profile record to them and to the people
// they share a conversation with. Without the user's profile key it is only
// ciphertext; this keeps strangers from watching when it changes. That of a
// user of another server comes from their server, by the same rule.
func (a *API) getProfile(w http.ResponseWriter, r *http.Request, c *Caller) error {
	userID := r.PathValue("id")
	var out *profileJSON
	var err error
	if a.remote(userID) {
		if !a.fed.Allowed(hostOf(userID)) {
			return errOtherServer
		}
		out, err = a.remoteProfile(r.Context(), c.UserID, userID)
	} else {
		out, err = a.localProfile(r.Context(), c.UserID, userID)
	}
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, out)
	return nil
}

func (a *API) localProfile(ctx context.Context, asker, userID string) (*profileJSON, error) {
	if userID != asker {
		shares, err := a.store.SharesConversation(ctx, asker, userID)
		if err != nil {
			return nil, err
		}
		if !shares {
			return nil, errNotFound
		}
	}
	p, err := a.store.Profile(ctx, userID)
	if errors.Is(err, store.ErrNotFound) {
		return nil, errNotFound
	} else if err != nil {
		return nil, err
	}
	return &profileJSON{userID, p.Version, p.CT, p.Signature}, nil
}

// putProfile publishes the caller's profile record, which must be newer than
// the one stored. The record is opaque here; devices check its signature.
func (a *API) putProfile(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Version   int64  `json:"version"`
		CT        string `json:"ct"`
		Signature string `json:"signature"`
	}
	if err := readJSONLimit(w, r, &req, 2*maxProfileBytes); err != nil {
		return err
	}
	if req.Version < 1 {
		return badRequest("version must be positive")
	}
	if err := decodeBase64(req.CT, maxProfileBytes, "ct"); err != nil {
		return err
	}
	if signature, err := base64.StdEncoding.DecodeString(req.Signature); err != nil || len(signature) != 64 {
		return badRequest("signature must be a base64 Ed25519 signature")
	}
	err := a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		if err := requireVerified(tx, c); err != nil {
			return nil, err
		}
		stored, err := tx.PutProfile(c.UserID, store.Profile{Version: req.Version, CT: req.CT, Signature: req.Signature})
		if err != nil {
			return nil, err
		}
		if !stored {
			return nil, &Error{http.StatusConflict, "stale_version", "A newer profile is stored; read it again"}
		}
		return a.emitToPeers(tx, c.UserID, protocol.EventProfileChanged,
			map[string]any{"user": c.UserID, "version": req.Version})
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]int64{"version": req.Version})
	return nil
}
