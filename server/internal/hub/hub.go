// Package hub fans live frames out to every connected device.
package hub

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/coder/websocket"

	"hanashi/server/internal/protocol"
)

const (
	// A device this far behind is disconnected; it catches up via sync.
	sendBuffer   = 256
	writeTimeout = 10 * time.Second
)

// Conn is one authenticated WebSocket, i.e. one online device. Only its
// writer goroutine writes to the socket, so frames go out in queue order and
// a close never overtakes frames queued before it.
type Conn struct {
	UserID    string
	SessionID string

	ws          *websocket.Conn
	out         chan []byte
	quit        chan struct{} // Closed to request shutdown.
	done        chan struct{} // Closed once the writer has exited.
	closeOne    sync.Once
	closeCode   websocket.StatusCode
	closeReason string

	// The device is not in use (guarded by the hub's lock).
	idle bool
}

// NewConn starts the connection's writer goroutine.
func NewConn(ws *websocket.Conn, userID, sessionID string) *Conn {
	c := &Conn{
		UserID: userID, SessionID: sessionID, ws: ws,
		out: make(chan []byte, sendBuffer), quit: make(chan struct{}), done: make(chan struct{}),
	}
	go c.writeLoop()
	return c
}

func (c *Conn) writeLoop() {
	defer close(c.done)
	for {
		select {
		case msg := <-c.out:
			if !c.write(msg) {
				c.ws.CloseNow()
				return
			}
		case <-c.quit:
			// Flush what was queued before the close, then close.
			for {
				select {
				case msg := <-c.out:
					if !c.write(msg) {
						c.ws.CloseNow()
						return
					}
				default:
					_ = c.ws.Close(c.closeCode, c.closeReason)
					return
				}
			}
		}
	}
}

func (c *Conn) write(msg []byte) bool {
	ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
	defer cancel()
	return c.ws.Write(ctx, websocket.MessageText, msg) == nil
}

// Send queues a frame. It never blocks: a full queue closes the connection.
func (c *Conn) Send(frame any) {
	data, err := json.Marshal(frame)
	if err != nil {
		return
	}
	c.sendRaw(data)
}

func (c *Conn) sendRaw(data []byte) {
	select {
	case <-c.quit:
	case c.out <- data:
	default:
		c.Close(websocket.StatusPolicyViolation, "too slow")
	}
}

// Close asks the writer to flush queued frames and close the socket.
func (c *Conn) Close(code websocket.StatusCode, reason string) {
	c.closeOne.Do(func() {
		c.closeCode, c.closeReason = code, reason
		close(c.quit)
	})
}

// Done is closed once the connection has shut down.
func (c *Conn) Done() <-chan struct{} { return c.done }

type Hub struct {
	mu     sync.RWMutex
	byUser map[string]map[*Conn]struct{}

	// Presence: how each user chose to appear, and what their contacts and
	// own devices were last told.
	modes map[string]string
	told  map[string]told
	// The status of users of other servers, as their servers last said, until
	// it goes stale.
	remote map[string]remoteStatus
}

type told struct{ status, mode string }

type remoteStatus struct {
	status string
	until  time.Time
}

func New() *Hub {
	return &Hub{byUser: map[string]map[*Conn]struct{}{}, modes: map[string]string{}, told: map[string]told{},
		remote: map[string]remoteStatus{}}
}

// Add registers an online device; mode is how its user chose to appear, as
// stored (the hub's own copy wins once it has one: see SetMode).
func (h *Hub) Add(c *Conn, mode string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.modes[c.UserID]; !ok {
		h.modes[c.UserID] = mode
	}
	set := h.byUser[c.UserID]
	if set == nil {
		set = map[*Conn]struct{}{}
		h.byUser[c.UserID] = set
	}
	set[c] = struct{}{}
}

func (h *Hub) Remove(c *Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if set := h.byUser[c.UserID]; set != nil {
		delete(set, c)
		if len(set) == 0 {
			delete(h.byUser, c.UserID)
		}
	}
}

func (h *Hub) conns(users []string, except string) []*Conn {
	h.mu.RLock()
	defer h.mu.RUnlock()
	var out []*Conn
	for _, u := range users {
		if u == except {
			continue
		}
		for c := range h.byUser[u] {
			out = append(out, c)
		}
	}
	return out
}

// DeviceOnline reports whether the device has a live connection.
func (h *Hub) DeviceOnline(userID, deviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.byUser[userID] {
		if c.SessionID == deviceID {
			return true
		}
	}
	return false
}

// Publish sends an event to every device of every recipient, including the
// device that caused it.
func (h *Hub) Publish(ev protocol.SyncEvent, recipients []string) {
	data, err := json.Marshal(map[string]any{"type": protocol.FrameEvent, "event": ev})
	if err != nil {
		return
	}
	for _, c := range h.conns(recipients, "") {
		c.sendRaw(data)
	}
}

// SendToDevice sends a frame to one device of userID, if it is online.
func (h *Hub) SendToDevice(userID, deviceID string, frame any) {
	data, err := json.Marshal(frame)
	if err != nil {
		return
	}
	for _, c := range h.conns([]string{userID}, "") {
		if c.SessionID == deviceID {
			c.sendRaw(data)
		}
	}
}

// SendToOtherDevices sends a frame to every device of userID except
// exceptDevice.
func (h *Hub) SendToOtherDevices(userID, exceptDevice string, frame any) {
	data, err := json.Marshal(frame)
	if err != nil {
		return
	}
	for _, c := range h.conns([]string{userID}, "") {
		if c.SessionID != exceptDevice {
			c.sendRaw(data)
		}
	}
}

// Send sends a frame to every device of every user.
func (h *Hub) Send(users []string, frame any) {
	data, err := json.Marshal(frame)
	if err != nil {
		return
	}
	for _, c := range h.conns(users, "") {
		c.sendRaw(data)
	}
}

// Typing tells the other members that from is typing.
func (h *Hub) Typing(conv, from string, recipients []string) {
	data, _ := json.Marshal(map[string]any{"type": protocol.FrameTyping, "conv": conv, "user": from})
	for _, c := range h.conns(recipients, from) {
		c.sendRaw(data)
	}
}

// Presence. A user is offline without a connection or while invisible, in
// focus while they chose it, online while any of their devices is in use,
// and idle otherwise.

// status is user's status; the caller holds the lock.
func (h *Hub) status(user string) string {
	if r, ok := h.remote[user]; ok {
		return r.status
	}
	set := h.byUser[user]
	switch mode := h.modes[user]; {
	case len(set) == 0 || mode == protocol.ModeInvisible:
		return protocol.StatusOffline
	case mode == protocol.ModeFocus:
		return protocol.StatusFocus
	}
	for c := range set {
		if !c.idle {
			return protocol.StatusOnline
		}
	}
	return protocol.StatusIdle
}

// SetRemoteStatus records the status of a user of another server, as their
// server says, until until; offline forgets it.
func (h *Hub) SetRemoteStatus(user, status string, until time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if status == protocol.StatusOffline {
		delete(h.remote, user)
		return
	}
	h.remote[user] = remoteStatus{status, until}
}

// ExpireRemote forgets the statuses of users of other servers that went
// stale before now, whose servers no longer said them; it returns whose.
func (h *Hub) ExpireRemote(now time.Time) []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	var expired []string
	for user, r := range h.remote {
		if now.After(r.until) {
			delete(h.remote, user)
			expired = append(expired, user)
		}
	}
	return expired
}

// Present lists the users of this server who have a device online, and
// their status (none offline).
func (h *Hub) Present() map[string]string {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := map[string]string{}
	for user := range h.byUser {
		if s := h.status(user); s != protocol.StatusOffline {
			out[user] = s
		}
	}
	return out
}

// SetIdle records whether c's device is in use; it reports whether that changed.
func (h *Hub) SetIdle(c *Conn, idle bool) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	changed := c.idle != idle
	c.idle = idle
	return changed
}

// SetMode records how user chose to appear.
func (h *Hub) SetMode(user, mode string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.modes[user] = mode
}

// PublishPresence tells user's contacts their status, and their own devices
// also their mode, if that changed since they were last told. It returns the
// status.
func (h *Hub) PublishPresence(user string, contacts []string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := told{status: h.status(user), mode: h.modes[user]}
	before, ok := h.told[user]
	if ok && before == now {
		return now.status
	}
	h.told[user] = now
	if !ok || before.status != now.status {
		data, _ := json.Marshal(map[string]any{"type": protocol.FramePresence, "user": user, "status": now.status})
		for _, u := range contacts {
			if u == user {
				continue
			}
			for c := range h.byUser[u] {
				c.sendRaw(data)
			}
		}
	}
	data, _ := json.Marshal(map[string]any{
		"type": protocol.FramePresence, "user": user, "status": now.status, "mode": now.mode,
	})
	for c := range h.byUser[user] {
		c.sendRaw(data)
	}
	return now.status
}

// SendPresence sends c the status of each of contacts who is not offline,
// and the mode its user chose. Under the same lock as PublishPresence, so
// what it sends is never older than what follows it.
func (h *Hub) SendPresence(c *Conn, contacts []string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	statuses := map[string]string{}
	for _, u := range contacts {
		if s := h.status(u); s != protocol.StatusOffline {
			statuses[u] = s
		}
	}
	data, _ := json.Marshal(map[string]any{
		"type": protocol.FramePresence, "statuses": statuses, "mode": h.modes[c.UserID],
	})
	c.sendRaw(data)
}

// CloseSession disconnects a signed-out device.
func (h *Hub) CloseSession(userID, sessionID string) {
	for _, c := range h.conns([]string{userID}, "") {
		if c.SessionID == sessionID {
			h.Remove(c)
			c.Send(map[string]any{"type": protocol.FrameError, "error": "session_revoked"})
			c.Close(4001, "session revoked")
		}
	}
}

func (h *Hub) CloseAll() {
	h.mu.Lock()
	var all []*Conn
	for _, set := range h.byUser {
		for c := range set {
			all = append(all, c)
		}
	}
	h.byUser = map[string]map[*Conn]struct{}{}
	h.mu.Unlock()
	for _, c := range all {
		c.Close(websocket.StatusGoingAway, "server shutting down")
	}
}
