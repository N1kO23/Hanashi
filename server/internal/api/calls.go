package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"hanashi/server/internal/livekit"
	"hanashi/server/internal/protocol"
	"hanashi/server/internal/push"
	"hanashi/server/internal/store"
)

// Calls (docs/calls.md). The server keeps each conversation's voice call,
// signs the tokens apps join its LiveKit room with, and follows what LiveKit
// says about who is in it: by webhook, and by asking LiveKit now and then,
// as webhooks can get lost. The audio is end-to-end encrypted by the apps;
// neither this server nor LiveKit can hear it.
//
// Every change runs under the event-append lock, so changes, and the frames
// and pushes telling of them, go out in order. LiveKit is called outside it.

// liveKitWebhookPath is where LiveKit sends its webhooks.
const liveKitWebhookPath = "/livekit/webhook"

const (
	// callTokenTTL is how long a join token lets an app into the call's room;
	// once in, LiveKit renews it.
	callTokenTTL = 10 * time.Minute
	// callJoinWindow: a call nobody got into by then failed.
	callJoinWindow = 30 * time.Second
	// callKeepEnded: GET /calls includes calls that ended this recently.
	callKeepEnded = 24 * time.Hour
	// callPurgeAfter: calls that ended longer ago are forgotten.
	callPurgeAfter = 7 * 24 * time.Hour
)

var (
	errCallsOff         = &Error{http.StatusNotFound, "calls_off", "This server has no calls"}
	errCallsUnavailable = &Error{http.StatusConflict, "calls_unavailable",
		"Calls with people of other servers come later"}
	errCallEnded = &Error{http.StatusConflict, "call_ended", "That call has ended"}
)

func (a *API) liveKitKeys() livekit.Keys {
	return livekit.Keys{APIKey: a.cfg.LiveKitAPIKey, Secret: a.cfg.LiveKitAPISecret}
}

// callIdentity is who a device is in LiveKit's rooms: the same as its MLS
// credential, so that apps can tell whether someone in a call belongs there.
func callIdentity(user, device string) string { return user + "/" + device }

func parseCallIdentity(identity string) (user, device string, ok bool) {
	i := strings.LastIndex(identity, "/")
	if i < 0 {
		return "", "", false
	}
	user, device = identity[:i], identity[i+1:]
	return user, device, protocol.ValidUserID(user) && protocol.IsULID(device)
}

func (a *API) callRingTimeout() time.Duration {
	if a.cfg.CallRingTimeout > 0 {
		return a.cfg.CallRingTimeout
	}
	return 45 * time.Second
}

// liveKitLater calls LiveKit's room API in the background: what it does only
// tidies LiveKit up after a change this server already made.
func (a *API) liveKitLater(what string, call func(ctx context.Context, client *livekit.Client) error) {
	if a.calls == nil {
		return
	}
	a.liveKitOps.Add(1)
	go func() {
		defer a.liveKitOps.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := call(ctx, a.calls); err != nil {
			a.log.Warn("calls: LiveKit", "what", what, "err", err)
		}
	}()
}

func (a *API) deleteRoomLater(room string) {
	a.liveKitLater("delete room", func(ctx context.Context, c *livekit.Client) error { return c.DeleteRoom(ctx, room) })
}

func (a *API) removeFromRoomLater(room, identity string) {
	a.liveKitLater("remove participant", func(ctx context.Context, c *livekit.Client) error {
		return c.RemoveParticipant(ctx, room, identity)
	})
}

// callChanged tells the devices of the call's conversation's members.
func (a *API) callChanged(call *store.Call, members []string) {
	a.hub.Send(members, map[string]any{"type": protocol.FrameCall, "call": call.Wire()})
}

// callTopic: a newer push about a call replaces an undelivered one of it.
func callTopic(call *store.Call) string { return "call" + call.ID }

// ring wakes user's devices for a direct call: every subscribed one, as an
// app frozen with its connection open would miss the frame.
func (a *API) ring(user string, call *store.Call) {
	payload, err := json.Marshal(map[string]any{"type": "call", "call": call.Wire()})
	if err != nil {
		return
	}
	a.push.Send([]string{user}, "", push.Message{
		Payload: payload, Urgency: "high", Topic: callTopic(call), TTL: time.Until(time.UnixMilli(call.RingUntil)),
	})
}

// stopRinging tells user's devices but except to stop ringing: why ("answered"
// or how the call ended). A missed or cancelled call shows as missed, so its
// push is urgent and kept a day; the others only stop a ring.
func (a *API) stopRinging(user string, call *store.Call, reason, except string) {
	payload, err := json.Marshal(map[string]any{"type": "call_stop", "call": call.ID, "conv": call.Conv, "reason": reason})
	if err != nil {
		return
	}
	msg := push.Message{Payload: payload, Urgency: "normal", Topic: callTopic(call), TTL: time.Minute}
	if reason == protocol.CallMissed || reason == protocol.CallCancelled {
		msg.Urgency, msg.TTL = "high", 24*time.Hour
	}
	a.push.Send([]string{user}, except, msg)
}

// callee is who a direct call rings.
func callee(tx *store.Tx, call *store.Call) (string, error) {
	return tx.DirectPartner(call.Conv, call.StartedBy)
}

// settle ends a call its participants left: a direct call its caller left
// before an answer is cancelled; an answered one ends once either side has
// no device left; a group call once nobody is left. It reports whether the
// call ended.
func settle(call *store.Call, now int64) bool {
	if !call.Active() || call.FirstJoinedAt == 0 {
		return false
	}
	users := map[string]bool{}
	for _, p := range call.Participants {
		users[p.User] = true
	}
	switch {
	case call.Direct && call.AnsweredAt == 0 && !users[call.StartedBy]:
		call.EndedAt, call.Reason = now, protocol.CallCancelled
	case call.Direct && call.AnsweredAt != 0 && len(users) < 2:
		call.EndedAt, call.Reason = now, protocol.CallEnded
	case !call.Direct && len(users) == 0:
		call.EndedAt, call.Reason = now, protocol.CallEnded
	default:
		return false
	}
	return true
}

// saveChange writes a call that changed and returns what tells of it: the
// frame to the members, the end of a ring, and once it ended, closing its
// room.
func (a *API) saveChange(tx *store.Tx, call *store.Call) (func(), error) {
	if err := tx.SaveCall(call); err != nil {
		return nil, err
	}
	members, err := tx.MemberIDs(call.Conv)
	if err != nil {
		return nil, err
	}
	var ringing string
	if call.Direct && !call.Active() && call.AnsweredAt == 0 {
		if ringing, err = callee(tx, call); err != nil {
			return nil, err
		}
	}
	changed := *call
	return func() {
		a.callChanged(&changed, members)
		if ringing != "" {
			a.stopRinging(ringing, &changed, changed.Reason, "")
		}
		if !changed.Active() {
			a.deleteRoomLater(changed.ID)
		}
	}, nil
}

func memberOf(tx *store.Tx, conv, user string) (bool, error) {
	members, err := tx.MemberIDs(conv)
	return slices.Contains(members, user), err
}

// POST /calls {"id", "conv", "video"}: joins the conversation's call, or
// starts one with the caller's ID (so that a retry finds it again), a video
// call if asked.
func (a *API) postCall(w http.ResponseWriter, r *http.Request, c *Caller) error {
	if !a.cfg.Calls() {
		return errCallsOff
	}
	var req struct {
		ID    string `json:"id"`
		Conv  string `json:"conv"`
		Video bool   `json:"video"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	if !protocol.IsULID(req.ID) {
		return badRequest("id must be a ULID")
	}
	ctx := r.Context()
	if err := a.requireMember(ctx, req.Conv, c); err != nil {
		return err
	}
	var call *store.Call
	err := a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		if err := requireVerified(tx, c); err != nil {
			return nil, err
		}
		if hub, _, err := tx.ConversationHub(req.Conv); err != nil {
			return nil, err
		} else if hub != "" {
			return nil, errCallsUnavailable
		}
		conv, err := tx.Conversation(req.Conv)
		if err != nil {
			return nil, err
		}
		members := make([]string, 0, len(conv.Members))
		for _, m := range conv.Members {
			if a.remote(m.ID) {
				return nil, errCallsUnavailable
			}
			members = append(members, m.ID)
		}
		var other string
		if conv.IsDirect {
			if other, err = tx.DirectPartner(req.Conv, c.UserID); err != nil {
				return nil, err
			} else if other == "" {
				return nil, errNotFound
			}
			if err := requireContact(tx, c.UserID, other); err != nil {
				return nil, err
			}
		}
		if active, err := tx.ActiveCall(req.Conv); err == nil {
			call = active
			return nil, nil
		} else if !errors.Is(err, store.ErrNotFound) {
			return nil, err
		}
		if _, err := tx.Call(req.ID); err == nil {
			return nil, errCallEnded
		} else if !errors.Is(err, store.ErrNotFound) {
			return nil, err
		}
		now := time.Now()
		call = &store.Call{
			ID: req.ID, Conv: req.Conv, Direct: conv.IsDirect, Video: req.Video,
			StartedBy: c.UserID, StartedDevice: c.SessionID, StartedAt: now.UnixMilli(),
		}
		if conv.IsDirect {
			call.RingUntil = now.Add(a.callRingTimeout()).UnixMilli()
		}
		if err := tx.InsertCall(call); err != nil {
			return nil, err
		}
		c.Log.Info("call started", "call", call.ID, "conv", call.Conv, "video", call.Video)
		started := *call
		return func() {
			a.callChanged(&started, members)
			if other != "" {
				a.ring(other, &started)
			}
		}, nil
	})
	if err != nil {
		return err
	}
	token, err := a.liveKitKeys().Token(callIdentity(c.UserID, c.SessionID), livekit.JoinGrant(call.ID), time.Now(), callTokenTTL)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"call":    call.Wire(),
		"livekit": map[string]string{"url": a.cfg.LiveKitURL, "token": token},
	})
	return nil
}

// GET /calls: the calls of the caller's conversations going on, or ended in
// the last day.
func (a *API) getCalls(w http.ResponseWriter, r *http.Request, c *Caller) error {
	out := []protocol.Call{}
	if a.cfg.Calls() {
		calls, err := a.store.CallsFor(r.Context(), c.UserID, time.Now().Add(-callKeepEnded).UnixMilli())
		if err != nil {
			return err
		}
		for _, call := range calls {
			out = append(out, call.Wire())
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"calls": out})
	return nil
}

// changeCall runs change on a call of a conversation the caller is in, and
// answers with the call.
func (a *API) changeCall(w http.ResponseWriter, r *http.Request, c *Caller,
	change func(tx *store.Tx, call *store.Call) (func(), error)) error {
	if !a.cfg.Calls() {
		return errCallsOff
	}
	var result *store.Call
	err := a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		call, err := tx.Call(r.PathValue("id"))
		if err != nil {
			return nil, err
		}
		if ok, err := memberOf(tx, call.Conv, c.UserID); err != nil {
			return nil, err
		} else if !ok {
			return nil, errNotFound
		}
		result = call
		if !call.Active() {
			return nil, nil
		}
		return change(tx, call)
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"call": result.Wire()})
	return nil
}

// POST /calls/{id}/decline: the one a direct call rings says no.
func (a *API) declineCall(w http.ResponseWriter, r *http.Request, c *Caller) error {
	return a.changeCall(w, r, c, func(tx *store.Tx, call *store.Call) (func(), error) {
		if !call.Direct || call.StartedBy == c.UserID {
			return nil, &Error{http.StatusConflict, "not_ringing", "Only the one a call of two rings can decline it"}
		}
		if call.AnsweredAt != 0 {
			return nil, nil
		}
		call.EndedAt, call.Reason = time.Now().UnixMilli(), protocol.CallDeclined
		c.Log.Info("call declined", "call", call.ID)
		return a.saveChange(tx, call)
	})
}

// POST /calls/{id}/leave: the caller's device hangs up. Before an answer,
// the caller hanging up cancels a direct call.
func (a *API) leaveCall(w http.ResponseWriter, r *http.Request, c *Caller) error {
	return a.changeCall(w, r, c, func(tx *store.Tx, call *store.Call) (func(), error) {
		if _, err := tx.RemoveCallParticipant(call.ID, c.SessionID, ""); err != nil {
			return nil, err
		}
		left, err := tx.Call(call.ID)
		if err != nil {
			return nil, err
		}
		*call = *left
		now := time.Now().UnixMilli()
		if call.Direct && call.AnsweredAt == 0 && call.StartedBy == c.UserID {
			call.EndedAt, call.Reason = now, protocol.CallCancelled
		} else {
			settle(call, now)
		}
		publish, err := a.saveChange(tx, call)
		if err != nil {
			return nil, err
		}
		room, identity := call.ID, callIdentity(c.UserID, c.SessionID)
		return func() {
			publish()
			a.removeFromRoomLater(room, identity)
		}, nil
	})
}

// dropFromCalls takes a user's devices out of the calls going on: all of
// them in conv, or with conv "", only device (everywhere). For a user who
// left a group, and a device signed out or revoked.
func (a *API) dropFromCalls(ctx context.Context, user, conv, device string) {
	if !a.cfg.Calls() {
		return
	}
	err := a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		calls, err := tx.ActiveCallsOf(user)
		if err != nil {
			return nil, err
		}
		var publishes []func()
		for _, call := range calls {
			if conv != "" && call.Conv != conv {
				continue
			}
			for _, p := range call.Participants {
				if p.User != user || (device != "" && p.Device != device) {
					continue
				}
				if _, err := tx.RemoveCallParticipant(call.ID, p.Device, ""); err != nil {
					return nil, err
				}
				room, identity := call.ID, callIdentity(p.User, p.Device)
				publishes = append(publishes, func() { a.removeFromRoomLater(room, identity) })
			}
			left, err := tx.Call(call.ID)
			if err != nil {
				return nil, err
			}
			settle(left, time.Now().UnixMilli())
			publish, err := a.saveChange(tx, left)
			if err != nil {
				return nil, err
			}
			publishes = append(publishes, publish)
		}
		return func() {
			for _, publish := range publishes {
				publish()
			}
		}, nil
	})
	if err != nil {
		a.log.Warn("calls: dropping devices", "user", user, "err", err)
	}
}

// POST /livekit/webhook: what LiveKit says happened in its rooms. Signed by
// LiveKit with the API secret; no session, no client level.
func (a *API) liveKitWebhook(w http.ResponseWriter, r *http.Request) {
	if !a.cfg.Calls() {
		http.NotFound(w, r)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 64<<10))
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if err := a.liveKitKeys().Verify(r.Header.Get("Authorization"), body, time.Now()); err != nil {
		a.log.Warn("calls: refused a webhook LiveKit did not sign")
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	event, err := livekit.ParseEvent(body)
	if err != nil || event.Room == nil {
		// Nothing to act on; LiveKit need not send it again.
		w.WriteHeader(http.StatusOK)
		return
	}
	ctx := r.Context()
	room := event.Room.Name
	switch {
	case event.Event == "participant_joined" && event.Participant != nil:
		err = a.callJoined(ctx, room, *event.Participant)
	case event.Event == "participant_left" && event.Participant != nil:
		err = a.callLeft(ctx, room, *event.Participant)
	case event.Event == "room_started":
		err = a.roomStarted(ctx, room)
	case event.Event == "room_finished":
		err = a.roomFinished(ctx, room)
	}
	if err != nil {
		// LiveKit sends it again.
		a.log.Warn("calls: webhook", "event", event.Event, "room", room, "err", err)
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// callJoined: a device got into a call's room. One that does not belong
// there (a token left over from an ended call, someone no longer a member)
// is put out again.
func (a *API) callJoined(ctx context.Context, room string, p livekit.Participant) error {
	user, device, ok := parseCallIdentity(p.Identity)
	var kick, closeRoom bool
	err := a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		call, err := tx.Call(room)
		if errors.Is(err, store.ErrNotFound) {
			closeRoom = true
			return nil, nil
		} else if err != nil {
			return nil, err
		}
		if !ok || !call.Active() {
			kick = true
			return nil, nil
		}
		if member, err := memberOf(tx, call.Conv, user); err != nil {
			return nil, err
		} else if !member {
			kick = true
			return nil, nil
		}
		now := time.Now().UnixMilli()
		if err := tx.PutCallParticipant(call.ID, store.CallParticipant{User: user, Device: device, SID: p.SID, JoinedAt: now}); err != nil {
			return nil, err
		}
		if call, err = tx.Call(room); err != nil {
			return nil, err
		}
		if call.FirstJoinedAt == 0 {
			call.FirstJoinedAt = now
		}
		answered := call.Direct && call.AnsweredAt == 0 && user != call.StartedBy
		if answered {
			call.AnsweredAt = now
		}
		publish, err := a.saveChange(tx, call)
		if err != nil {
			return nil, err
		}
		changed := *call
		return func() {
			publish()
			if answered {
				// The user's other devices stop ringing.
				a.stopRinging(user, &changed, "answered", device)
			}
		}, nil
	})
	switch {
	case closeRoom:
		a.deleteRoomLater(room)
	case kick:
		a.removeFromRoomLater(room, p.Identity)
	}
	return err
}

// callLeft: a device's connection to a call's room ended (a newer one of the
// same device does not count).
func (a *API) callLeft(ctx context.Context, room string, p livekit.Participant) error {
	_, device, ok := parseCallIdentity(p.Identity)
	if !ok {
		return nil
	}
	return a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		call, err := tx.Call(room)
		if errors.Is(err, store.ErrNotFound) {
			return nil, nil
		} else if err != nil || !call.Active() {
			return nil, err
		}
		if removed, err := tx.RemoveCallParticipant(call.ID, device, p.SID); err != nil || !removed {
			return nil, err
		}
		if call, err = tx.Call(room); err != nil {
			return nil, err
		}
		settle(call, time.Now().UnixMilli())
		return a.saveChange(tx, call)
	})
}

// roomStarted: a room for no call going on (a leftover token) is closed.
func (a *API) roomStarted(ctx context.Context, room string) error {
	var active bool
	err := a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		call, err := tx.Call(room)
		if err == nil {
			active = call.Active()
		} else if !errors.Is(err, store.ErrNotFound) {
			return nil, err
		}
		return nil, nil
	})
	if err == nil && !active {
		a.deleteRoomLater(room)
	}
	return err
}

// roomFinished: everyone is out of the room, so its call is over.
func (a *API) roomFinished(ctx context.Context, room string) error {
	return a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		call, err := tx.Call(room)
		if errors.Is(err, store.ErrNotFound) {
			return nil, nil
		} else if err != nil || !call.Active() {
			return nil, err
		}
		for _, p := range call.Participants {
			if _, err := tx.RemoveCallParticipant(call.ID, p.Device, ""); err != nil {
				return nil, err
			}
		}
		call.Participants = nil
		now := time.Now().UnixMilli()
		if !settle(call, now) {
			call.EndedAt, call.Reason = now, protocol.CallFailed
		}
		return a.saveChange(tx, call)
	})
}

// endCall ends a call going on, for reason.
func (a *API) endCall(ctx context.Context, id, reason string) error {
	return a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		call, err := tx.Call(id)
		if err != nil || !call.Active() {
			return nil, err
		}
		call.EndedAt, call.Reason = time.Now().UnixMilli(), reason
		return a.saveChange(tx, call)
	})
}

// runCalls looks after the calls while the server runs: direct calls nobody
// answered in time are missed, calls nobody got into failed, and what this
// server knows of who is in them is compared with LiveKit's rooms.
func (a *API) runCalls(ctx context.Context) {
	if !a.cfg.Calls() {
		return
	}
	sweepEvery, reconcileEvery := a.cfg.CallSweepInterval, a.cfg.CallReconcileInterval
	if sweepEvery <= 0 {
		sweepEvery = 2 * time.Second
	}
	if reconcileEvery <= 0 {
		reconcileEvery = 15 * time.Second
	}
	a.reconcileCalls(ctx)
	sweep, reconcile, purge := time.NewTicker(sweepEvery), time.NewTicker(reconcileEvery), time.NewTicker(time.Hour)
	defer sweep.Stop()
	defer reconcile.Stop()
	defer purge.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-sweep.C:
			a.sweepCalls(ctx)
		case <-reconcile.C:
			a.reconcileCalls(ctx)
		case <-purge.C:
			if err := a.store.PurgeCalls(ctx, time.Now().Add(-callPurgeAfter).UnixMilli()); err != nil {
				a.log.Warn("calls: purging", "err", err)
			}
		}
	}
}

func (a *API) sweepCalls(ctx context.Context) {
	calls, err := a.store.ActiveCalls(ctx)
	if err != nil {
		a.log.Warn("calls: sweeping", "err", err)
		return
	}
	now := time.Now()
	for _, call := range calls {
		var reason string
		switch {
		case call.Direct && call.AnsweredAt == 0 && call.RingUntil != 0 && now.UnixMilli() >= call.RingUntil:
			reason = protocol.CallMissed
		case call.FirstJoinedAt == 0 && now.Sub(time.UnixMilli(call.StartedAt)) >= callJoinWindow:
			reason = protocol.CallFailed
		default:
			continue
		}
		if err := a.endCall(ctx, call.ID, reason); err != nil {
			a.log.Warn("calls: ending", "call", call.ID, "err", err)
		}
	}
}

// reconcileCalls compares who is in each call with LiveKit's room: devices
// LiveKit no longer has (whose leaving went unheard) leave, and ones it has
// that this server missed join. Nothing changes while LiveKit cannot say.
func (a *API) reconcileCalls(ctx context.Context) {
	if a.calls == nil {
		return
	}
	calls, err := a.store.ActiveCalls(ctx)
	if err != nil {
		a.log.Warn("calls: reconciling", "err", err)
		return
	}
	for _, call := range calls {
		asked := time.Now().UnixMilli()
		inRoom, err := a.calls.ListParticipants(ctx, call.ID)
		if err != nil {
			a.log.Debug("calls: LiveKit cannot say who is in a room", "call", call.ID, "err", err)
			continue
		}
		sids := map[string]string{}
		for _, p := range inRoom {
			sids[p.Identity] = p.SID
		}
		for _, p := range call.Participants {
			identity := callIdentity(p.User, p.Device)
			if p.JoinedAt < asked && sids[identity] != p.SID {
				if err := a.callLeft(ctx, call.ID, livekit.Participant{SID: p.SID, Identity: identity}); err != nil {
					a.log.Warn("calls: reconciling", "call", call.ID, "err", err)
				}
			}
		}
		for _, p := range inRoom {
			if !slices.ContainsFunc(call.Participants, func(q store.CallParticipant) bool { return q.SID == p.SID }) {
				if err := a.callJoined(ctx, call.ID, p); err != nil {
					a.log.Warn("calls: reconciling", "call", call.ID, "err", err)
				}
			}
		}
	}
}
