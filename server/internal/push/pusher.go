package push

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"sync"
	"time"

	"hanashi/server/internal/netguard"
	"hanashi/server/internal/store"
)

// Reason says why a device is woken; it sets how urgently the push service
// delivers.
type Reason int

const (
	// NewMessage: show a notification now (urgency "high").
	NewMessage Reason = iota + 1
	// ReadElsewhere: the user read a conversation on another device, so
	// its notification can go (urgency "normal").
	ReadElsewhere
	// StateNeeded: a group or profile changed in a way no notification comes
	// of, but that others wait for this device to act on (urgency "normal").
	StateNeeded
)

func (r Reason) String() string {
	switch r {
	case NewMessage:
		return "message"
	case ReadElsewhere:
		return "read"
	}
	return "state"
}

// What a push for a Reason carries, encrypted. Everything else comes from
// syncing.
var syncPayload = []byte(`{"type":"sync"}`)

// Message is one push: what it carries (encrypted, when the subscription
// has keys), and how the push service treats it.
type Message struct {
	Payload []byte
	// Urgency is "high" or "normal" (RFC 8030 section 5.3).
	Urgency string
	// Topic: a newer push of the same topic replaces one the service has
	// not delivered yet (RFC 8030 section 5.4).
	Topic string
	// TTL is how long the service keeps it for a device that is offline.
	TTL time.Duration
}

func (r Reason) message() Message {
	switch r {
	case NewMessage:
		return Message{Payload: syncPayload, Urgency: "high", Topic: "message", TTL: 24 * time.Hour}
	case StateNeeded:
		return Message{Payload: syncPayload, Urgency: "normal", Topic: "state", TTL: 24 * time.Hour}
	}
	return Message{Payload: syncPayload, Urgency: "normal", Topic: "read", TTL: time.Hour}
}

// Store is the part of the database the pusher needs.
type Store interface {
	PushSubscriptions(ctx context.Context, userIDs []string) ([]store.PushSubscription, error)
	DeletePushSubscription(ctx context.Context, deviceID, endpoint string) error
}

// Presence tells whether a device has a live connection (and needs no push).
type Presence interface {
	DeviceOnline(userID, deviceID string) bool
}

type Options struct {
	// AllowPrivate lets endpoints resolve to loopback and private addresses
	// (a push service on the local network). Off, users could make the
	// server send requests into its own network.
	AllowPrivate bool
	// MinInterval spaces out pushes to one device; events in between are
	// covered by the next push. Default 2 s.
	MinInterval time.Duration
}

// Pusher sends pushes in the background, at most one at a time per device.
type Pusher struct {
	store    Store
	presence Presence
	vapid    *VAPID
	client   *http.Client
	log      *slog.Logger
	interval time.Duration

	mu      sync.Mutex
	devices map[string]*deviceState
	wg      sync.WaitGroup
}

type deviceState struct {
	sub     store.PushSubscription
	pending Reason // 0 when nothing is waiting; NewMessage wins over ReadElsewhere
}

func New(st Store, presence Presence, vapid *VAPID, log *slog.Logger, opts Options) *Pusher {
	if opts.MinInterval == 0 {
		opts.MinInterval = 2 * time.Second
	}
	return &Pusher{
		store:    st,
		presence: presence,
		vapid:    vapid,
		client:   netguard.Client(opts.AllowPrivate, 30*time.Second),
		log:      log,
		interval: opts.MinInterval,
		devices:  map[string]*deviceState{},
	}
}

// VAPID is the key clients register with.
func (p *Pusher) VAPID() *VAPID { return p.vapid }

// Notify wakes every device of userIDs that is not connected, except
// exceptDevice (the one that caused the event).
func (p *Pusher) Notify(userIDs []string, exceptDevice string, reason Reason) {
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		subs, err := p.store.PushSubscriptions(ctx, userIDs)
		if err != nil {
			p.log.Warn("push: loading subscriptions", "err", err)
			return
		}
		for _, sub := range subs {
			if sub.DeviceID != exceptDevice && !p.presence.DeviceOnline(sub.UserID, sub.DeviceID) {
				p.enqueue(sub, reason)
			}
		}
	}()
}

// Send pushes msg to every subscribed device of userIDs except
// exceptDevice, at once and whether connected or not: for calls, which
// cannot wait for the next batch, and which an app frozen with its
// connection still open would miss.
func (p *Pusher) Send(userIDs []string, exceptDevice string, msg Message) {
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		subs, err := p.store.PushSubscriptions(ctx, userIDs)
		if err != nil {
			p.log.Warn("push: loading subscriptions", "err", err)
			return
		}
		for _, sub := range subs {
			if sub.DeviceID == exceptDevice {
				continue
			}
			p.wg.Add(1)
			go func() {
				defer p.wg.Done()
				p.send(sub, msg)
			}()
		}
	}()
}

// Wait blocks until every queued push has been attempted (for tests and
// shutdown).
func (p *Pusher) Wait() { p.wg.Wait() }

func (p *Pusher) enqueue(sub store.PushSubscription, reason Reason) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if state, ok := p.devices[sub.DeviceID]; ok {
		state.sub = sub
		if state.pending == 0 || reason < state.pending {
			state.pending = reason
		}
		return
	}
	state := &deviceState{sub: sub, pending: reason}
	p.devices[sub.DeviceID] = state
	p.wg.Add(1)
	go p.drain(sub.DeviceID, state)
}

// drain sends the device's pending push, then keeps sending, no faster than
// the interval, while more arrive.
func (p *Pusher) drain(deviceID string, state *deviceState) {
	defer p.wg.Done()
	for {
		p.mu.Lock()
		sub, reason := state.sub, state.pending
		state.pending = 0
		if reason == 0 {
			delete(p.devices, deviceID)
			p.mu.Unlock()
			return
		}
		p.mu.Unlock()
		p.send(sub, reason.message())
		time.Sleep(p.interval)
	}
}

func (p *Pusher) send(sub store.PushSubscription, msg Message) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var body []byte
	if sub.P256dh != "" && sub.Auth != "" {
		key, err1 := base64.RawURLEncoding.DecodeString(sub.P256dh)
		auth, err2 := base64.RawURLEncoding.DecodeString(sub.Auth)
		if err := errors.Join(err1, err2); err != nil {
			p.log.Warn("push: bad subscription keys", "device", sub.DeviceID, "err", err)
			return
		}
		encrypted, err := Encrypt(msg.Payload, key, auth)
		if err != nil {
			p.log.Warn("push: encrypting", "device", sub.DeviceID, "err", err)
			return
		}
		body = encrypted
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, sub.Endpoint, bytes.NewReader(body))
	if err != nil {
		p.log.Warn("push: bad endpoint", "device", sub.DeviceID, "err", err)
		return
	}
	authorization, err := p.vapid.Authorization(sub.Endpoint, time.Now())
	if err != nil {
		p.log.Warn("push: signing", "device", sub.DeviceID, "err", err)
		return
	}
	req.Header.Set("Authorization", authorization)
	if body != nil {
		req.Header.Set("Content-Type", "application/octet-stream")
		req.Header.Set("Content-Encoding", "aes128gcm")
	}
	req.Header.Set("Urgency", msg.Urgency)
	req.Header.Set("Topic", msg.Topic)
	req.Header.Set("TTL", strconv.Itoa(max(1, int(msg.TTL/time.Second))))
	resp, err := p.client.Do(req)
	if err != nil {
		p.log.Warn("push: sending", "device", sub.DeviceID, "err", err)
		return
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64*1024))
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		p.log.Debug("push: sent", "user", sub.UserID, "device", sub.DeviceID, "topic", msg.Topic)
	case resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone:
		// The subscription expired or was removed; the app registers again.
		if err := p.store.DeletePushSubscription(ctx, sub.DeviceID, sub.Endpoint); err != nil {
			p.log.Warn("push: removing expired subscription", "device", sub.DeviceID, "err", err)
		}
	default:
		p.log.Warn("push: rejected", "device", sub.DeviceID, "status", resp.StatusCode)
	}
}

// Setup loads the server's VAPID key, creating it on first start, and
// returns a Pusher that signs with it.
func Setup(ctx context.Context, st interface {
	Store
	ServerSecret(ctx context.Context, name string, create func() (string, error)) (string, error)
}, presence Presence, contact string, log *slog.Logger, opts Options) (*Pusher, error) {
	encoded, err := st.ServerSecret(ctx, "vapid_key", func() (string, error) {
		key, err := NewVAPIDKey()
		return base64.StdEncoding.EncodeToString(key), err
	})
	if err != nil {
		return nil, err
	}
	key, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	vapid, err := NewVAPID(key, contact)
	if err != nil {
		return nil, err
	}
	return New(st, presence, vapid, log, opts), nil
}
