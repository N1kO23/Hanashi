package api

import (
	"context"
	"net/http"
	"time"

	"hanashi/server/internal/hub"
	"hanashi/server/internal/protocol"
)

// Presence: who of the people a user shares a conversation with is online,
// idle, in focus or offline. It is kept in memory and only ever sent live,
// never stored as events.

// presenceChanged tells user's contacts their status, if it changed. It also
// runs after the connection's request is gone, so it has its own deadline.
func (a *API) presenceChanged(user string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	contacts, err := a.store.ConversationPeersOf(ctx, user)
	if err != nil {
		a.log.Debug("presence not told", "user", user, "err", err)
		return
	}
	status := a.hub.PublishPresence(user, contacts)
	a.tellPresence(user, status, contacts)
	a.log.Debug("presence", "user", user, "status", status)
}

// sendPresence sends conn the status of everyone its user shares a
// conversation with.
func (a *API) sendPresence(ctx context.Context, conn *hub.Conn) {
	contacts, err := a.store.ConversationPeersOf(ctx, conn.UserID)
	if err != nil {
		a.log.Debug("presence not sent", "user", conn.UserID, "err", err)
		return
	}
	a.hub.SendPresence(conn, contacts)
}

// getPresence returns how the caller chose to appear, for a device without a
// connection to hear it on (one woken by a push).
func (a *API) getPresence(w http.ResponseWriter, r *http.Request, c *Caller) error {
	mode, err := a.store.PresenceMode(r.Context(), c.UserID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"mode": mode})
	return nil
}

// putPresence sets how the caller appears to others: "auto" (online or idle),
// "focus" or "invisible" (offline).
func (a *API) putPresence(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Mode string `json:"mode"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	switch req.Mode {
	case protocol.ModeAuto, protocol.ModeFocus, protocol.ModeInvisible:
	default:
		return badRequest(`"mode" is auto, focus or invisible`)
	}
	if err := a.store.SetPresenceMode(r.Context(), c.UserID, req.Mode); err != nil {
		return err
	}
	a.hub.SetMode(c.UserID, req.Mode)
	a.presenceChanged(c.UserID)
	writeJSON(w, http.StatusOK, map[string]string{"mode": req.Mode})
	return nil
}
