package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"hanashi/server/internal/federation"
	"hanashi/server/internal/protocol"
	"hanashi/server/internal/push"
	"hanashi/server/internal/store"
)

// Conversations across servers (see "Federation" in docs/protocol.md). One
// server orders each conversation, its hub: leases, epochs, GroupInfo and the
// order of events are its, as on one server. The servers of its other members
// mirror it, taking its events in the hub's order, and relay to it what their
// users ask of it.

const (
	itemConvEvent       = "conv.event"
	itemWelcome         = "inbox.welcome"
	itemMessagesDeleted = "messages.deleted"
	// How long a relayed request waits for this server's copy of what it made.
	mirrorWait = 10 * time.Second
	// Events a catch-up takes at a time, and about how many bytes of them.
	catchUpPage  = 500
	catchUpBytes = 2 << 20
)

var errNoClearAnswer = &Error{http.StatusGatewayTimeout, "no_clear_answer",
	"Their server took it, but this one has not heard back yet; try again"}

// directHub is the server that orders the direct chat of a and b: that of the
// one whose ID sorts first, which both servers work out alike, so two
// starting their chat at once cannot make two.
func directHub(a, b string) string { return hostOf(min(a, b)) }

// convEventJSON is an event of a conversation as its hub passes it on.
type convEventJSON struct {
	Type   string          `json:"type"`
	TS     int64           `json:"ts"`
	Data   json.RawMessage `json:"data"`
	MsgID  string          `json:"msgId,omitempty"`
	Sender string          `json:"sender,omitempty"`
}

// The hub's side

// appendConvEvent appends an event of conv that its members see, and passes
// it on to the servers of its members of other servers if this server orders
// it. What it returns wakes their senders.
func (a *API) appendConvEvent(tx *store.Tx, conv, typ string, data json.RawMessage, opts store.AppendOptions) (protocol.SyncEvent, func(), error) {
	return a.appendConvEventTo(tx, conv, typ, data, opts, nil)
}

// appendConvEventTo is appendConvEvent, also passing it on to the servers
// also (whose users were members until this event).
func (a *API) appendConvEventTo(tx *store.Tx, conv, typ string, data json.RawMessage, opts store.AppendOptions,
	also []string) (protocol.SyncEvent, func(), error) {
	ev, err := tx.AppendEvent(conv, typ, data, opts)
	if err != nil {
		return ev, nil, err
	}
	hub, _, err := tx.ConversationHub(conv)
	if err != nil || hub != "" {
		return ev, func() {}, err
	}
	hosts, err := tx.RemoteMemberHosts(conv, a.cfg.Host)
	if err != nil {
		return ev, nil, err
	}
	for _, host := range also {
		if !slices.Contains(hosts, host) {
			hosts = append(hosts, host)
		}
	}
	if len(hosts) == 0 {
		return ev, func() {}, nil
	}
	prev, err := tx.PreviousConvEvent(conv, ev.Seq)
	if err != nil {
		return ev, nil, err
	}
	item := map[string]any{"type": itemConvEvent, "conv": conv, "seq": ev.Seq, "prev": prev,
		"event": convEventJSON{Type: typ, TS: ev.TS, Data: data, MsgID: opts.MsgID, Sender: opts.Sender}}
	for _, host := range hosts {
		if err := federation.Enqueue(tx, host, item); err != nil {
			return ev, nil, err
		}
	}
	return ev, func() {
		for _, host := range hosts {
			a.fed.Wake(host)
		}
	}, nil
}

// remoteCaller is a user of origin acting through it, which vouches for them
// and their device.
func (a *API) remoteCaller(origin, user, device string) (*Caller, error) {
	if !protocol.ValidUserID(user) || hostOf(user) != origin || !protocol.IsULID(device) {
		return nil, badRequest("user and device must be of the server that asks")
	}
	return &Caller{UserID: user, SessionID: device, Log: a.log.With("user", user, "device", device, "origin", origin)}, nil
}

// requireHubHere refuses a request about a conversation this server does not
// order.
func (a *API) requireHubHere(ctx context.Context, conv string) error {
	hub, _, err := a.store.ConversationHub(ctx, conv)
	if errors.Is(err, store.ErrNotFound) || (err == nil && hub != "") {
		return errNotFound
	}
	return err
}

// answerConvQuery answers what a member's server relays to this hub, as the
// member would ask it here.
func (a *API) answerConvQuery(ctx context.Context, origin, kind string, body []byte) (any, error) {
	var req struct {
		User, Device, Conv, Lease string
		// Whom a member adds.
		Member   string
		Epoch    *int64
		Since    int64
		Data     string
		Envelope json.RawMessage
		Commit   *commitInput
		Request  *conversationRequest
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return nil, badRequest("Not a request")
	}
	if kind == "conv.events" {
		return a.answerCatchUp(ctx, origin, req.Conv, req.Since)
	}
	c, err := a.remoteCaller(origin, req.User, req.Device)
	if err != nil {
		return nil, err
	}
	if kind == "conv.create" {
		if req.Request == nil {
			return nil, badRequest("request is required")
		}
		return a.newConversation(ctx, c, *req.Request)
	}
	if kind == "conv.message" {
		var env struct{ Conv string }
		if json.Unmarshal(req.Envelope, &env) != nil {
			return nil, badRequest("The envelope must be an envelope")
		}
		req.Conv = env.Conv
	}
	if err := a.requireHubHere(ctx, req.Conv); err != nil {
		return nil, err
	}
	switch kind {
	case "conv.message":
		seq, err := a.postMessage(ctx, c, req.Envelope)
		return map[string]int64{"seq": seq}, err
	case "conv.lease":
		return a.lease(ctx, c, req.Conv, req.Epoch)
	case "conv.release":
		return struct{}{}, a.release(ctx, c, req.Conv, req.Lease)
	case "conv.commit":
		if req.Commit == nil {
			return nil, badRequest("commit is required")
		}
		seq, err := a.commit(ctx, c, req.Conv, *req.Commit)
		return map[string]int64{"seq": seq}, err
	case "conv.group_info":
		return a.groupInfoOf(ctx, c, req.Conv)
	case "conv.state":
		return struct{}{}, a.sealState(ctx, c, req.Conv, req.Epoch, req.Data)
	case "conv.add_member":
		if req.Commit == nil {
			return nil, badRequest("commit is required")
		}
		info, seq, err := a.addMemberTo(ctx, c, req.Conv, req.Member, *req.Commit)
		return map[string]any{"conversation": info, "seq": seq}, err
	case "conv.leave":
		seq, err := a.leaveConv(ctx, c, req.Conv)
		return map[string]int64{"seq": seq}, err
	}
	return nil, errNotFound
}

// answerCatchUp gives a member's server the events of conv after since, for
// its copy.
func (a *API) answerCatchUp(ctx context.Context, origin, conv string, since int64) (any, error) {
	if err := a.requireHubHere(ctx, conv); err != nil {
		return nil, err
	}
	hosts, err := a.store.RemoteMemberHosts(ctx, conv, a.cfg.Host)
	if err != nil {
		return nil, err
	}
	if !slices.Contains(hosts, origin) {
		return nil, errNotFound
	}
	events, err := a.store.ConvEventsSince(ctx, conv, since, catchUpPage+1)
	if err != nil {
		return nil, err
	}
	more := len(events) > catchUpPage
	if more {
		events = events[:catchUpPage]
	}
	size := 0
	for i, e := range events {
		if size += len(e.Data); i > 0 && size > catchUpBytes {
			events, more = events[:i], true
			break
		}
	}
	type eventJSON struct {
		Seq int64 `json:"seq"`
		convEventJSON
	}
	out := make([]eventJSON, 0, len(events))
	for _, e := range events {
		out = append(out, eventJSON{e.Seq, convEventJSON{e.Type, e.TS, e.Data, e.MsgID, e.Sender}})
	}
	return map[string]any{"events": out, "more": more}, nil
}

// A member's side

// relay asks hub what c asked of this server, as c, and passes the hub's
// answer back: its refusals unchanged, as apps go by them.
func (a *API) relay(ctx context.Context, c *Caller, hub, kind string, req map[string]any, out any) error {
	req["user"], req["device"] = c.UserID, c.SessionID
	err := a.fed.Query(ctx, hub, kind, req, out)
	if err == nil {
		return nil
	}
	c.Log.Debug("relayed request failed", "hub", hub, "kind", kind, "err", err)
	var fedErr *federation.Error
	switch {
	case errors.Is(err, federation.ErrNotAllowed):
		return errOtherServer
	case errors.As(err, &fedErr) && (fedErr.Code == "not_signed" || fedErr.Code == "not_allowed" || fedErr.Code == "federation_off"):
		return errOtherServer
	case errors.As(err, &fedErr) && fedErr.Status < http.StatusInternalServerError:
		return &Error{fedErr.Status, fedErr.Code, fedErr.Message}
	default:
		return errServerUnreachable
	}
}

// mirrorHub is the server that orders conv, when it is not this one; "" if
// it is (or there is no such conversation).
func (a *API) mirrorHub(ctx context.Context, conv string) (string, error) {
	hub, _, err := a.store.ConversationHub(ctx, conv)
	if errors.Is(err, store.ErrNotFound) {
		return "", nil
	}
	return hub, err
}

// mirrorWaiters wake requests waiting for a conversation's copy to move on.
type mirrorWaiters struct {
	mu      sync.Mutex
	waiting map[string][]chan struct{}
}

func (m *mirrorWaiters) wait(conv string) <-chan struct{} {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.waiting == nil {
		m.waiting = map[string][]chan struct{}{}
	}
	ch := make(chan struct{})
	m.waiting[conv] = append(m.waiting[conv], ch)
	return ch
}

func (m *mirrorWaiters) moved(conv string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, ch := range m.waiting[conv] {
		close(ch)
	}
	delete(m.waiting, conv)
}

// waitMirror waits until this server's copy of conv has the hub's event
// hubSeq, and answers its seq here.
func (a *API) waitMirror(ctx context.Context, conv string, hubSeq int64) (int64, error) {
	deadline := time.After(mirrorWait)
	for {
		moved := a.mirrors.wait(conv)
		seq, err := a.store.SeqOfHubEvent(ctx, conv, hubSeq)
		if err == nil {
			return seq, nil
		} else if !errors.Is(err, store.ErrNotFound) {
			return 0, err
		}
		if _, at, err := a.store.ConversationHub(ctx, conv); err == nil && at >= hubSeq {
			return 0, errNoClearAnswer // Taken, and gone since (a deleted message).
		}
		select {
		case <-moved:
		case <-deadline:
			return 0, errNoClearAnswer
		case <-ctx.Done():
			return 0, ctx.Err()
		}
	}
}

// waitMirrorOf waits until this server has a copy of conv.
func (a *API) waitMirrorOf(ctx context.Context, conv string) error {
	deadline := time.After(mirrorWait)
	for {
		moved := a.mirrors.wait(conv)
		if _, _, err := a.store.ConversationHub(ctx, conv); err == nil {
			return nil
		} else if !errors.Is(err, store.ErrNotFound) {
			return err
		}
		select {
		case <-moved:
		case <-deadline:
			return errNoClearAnswer
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// relayMessage sends c's message in a conversation another server orders.
func (a *API) relayMessage(ctx context.Context, c *Caller, hub, conv string, raw json.RawMessage) (int64, error) {
	if err := a.requireMember(ctx, conv, c); err != nil {
		return 0, err
	}
	var out struct{ Seq int64 }
	if err := a.relay(ctx, c, hub, "conv.message", map[string]any{"envelope": raw}, &out); err != nil {
		return 0, err
	}
	return a.waitMirror(ctx, conv, out.Seq)
}

// relayCommit sends c's commit to a conversation another server orders,
// saying whose each Welcome's device is.
func (a *API) relayCommit(ctx context.Context, c *Caller, hub, conv string, in commitInput) (int64, error) {
	if err := a.requireMember(ctx, conv, c); err != nil {
		return 0, err
	}
	a.markWelcomes(ctx, in.Welcomes)
	var out struct{ Seq int64 }
	if err := a.relay(ctx, c, hub, "conv.commit", map[string]any{"conv": conv, "commit": in}, &out); err != nil {
		return 0, err
	}
	return a.waitMirror(ctx, conv, out.Seq)
}

// relayAdd adds user to a group another server orders. Whoever is added must
// be a contact of whoever adds: this server can tell, the hub may not.
func (a *API) relayAdd(ctx context.Context, c *Caller, hub, conv, user string, in commitInput) (*protocol.ConversationInfo, int64, error) {
	if ok, err := a.store.IsContact(ctx, c.UserID, user); err != nil {
		return nil, 0, err
	} else if !ok {
		return nil, 0, errNotAContact
	}
	a.markWelcomes(ctx, in.Welcomes)
	var out struct {
		Seq int64 `json:"seq"`
	}
	req := map[string]any{"conv": conv, "member": user, "commit": in}
	if err := a.relay(ctx, c, hub, "conv.add_member", req, &out); err != nil {
		return nil, 0, err
	}
	seq, err := a.waitMirror(ctx, conv, out.Seq)
	if err != nil {
		return nil, 0, err
	}
	info, err := a.store.Conversation(ctx, conv)
	return info, seq, err
}

// relayLeave takes c out of a group another server orders.
func (a *API) relayLeave(ctx context.Context, c *Caller, hub, conv string) (int64, error) {
	var out struct {
		Seq int64 `json:"seq"`
	}
	if err := a.relay(ctx, c, hub, "conv.leave", map[string]any{"conv": conv}, &out); err != nil {
		return 0, err
	}
	return a.waitMirror(ctx, conv, out.Seq)
}

// markWelcomes says whose each device is, for the hub, which may not know
// the devices of this server's users.
func (a *API) markWelcomes(ctx context.Context, welcomes []welcomeInput) {
	for i, w := range welcomes {
		if owner, err := a.store.SessionOwner(ctx, w.Device); err == nil {
			welcomes[i].User = owner
		} else if owner, err := a.store.RemoteDeviceOwner(ctx, w.Device); err == nil {
			welcomes[i].User = owner
		}
	}
}

// Taking the hub's events

type convEventItem struct {
	Conv  string        `json:"conv"`
	Seq   int64         `json:"seq"`
	Prev  int64         `json:"prev"`
	Event convEventJSON `json:"event"`
}

// takeConvEvent takes an event of a conversation origin orders into this
// server's copy, in the hub's order: a repeat changes nothing, and a gap is
// filled from the hub once the transaction is done.
func (a *API) takeConvEvent(tx *store.Tx, origin string, it convEventItem) ([]func(), error) {
	hub, at, err := tx.ConversationHub(it.Conv)
	switch {
	case errors.Is(err, store.ErrNotFound):
		if it.Event.Type != protocol.EventConversationCreated || it.Prev != 0 {
			return a.catchUpLater(origin, it.Conv), nil // Its start is missing.
		}
	case err != nil:
		return nil, err
	case hub != origin:
		return nil, &Error{http.StatusForbidden, "not_the_hub", "That server does not order this conversation"}
	case it.Seq <= at:
		return nil, nil
	case it.Prev > at:
		return a.catchUpLater(origin, it.Conv), nil
	}
	return a.mirrorEvent(tx, origin, it.Conv, it.Seq, it.Event)
}

// mirrorEvent appends the hub's event seq of conv here, and does for this
// server's users what the hub does for its own. A conversation_created makes
// the copy; member_added and member_removed change who of it is in it. While
// nobody of this server is, its messages are kept as history only, for
// whoever of it joins later: never sent to anyone as new.
func (a *API) mirrorEvent(tx *store.Tx, hub, conv string, seq int64, ev convEventJSON) ([]func(), error) {
	if ev.Type == protocol.EventConversationCreated {
		if _, _, err := tx.ConversationHub(conv); errors.Is(err, store.ErrNotFound) {
			if err := a.createMirror(tx, hub, conv, ev.Data); err != nil {
				return nil, err
			}
		} else if err != nil {
			return nil, err
		}
	}
	leaver, err := a.mirrorMembers(tx, conv, ev)
	if err != nil {
		return nil, err
	}
	var commit struct {
		Epoch  int64  `json:"epoch"`
		Device string `json:"device"`
		State  string `json:"state"`
	}
	if ev.Type == protocol.EventMLSCommit {
		if err := json.Unmarshal(ev.Data, &commit); err != nil {
			return nil, badRequest("A commit must say its epoch")
		}
		if err := tx.SetConversationEpoch(conv, commit.Epoch+1); err != nil {
			return nil, err
		}
	}
	if err := tx.SetHubSeq(conv, seq); err != nil {
		return nil, err
	}
	if ev.MsgID != "" {
		if _, err := tx.MessageByID(ev.MsgID); err == nil {
			// Its ID is taken here: a repeat of what this copy has, or a
			// clash with another message, which this copy goes without.
			return nil, nil
		} else if !errors.Is(err, store.ErrNotFound) {
			return nil, err
		}
	}
	members, err := tx.MemberIDs(conv)
	if err != nil {
		return nil, err
	}
	ours := slices.DeleteFunc(slices.Clone(members), a.remote)
	opts := store.AppendOptions{MsgID: ev.MsgID, Sender: ev.Sender, HubSeq: seq, TS: ev.TS}
	var publish []func()
	if leaver != "" {
		// No longer a member, they get their own copy, as on the hub.
		own := opts
		own.TargetUser = leaver
		theirs, err := tx.AppendEvent(conv, protocol.EventMemberRemoved, ev.Data, own)
		if err != nil {
			return nil, err
		}
		publish = append(publish, func() { a.hub.Publish(theirs, []string{leaver}) })
	}
	if len(ours) == 0 {
		if ev.Type == protocol.EventMessage {
			opts.TargetUser = store.HistoryOnly
			if _, err := tx.AppendEvent(conv, ev.Type, ev.Data, opts); err != nil {
				return nil, err
			}
		}
		return append(publish, func() { a.mirrors.moved(conv) }), nil
	}
	local, err := tx.AppendEvent(conv, ev.Type, ev.Data, opts)
	if err != nil {
		return nil, err
	}
	return append(publish, func() {
		a.hub.Publish(local, members)
		others := slices.DeleteFunc(slices.Clone(ours), func(m string) bool { return m == ev.Sender })
		switch {
		case ev.Type == protocol.EventMessage:
			a.push.Notify(others, "", push.NewMessage)
		case ev.Type == protocol.EventControl:
			a.push.Notify(others, "", push.StateNeeded)
		case ev.Type == protocol.EventMLSCommit && commit.State == "":
			a.push.Notify(ours, commit.Device, push.StateNeeded)
		}
		a.mirrors.moved(conv)
	}), nil
}

// mirrorMembers changes who is in this server's copy of conv as a
// member_added or member_removed says: anyone the hub adds, except users of
// this server added by someone who is not their contact, who never get in.
// It answers a user of this server who is out now.
func (a *API) mirrorMembers(tx *store.Tx, conv string, ev convEventJSON) (string, error) {
	if ev.Type != protocol.EventMemberAdded && ev.Type != protocol.EventMemberRemoved {
		return "", nil
	}
	var change struct {
		User string `json:"user"`
		By   string `json:"by"`
	}
	if err := json.Unmarshal(ev.Data, &change); err != nil || !protocol.ValidUserID(change.User) {
		return "", badRequest("A change of members must say whose")
	}
	members, err := tx.MemberIDs(conv)
	if err != nil {
		return "", err
	}
	in := slices.Contains(members, change.User)
	if ev.Type == protocol.EventMemberRemoved {
		if !in {
			return "", nil
		}
		if err := tx.RemoveMember(conv, change.User); err != nil {
			return "", err
		}
		if a.remote(change.User) {
			return "", nil
		}
		return change.User, nil
	}
	if in {
		return "", nil
	}
	if a.remote(change.User) {
		if err := tx.EnsureRemoteUser(change.User); err != nil {
			return "", err
		}
	} else if requireContact(tx, change.User, change.By) != nil {
		a.log.Info("federation: not taken into a group by a stranger", "conv", conv, "user", change.User, "by", change.By)
		return "", nil
	}
	return "", tx.AddMember(conv, change.User)
}

// createMirror makes this server's copy of a conversation hub orders, from
// its conversation_created event. A direct chat's hub is directHub of the
// two, a group's its creator's server. Users of this server are in it only
// with a contact of theirs who made it (in a direct chat, the other).
func (a *API) createMirror(tx *store.Tx, hub, conv string, data json.RawMessage) error {
	var created struct {
		Conversation protocol.ConversationInfo `json:"conversation"`
		By           string                    `json:"by"`
	}
	if err := json.Unmarshal(data, &created); err != nil || created.Conversation.ID != conv ||
		len(created.Conversation.Members) < 2 {
		return badRequest("Not the start of a conversation")
	}
	var members []string
	for _, m := range created.Conversation.Members {
		if !protocol.ValidUserID(m.ID) {
			return badRequest("Members must be users")
		}
		members = append(members, m.ID)
	}
	slices.Sort(members)
	if !slices.Contains(members, created.By) {
		return badRequest("by must be a member")
	}
	var directKey *string
	if created.Conversation.IsDirect {
		if len(members) != 2 || directHub(members[0], members[1]) != hub || !a.remote(members[0]) && !a.remote(members[1]) {
			return &Error{http.StatusForbidden, "not_the_hub", "That server does not order this chat"}
		}
		key := strings.Join(members, "|")
		directKey = &key
	} else if hostOf(created.By) != hub {
		return &Error{http.StatusForbidden, "not_the_hub", "A group is ordered by its creator's server"}
	}
	var kept []string
	for _, m := range members {
		if a.remote(m) {
			if err := tx.EnsureRemoteUser(m); err != nil {
				return err
			}
			kept = append(kept, m)
			continue
		}
		from := created.By
		if created.Conversation.IsDirect {
			from = members[0]
			if from == m {
				from = members[1]
			}
		}
		if _, err := tx.User(m); errors.Is(err, store.ErrNotFound) {
			continue
		} else if err != nil {
			return err
		}
		if requireContact(tx, m, from) != nil {
			a.log.Info("federation: not taken into a chat by a stranger", "conv", conv, "user", m, "by", from)
			continue
		}
		kept = append(kept, m)
	}
	if err := tx.CreateMirror(conv, hub, created.By, kept, directKey, 0); store.IsDuplicate(err) {
		return &Error{http.StatusConflict, "id_taken", "There is such a conversation here already"}
	} else if err != nil {
		return err
	}
	a.log.Debug("federation: conversation mirrored", "conv", conv, "hub", hub, "members", len(kept))
	return nil
}

// catchUpLater fills a gap in this server's copy of conv from its hub, once
// the transaction that found it is done.
func (a *API) catchUpLater(hub, conv string) []func() {
	return []func(){func() { go a.catchUp(hub, conv) }}
}

// catchUp takes from hub the events of conv this server's copy lacks, one
// catch-up per conversation at a time; one asked for meanwhile runs once it
// is done.
func (a *API) catchUp(hub, conv string) {
	again := &atomic.Bool{}
	if running, busy := a.catchingUp.LoadOrStore(conv, again); busy {
		running.(*atomic.Bool).Store(true)
		return
	}
	defer a.catchingUp.Delete(conv)
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	for {
		_, since, err := a.store.ConversationHub(ctx, conv)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			a.log.Warn("federation: catching up", "conv", conv, "err", err)
			return
		}
		var page struct {
			Events []struct {
				Seq int64 `json:"seq"`
				convEventJSON
			} `json:"events"`
			More bool `json:"more"`
		}
		if err := a.fed.Query(ctx, hub, "conv.events", map[string]any{"conv": conv, "since": since}, &page); err != nil {
			a.log.Info("federation: could not catch up", "conv", conv, "hub", hub, "err", err)
			return
		}
		a.log.Debug("federation: catching up", "conv", conv, "since", since, "events", len(page.Events))
		err = a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
			var publish []func()
			for _, e := range page.Events {
				// One after another from where this copy is: in order.
				_, at, err := tx.ConversationHub(conv)
				if err != nil && !errors.Is(err, store.ErrNotFound) {
					return nil, err
				}
				if e.Seq <= at {
					continue
				}
				done, err := a.mirrorEvent(tx, hub, conv, e.Seq, e.convEventJSON)
				if err != nil {
					return nil, err
				}
				publish = append(publish, done...)
			}
			return func() {
				for _, p := range publish {
					p()
				}
			}, nil
		})
		if err != nil {
			a.log.Warn("federation: taking what was caught up", "conv", conv, "err", err)
			return
		}
		if !page.More && !again.Swap(false) {
			return
		}
	}
}

// Welcomes and deletions

type welcomeItem struct {
	User, Device, Conv       string
	Epoch                    int64
	Data, State              string
	SenderUser, SenderDevice string
}

// takeWelcome puts a Welcome from a conversation origin orders into the
// inbox of a device of this server's user: from one of their own devices, or
// a contact of theirs (who adds them); or in a conversation this server
// mirrors from origin, for a member. The device itself checks who it is from.
func (a *API) takeWelcome(tx *store.Tx, origin string, w welcomeItem) ([]func(), error) {
	if a.remote(w.User) || !protocol.IsULID(w.Device) {
		return nil, &Error{http.StatusNotFound, "user_not_found", ""}
	}
	if owner, err := tx.SessionOwner(w.Device); errors.Is(err, store.ErrNotFound) || (err == nil && owner != w.User) {
		return nil, &Error{http.StatusNotFound, "device_not_found", ""}
	} else if err != nil {
		return nil, err
	}
	hub, _, err := tx.ConversationHub(w.Conv)
	member := false
	switch {
	case errors.Is(err, store.ErrNotFound):
	case err != nil:
		return nil, err
	case hub != origin:
		return nil, &Error{http.StatusForbidden, "not_the_hub", "That server does not order this conversation"}
	default:
		members, err := tx.MemberIDs(w.Conv)
		if err != nil {
			return nil, err
		}
		member = slices.Contains(members, w.User)
	}
	if !member && w.SenderUser != w.User {
		if err := requireContact(tx, w.User, w.SenderUser); err != nil {
			return nil, err
		}
	}
	fields := map[string]any{"conv": w.Conv, "epoch": w.Epoch, "data": w.Data}
	if w.State != "" {
		fields["state"] = w.State
	}
	payload, _ := json.Marshal(fields)
	item, err := tx.AddInboxItem(w.Device, store.InboxItem{
		Type: protocol.InboxWelcome, SenderUser: w.SenderUser, SenderDevice: w.SenderDevice, Payload: string(payload),
	})
	if err != nil {
		return nil, err
	}
	return []func(){func() { a.pushInbox(w.User, w.Device, item) }}, nil
}

// tellDeleted tells the servers of the other members of convs that user
// deleted messages ids.
func (a *API) tellDeleted(tx *store.Tx, user string, ids []string, convs []string) (func(), error) {
	var hosts []string
	for _, conv := range convs {
		of, err := tx.RemoteMemberHosts(conv, a.cfg.Host)
		if err != nil {
			return nil, err
		}
		for _, host := range of {
			if !slices.Contains(hosts, host) {
				hosts = append(hosts, host)
			}
		}
	}
	for _, host := range hosts {
		if err := federation.Enqueue(tx, host, map[string]any{"type": itemMessagesDeleted, "user": user, "ids": ids}); err != nil {
			return nil, err
		}
	}
	return func() {
		for _, host := range hosts {
			a.fed.Wake(host)
		}
	}, nil
}
