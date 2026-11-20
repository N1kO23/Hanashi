package api

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"net/http"
	"slices"
	"strconv"

	"hanashi/server/internal/federation"
	"hanashi/server/internal/protocol"
	"hanashi/server/internal/store"
)

// Key directory: identity keys, device keys and their cross-signatures, and
// the user's encrypted secret storage. The server stores what clients upload
// and checks signatures as a sanity check, but clients never rely on that:
// they verify everything against identity keys they have pinned themselves.

const maxSecretStorageBytes = 16 * 1024

// decodeKey decodes standard base64 of exactly n bytes.
func decodeKey(s string, n int, field string) ([]byte, error) {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(b) != n {
		return nil, badRequest(field + " must be base64 of " + strconv.Itoa(n) + " bytes")
	}
	return b, nil
}

// emitKeysChanged tells the user's devices and contacts to refetch the user's
// keys; contacts and conversation peers of other servers, through their
// servers. Must run inside store.AppendEvents.
func (a *API) emitKeysChanged(tx *store.Tx, userID string) (func(), error) {
	publish, err := a.emitToPeers(tx, userID, protocol.EventDeviceKeysChanged, map[string]string{"user": userID})
	if err != nil {
		return nil, err
	}
	hosts, err := tx.RemoteContactHosts(userID, a.cfg.Host)
	if err != nil {
		return nil, err
	}
	// Also those of the people the user shares a conversation with.
	peers, err := tx.ConversationPeers(userID)
	if err != nil {
		return nil, err
	}
	for _, host := range a.remoteHosts(peers) {
		if !slices.Contains(hosts, host) {
			hosts = append(hosts, host)
		}
	}
	for _, host := range hosts {
		if err := federation.Enqueue(tx, host, map[string]any{"type": itemKeysChanged, "user": userID}); err != nil {
			return nil, err
		}
	}
	return func() {
		publish()
		for _, host := range hosts {
			a.fed.Wake(host)
		}
	}, nil
}

// emitToPeers appends a user-level event for the user and everyone
// sharing a conversation with them. Must run inside store.AppendEvents.
func (a *API) emitToPeers(tx *store.Tx, userID, eventType string, payload any) (func(), error) {
	contacts, err := tx.ConversationPeers(userID)
	if err != nil {
		return nil, err
	}
	data := eventData(payload)
	a.log.Debug("telling contacts", "event", eventType, "about", userID, "users", len(contacts))
	var events []protocol.SyncEvent
	for _, c := range contacts {
		ev, err := tx.AppendEvent("", eventType, data, store.AppendOptions{TargetUser: c})
		if err != nil {
			return nil, err
		}
		events = append(events, ev)
	}
	return func() {
		for i, ev := range events {
			a.hub.Publish(ev, []string{contacts[i]})
		}
	}, nil
}

// keysChanged emits device_keys_changed outside of any other write.
func (a *API) keysChanged(ctx context.Context, userID string) error {
	return a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) { return a.emitKeysChanged(tx, userID) })
}

func (a *API) putIdentity(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		IdentityKey string `json:"identityKey"`
		Reset       bool   `json:"reset"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	if _, err := decodeKey(req.IdentityKey, ed25519.PublicKeySize, "identityKey"); err != nil {
		return err
	}
	var version int
	err := a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		current, err := tx.UserKeys(c.UserID)
		switch {
		case errors.Is(err, store.ErrNotFound):
			version = 1
			c.Log.Info("encryption identity created")
		case err != nil:
			return nil, err
		case current.IdentityKey == req.IdentityKey:
			version = current.IdentityVersion
			return nil, nil
		case !req.Reset:
			return nil, &Error{http.StatusConflict, "identity_exists", "This account already has an encryption identity"}
		default:
			// Reset: everything vouched for by the old identity is void.
			version = current.IdentityVersion + 1
			c.Log.Info("encryption identity reset", "identity_version", version)
			if err := tx.ResetIdentityState(c.UserID); err != nil {
				return nil, err
			}
		}
		if err := tx.SetIdentity(c.UserID, req.IdentityKey, version); err != nil {
			return nil, err
		}
		return a.emitKeysChanged(tx, c.UserID)
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"identityKey": req.IdentityKey, "identityVersion": version})
	return nil
}

// putDeviceKey registers the calling device's MLS signature key. It cannot
// change afterwards; a device with a new key signs in again as a new device.
func (a *API) putDeviceKey(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		MLSSigKey string `json:"mlsSigKey"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	if _, err := decodeKey(req.MLSSigKey, ed25519.PublicKeySize, "mlsSigKey"); err != nil {
		return err
	}
	err := a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		existing, err := tx.DeviceKey(c.SessionID)
		if err == nil {
			if existing.MLSSigKey != req.MLSSigKey {
				return nil, &Error{http.StatusConflict, "device_key_exists", "This device already registered a different key"}
			}
			return nil, nil
		} else if !errors.Is(err, store.ErrNotFound) {
			return nil, err
		}
		if err := tx.InsertDeviceKey(c.SessionID, c.UserID, req.MLSSigKey); err != nil {
			return nil, err
		}
		c.Log.Debug("device key registered")
		return a.emitKeysChanged(tx, c.UserID)
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

// putDeviceSignature stores the identity key's signature over one of the
// caller's own device records, marking that device as verified.
func (a *API) putDeviceSignature(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Signature string `json:"signature"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	sig, err := decodeKey(req.Signature, ed25519.SignatureSize, "signature")
	if err != nil {
		return err
	}
	deviceID := r.PathValue("id")
	err = a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		device, err := tx.DeviceKey(deviceID)
		if errors.Is(err, store.ErrNotFound) || (err == nil && device.UserID != c.UserID) {
			return nil, errNotFound
		} else if err != nil {
			return nil, err
		}
		identity, err := tx.UserKeys(c.UserID)
		if errors.Is(err, store.ErrNotFound) {
			return nil, &Error{http.StatusConflict, "no_identity", "Set up an encryption identity first"}
		} else if err != nil {
			return nil, err
		}
		pub, _ := base64.StdEncoding.DecodeString(identity.IdentityKey)
		if !ed25519.Verify(pub, protocol.DeviceRecordMessage(c.UserID, deviceID, device.MLSSigKey), sig) {
			return nil, &Error{http.StatusBadRequest, "bad_signature", "The signature does not match the identity key"}
		}
		if err := tx.SetDeviceSignature(deviceID, req.Signature, identity.IdentityVersion); err != nil {
			return nil, err
		}
		c.Log.Debug("device verified", "verified", deviceID, "identity_version", identity.IdentityVersion)
		return a.emitKeysChanged(tx, c.UserID)
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

type deviceKeyJSON struct {
	DeviceID      string  `json:"deviceId"`
	MLSSigKey     string  `json:"mlsSigKey"`
	Signature     *string `json:"signature,omitempty"`
	SignedVersion *int    `json:"signedVersion,omitempty"`
}

// userKeysJSON is a user's public keys, as GET /keys/users/{id} answers.
type userKeysJSON struct {
	UserID          string          `json:"userId"`
	IdentityKey     string          `json:"identityKey,omitempty"`
	IdentityVersion int             `json:"identityVersion,omitempty"`
	Devices         []deviceKeyJSON `json:"devices"`
}

// getUserKeys answers a user's keys: those of a user of another server, as
// their server says.
func (a *API) getUserKeys(w http.ResponseWriter, r *http.Request, c *Caller) error {
	userID := r.PathValue("id")
	var out *userKeysJSON
	var err error
	if a.remote(userID) {
		if !a.fed.Allowed(hostOf(userID)) {
			return errOtherServer
		}
		out, err = a.remoteUserKeys(r.Context(), userID)
	} else {
		out, err = a.localUserKeys(r.Context(), userID)
	}
	if err != nil {
		return err
	}
	signed := 0
	for _, d := range out.Devices {
		if d.Signature != nil {
			signed++
		}
	}
	c.Log.Debug("keys looked up", "of", userID, "identity_version", out.IdentityVersion, "devices", len(out.Devices),
		"signed", signed)
	writeJSON(w, http.StatusOK, out)
	return nil
}

func (a *API) localUserKeys(ctx context.Context, userID string) (*userKeysJSON, error) {
	if _, err := a.store.User(ctx, userID); errors.Is(err, store.ErrNotFound) {
		return nil, &Error{http.StatusNotFound, "user_not_found", ""}
	} else if err != nil {
		return nil, err
	}
	out := &userKeysJSON{UserID: userID, Devices: []deviceKeyJSON{}}
	if keys, err := a.store.UserKeys(ctx, userID); err == nil {
		out.IdentityKey = keys.IdentityKey
		out.IdentityVersion = keys.IdentityVersion
	} else if !errors.Is(err, store.ErrNotFound) {
		return nil, err
	}
	devices, err := a.store.DeviceKeysOf(ctx, userID)
	if err != nil {
		return nil, err
	}
	for _, d := range devices {
		out.Devices = append(out.Devices,
			deviceKeyJSON{DeviceID: d.DeviceID, MLSSigKey: d.MLSSigKey, Signature: d.Signature, SignedVersion: d.SignedVersion})
	}
	return out, nil
}

func (a *API) getSecretStorage(w http.ResponseWriter, r *http.Request, c *Caller) error {
	data, version, err := a.store.SecretStorage(r.Context(), c.UserID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"data": data, "identityVersion": version})
	return nil
}

// putSecretStorage stores the user's secrets, encrypted with their recovery
// key. The blob is opaque to the server.
func (a *API) putSecretStorage(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Data            string `json:"data"`
		IdentityVersion int    `json:"identityVersion"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	if req.Data == "" || len(req.Data) > maxSecretStorageBytes {
		return badRequest("data must be a non-empty string of at most 16 KiB")
	}
	err := a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		identity, err := tx.UserKeys(c.UserID)
		if errors.Is(err, store.ErrNotFound) || (err == nil && identity.IdentityVersion != req.IdentityVersion) {
			return nil, &Error{http.StatusConflict, "identity_changed", "The secrets belong to a different identity"}
		} else if err != nil {
			return nil, err
		}
		c.Log.Debug("recovery data stored", "identity_version", req.IdentityVersion)
		return nil, tx.PutSecretStorage(c.UserID, req.Data, req.IdentityVersion)
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

// Key backup: per-message content keys, encrypted by the user's devices with
// the backup secret, so a new device can read history. The server only
// stores them.

const (
	maxBackupEntries    = 500
	maxBackupEntryBytes = 512
)

func (a *API) putKeyBackup(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		IdentityVersion int `json:"identityVersion"`
		Entries         []struct {
			ID   string `json:"id"`
			Data string `json:"data"`
		} `json:"entries"`
	}
	if err := readJSONLimit(w, r, &req, 1<<20); err != nil {
		return err
	}
	if len(req.Entries) == 0 || len(req.Entries) > maxBackupEntries {
		return badRequest("send 1 to 500 entries")
	}
	entries := map[string]string{}
	for _, e := range req.Entries {
		if !protocol.IsULID(e.ID) {
			return badRequest("id must be a message ID")
		}
		if err := decodeBase64(e.Data, maxBackupEntryBytes, "data"); err != nil {
			return err
		}
		entries[e.ID] = e.Data
	}
	accepted, err := a.store.AddKeyBackup(r.Context(), c.UserID, req.IdentityVersion, entries)
	if errors.Is(err, store.ErrStaleIdentity) {
		return &Error{http.StatusConflict, "identity_changed", "The backup belongs to a different identity"}
	} else if err != nil {
		return err
	}
	c.Log.Debug("key backup stored", "identity_version", req.IdentityVersion, "entries", len(entries), "accepted", accepted)
	if accepted > 0 {
		a.hub.SendToOtherDevices(c.UserID, c.SessionID, map[string]any{"type": protocol.FrameBackup})
	}
	writeJSON(w, http.StatusOK, map[string]int{"accepted": accepted})
	return nil
}

func (a *API) queryKeyBackup(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		IDs []string `json:"ids"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	if len(req.IDs) == 0 || len(req.IDs) > maxBackupEntries {
		return badRequest("ask for 1 to 500 messages")
	}
	for _, id := range req.IDs {
		if !protocol.IsULID(id) {
			return badRequest("ids must be message IDs")
		}
	}
	entries, err := a.store.KeyBackup(r.Context(), c.UserID, req.IDs)
	if err != nil {
		return err
	}
	c.Log.Debug("key backup read", "asked", len(req.IDs), "found", len(entries))
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries})
	return nil
}

// conversationKeyBackup pages through the caller's entries for one
// conversation: what a device shares when it adds someone (all of the
// conversation's keys it can read).
func (a *API) conversationKeyBackup(w http.ResponseWriter, r *http.Request, c *Caller) error {
	ctx := r.Context()
	q := r.URL.Query()
	convID := q.Get("conv")
	if err := a.requireMember(ctx, convID, c); err != nil {
		return err
	}
	after, err := strconv.ParseInt(q.Get("after"), 10, 64)
	if err != nil {
		after = 0
	}
	entries, err := a.store.ConversationKeyBackup(ctx, c.UserID, convID, after, maxBackupEntries+1)
	if err != nil {
		return err
	}
	more := len(entries) > maxBackupEntries
	if more {
		entries = entries[:maxBackupEntries]
	}
	c.Log.Debug("key backup read", "conv", convID, "after", after, "entries", len(entries), "more", more)
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries, "more": more})
	return nil
}
