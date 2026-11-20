package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"

	"hanashi/server/internal/protocol"
	"hanashi/server/internal/store"
)

// Emoji verification runs between two devices through their inboxes; the
// server only relays (the protocol is safe against a relay that cheats).
// Users can then store signed statements that they verified a contact.

const (
	maxDeviceMessageBytes = 16 * 1024
	maxAttestationBytes   = 4 * 1024
)

// sendToDevices delivers a device-to-device message to the inboxes of the
// caller's own other devices or of a contact's devices. Those of a user of
// another server get it from their server, in order (inbox.message).
func (a *API) sendToDevices(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		To []struct {
			User   string `json:"user"`
			Device string `json:"device"`
		} `json:"to"`
		Type string          `json:"type"`
		Data json.RawMessage `json:"data"`
	}
	if err := readJSONLimit(w, r, &req, 4*maxDeviceMessageBytes); err != nil {
		return err
	}
	if !strings.HasPrefix(req.Type, "verification.") || len(req.Type) > 64 {
		return badRequest("type must be a verification message")
	}
	data := bytes.TrimSpace(req.Data)
	if len(data) == 0 || data[0] != '{' || len(data) > maxDeviceMessageBytes {
		return badRequest("data must be a JSON object of at most 16 KiB")
	}
	if len(req.To) == 0 || len(req.To) > 10 {
		return badRequest("send to 1 to 10 recipients")
	}
	ctx := r.Context()
	type target struct{ user, device string }
	var targets, remote []target
	for _, to := range req.To {
		if to.User != c.UserID {
			// Only people the caller chats with, so strangers cannot be pestered.
			shares, err := a.store.SharesConversation(ctx, c.UserID, to.User)
			if err != nil {
				return err
			}
			if !shares {
				return &Error{http.StatusForbidden, "not_a_contact", "You can only verify people you chat with"}
			}
		}
		if a.remote(to.User) {
			if to.Device != "" && !protocol.IsULID(to.Device) {
				return &Error{http.StatusNotFound, "device_not_found", "No such device"}
			}
			remote = append(remote, target{to.User, to.Device})
			continue
		}
		sessions, err := a.store.SessionsOf(ctx, to.User)
		if err != nil {
			return err
		}
		found := false
		for _, s := range sessions {
			if s.ID == c.SessionID || (to.Device != "" && s.ID != to.Device) {
				continue
			}
			found = true
			targets = append(targets, target{to.User, s.ID})
		}
		if to.Device != "" && !found {
			return &Error{http.StatusNotFound, "device_not_found", "No such device"}
		}
	}
	devices := make([]string, len(targets))
	for i, t := range targets {
		devices[i] = t.device
	}
	items, err := a.store.AddInboxItems(ctx, devices, store.InboxItem{
		Type: req.Type, SenderUser: c.UserID, SenderDevice: c.SessionID, Payload: string(data),
	})
	if err != nil {
		return err
	}
	for i, item := range items {
		a.pushInbox(targets[i].user, targets[i].device, item)
	}
	if len(remote) > 0 {
		err := a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
			var sends []func()
			for _, t := range remote {
				send, err := a.tellServer(tx, t.user, map[string]any{"type": itemDeviceMessage, "to": t.user,
					"device": t.device, "messageType": req.Type, "data": json.RawMessage(data),
					"senderUser": c.UserID, "senderDevice": c.SessionID})
				if err != nil {
					return nil, err
				}
				sends = append(sends, send)
			}
			return func() {
				for _, send := range sends {
					send()
				}
			}, nil
		})
		if err != nil {
			return err
		}
	}
	c.Log.Debug("device message sent", "type", req.Type, "devices", len(items), "other_servers", len(remote))
	// Each one handed to another server counts as one.
	writeJSON(w, http.StatusOK, map[string]int{"delivered": len(items) + len(remote)})
	return nil
}

// takeDeviceMessage puts a device message from a user of origin into the
// inbox of a device of this server's user, by the same rule as sendToDevices:
// only from someone they chat with.
func (a *API) takeDeviceMessage(tx *store.Tx, origin string, m deviceMessageItem) ([]func(), error) {
	if !protocol.ValidUserID(m.SenderUser) || hostOf(m.SenderUser) != origin || !protocol.IsULID(m.SenderDevice) {
		return nil, badRequest("the sender must be of the server that sends it")
	}
	data := bytes.TrimSpace(m.Data)
	if !strings.HasPrefix(m.MessageType, "verification.") || len(m.MessageType) > 64 || len(data) == 0 ||
		data[0] != '{' || len(data) > maxDeviceMessageBytes {
		return nil, badRequest("Not a verification message")
	}
	if !protocol.ValidUserID(m.To) || a.remote(m.To) {
		return nil, &Error{http.StatusNotFound, "user_not_found", ""}
	}
	if shares, err := tx.SharesConversation(m.SenderUser, m.To); err != nil {
		return nil, err
	} else if !shares {
		return nil, errNotAContact
	}
	devices, err := tx.SessionIDs(m.To)
	if err != nil {
		return nil, err
	}
	if m.Device != "" {
		if !slices.Contains(devices, m.Device) {
			return nil, &Error{http.StatusNotFound, "device_not_found", ""}
		}
		devices = []string{m.Device}
	}
	var publish []func()
	for _, d := range devices {
		item, err := tx.AddInboxItem(d, store.InboxItem{
			Type: m.MessageType, SenderUser: m.SenderUser, SenderDevice: m.SenderDevice, Payload: string(data),
		})
		if err != nil {
			return nil, err
		}
		publish = append(publish, func() { a.pushInbox(m.To, d, item) })
	}
	return publish, nil
}

type deviceMessageItem struct {
	To           string          `json:"to"`
	Device       string          `json:"device"`
	MessageType  string          `json:"messageType"`
	Data         json.RawMessage `json:"data"`
	SenderUser   string          `json:"senderUser"`
	SenderDevice string          `json:"senderDevice"`
}

// putAttestation stores the caller's signed statement that it verified a
// user's identity key. Opaque to the server: the caller's devices check the
// signature.
func (a *API) putAttestation(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Data string `json:"data"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	if req.Data == "" || len(req.Data) > maxAttestationBytes {
		return badRequest("data must be a non-empty string of at most 4 KiB")
	}
	target := r.PathValue("user")
	if _, err := a.store.User(r.Context(), target); errors.Is(err, store.ErrNotFound) {
		return &Error{http.StatusNotFound, "user_not_found", "No user " + target}
	} else if err != nil {
		return err
	}
	if err := a.store.PutAttestation(r.Context(), c.UserID, target, req.Data); err != nil {
		return err
	}
	a.notifyOwnDevices(c)
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

func (a *API) getAttestations(w http.ResponseWriter, r *http.Request, c *Caller) error {
	attestations, err := a.store.Attestations(r.Context(), c.UserID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"attestations": attestations})
	return nil
}

// notifyOwnDevices tells the caller's other devices that its attestations
// changed, so they refetch them.
func (a *API) notifyOwnDevices(c *Caller) {
	a.hub.SendToOtherDevices(c.UserID, c.SessionID, map[string]any{"type": protocol.FrameTrust})
}
