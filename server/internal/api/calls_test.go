package api_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/oklog/ulid/v2"

	"hanashi/server/internal/config"
	"hanashi/server/internal/livekit"
	"hanashi/server/internal/protocol"
)

var liveKitKeys = livekit.Keys{APIKey: "APItest", Secret: "a test secret, long enough to be a real one"}

// fakeLiveKit stands in for LiveKit's room API: it records what the server
// asks of it and says who is in each room.
type fakeLiveKit struct {
	*httptest.Server
	mu    sync.Mutex
	asked []string
	rooms map[string][]livekit.Participant
}

func newFakeLiveKit(t *testing.T) *fakeLiveKit {
	f := &fakeLiveKit{rooms: map[string][]livekit.Participant{}}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req map[string]string
		_ = json.NewDecoder(r.Body).Decode(&req)
		method := strings.TrimPrefix(r.URL.Path, "/twirp/livekit.RoomService/")
		f.mu.Lock()
		defer f.mu.Unlock()
		f.asked = append(f.asked, strings.TrimSpace(method+" "+req["room"]+" "+req["identity"]))
		if method == "ListParticipants" {
			json.NewEncoder(w).Encode(map[string]any{"participants": f.rooms[req["room"]]})
			return
		}
		w.Write([]byte(`{}`))
	}))
	t.Cleanup(f.Close)
	return f
}

// wasAsked waits until the server asked LiveKit for what.
func (f *fakeLiveKit) wasAsked(t *testing.T, what string) {
	t.Helper()
	eventually(t, "LiveKit is asked to "+what, func() bool {
		f.mu.Lock()
		defer f.mu.Unlock()
		return slices.Contains(f.asked, what)
	})
}

func (f *fakeLiveKit) setRoom(room string, participants ...livekit.Participant) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.rooms[room] = participants
}

// withLiveKit lets the server carry calls through f. Calls are compared
// with f's rooms only at reconcileEvery.
func withLiveKit(f *fakeLiveKit, reconcileEvery time.Duration) serverOption {
	return func(c *config.Config) {
		c.LiveKitURL = "wss://livekit.test.local"
		c.LiveKitAPIURL = f.URL
		c.LiveKitAPIKey = liveKitKeys.APIKey
		c.LiveKitAPISecret = liveKitKeys.Secret
		c.CallSweepInterval = 20 * time.Millisecond
		c.CallReconcileInterval = reconcileEvery
	}
}

func withRingTimeout(d time.Duration) serverOption {
	return func(c *config.Config) { c.CallRingTimeout = d }
}

type callJoin struct {
	Call    protocol.Call `json:"call"`
	LiveKit struct {
		URL   string `json:"url"`
		Token string `json:"token"`
	} `json:"livekit"`
}

func (d *device) call(id, conv string) (callJoin, error) {
	var join callJoin
	err := d.do("POST", "/calls", map[string]string{"id": id, "conv": conv}, &join)
	return join, err
}

// videoCall starts a video call, or joins the conversation's call.
func (d *device) videoCall(id, conv string) (callJoin, error) {
	var join callJoin
	err := d.do("POST", "/calls", map[string]any{"id": id, "conv": conv, "video": true}, &join)
	return join, err
}

func (d *device) identity() string { return d.UserID + "/" + d.DeviceID }

// webhook posts what LiveKit would say, signed with keys, and answers the
// status.
func webhook(t *testing.T, base string, keys livekit.Keys, event, room string, p *livekit.Participant) int {
	t.Helper()
	body, _ := json.Marshal(map[string]any{
		"id": ulid.Make().String(), "event": event, "room": map[string]string{"name": room, "sid": "RM_" + room},
		"participant": p,
	})
	auth, err := keys.SignWebhook(body, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest("POST", base+"/livekit/webhook", bytes.NewReader(body))
	req.Header.Set("Authorization", auth)
	req.Header.Set("Content-Type", "application/webhook+json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return resp.StatusCode
}

func joined(t *testing.T, base, room string, d *device, sid string) {
	t.Helper()
	if status := webhook(t, base, liveKitKeys, "participant_joined", room, &livekit.Participant{SID: sid, Identity: d.identity()}); status != 200 {
		t.Fatalf("joined: %d", status)
	}
}

func left(t *testing.T, base, room string, d *device, sid string) {
	t.Helper()
	if status := webhook(t, base, liveKitKeys, "participant_left", room, &livekit.Participant{SID: sid, Identity: d.identity()}); status != 200 {
		t.Fatalf("left: %d", status)
	}
}

// nextCall is the next call frame.
func (s *socket) nextCall() protocol.Call {
	s.t.Helper()
	data, _ := json.Marshal(s.nextOfType("call")["call"])
	var call protocol.Call
	_ = json.Unmarshal(data, &call)
	return call
}

func usersIn(call protocol.Call) []string {
	var users []string
	for _, p := range call.Participants {
		users = append(users, p.User)
	}
	return users
}

func TestCallsAreOffWithoutLiveKit(t *testing.T) {
	base := startServer(t)
	a := register(t, base, "a")
	b := register(t, base, "b")
	conv := a.createConversation("", b.UserID)
	var integrations map[string]any
	a.must("GET", "/integrations", nil, &integrations)
	if _, ok := integrations["calls"]; ok {
		t.Errorf("integrations %v", integrations)
	}
	if _, err := a.call(ulid.Make().String(), conv.ID); codeOf(err) != "calls_off" {
		t.Errorf("start: %v", err)
	}
	var calls map[string][]any
	a.must("GET", "/calls", nil, &calls)
	if len(calls["calls"]) != 0 {
		t.Errorf("calls %v", calls)
	}
	if status := webhook(t, base, liveKitKeys, "room_started", "x", nil); status != http.StatusNotFound {
		t.Errorf("webhook: %d", status)
	}
}

func TestCallOfTwo(t *testing.T) {
	lk := newFakeLiveKit(t)
	base := startServer(t, withLiveKit(lk, time.Hour))
	service := newPushService(t)
	a := register(t, base, "a")
	b := register(t, base, "b")
	laptop := login(t, base, "b", "laptop")
	conv := a.createConversation("", b.UserID)
	service.subscribe(b, "b")
	service.subscribe(laptop, "laptop")
	var integrations map[string]any
	a.must("GET", "/integrations", nil, &integrations)
	if integrations["calls"] != true || integrations["video"] != true {
		t.Fatalf("integrations %v", integrations)
	}
	as, bs := a.connect(), b.connect()

	id := ulid.Make().String()
	join, err := a.call(id, conv.ID)
	if err != nil {
		t.Fatal(err)
	}
	if join.Call.ID != id || !join.Call.Direct || join.Call.Video || join.Call.StartedBy != a.UserID ||
		join.Call.RingUntil == 0 || join.LiveKit.URL != "wss://livekit.test.local" {
		t.Fatalf("join %+v", join)
	}
	// A token for the call's room, as this device.
	payload, _ := base64.RawURLEncoding.DecodeString(strings.Split(join.LiveKit.Token, ".")[1])
	var claims struct {
		Iss   string `json:"iss"`
		Sub   string `json:"sub"`
		Video struct {
			Room              string   `json:"room"`
			RoomJoin          bool     `json:"roomJoin"`
			CanPublishSources []string `json:"canPublishSources"`
		} `json:"video"`
	}
	json.Unmarshal(payload, &claims)
	if claims.Iss != "APItest" || claims.Sub != a.identity() || claims.Video.Room != id || !claims.Video.RoomJoin ||
		!slices.Equal(claims.Video.CanPublishSources, []string{"microphone", "camera", "screen_share", "screen_share_audio"}) {
		t.Fatalf("claims %+v", claims)
	}
	// A retry finds the same call, and rings nobody again.
	if again, err := a.call(id, conv.ID); err != nil || again.Call.ID != id {
		t.Fatalf("again %+v, %v", again, err)
	}
	if call := bs.nextCall(); call.ID != id || len(call.Participants) != 0 {
		t.Fatalf("frame %+v", call)
	}
	as.nextCall()

	// It rings both of b's devices, connected or not, at once.
	rings := service.waitFor(2)
	for i, ring := range rings {
		if ring.urgency != "high" || !strings.Contains(ring.payload, `"type":"call"`) || !strings.Contains(ring.payload, id) ||
			service.headers[i].Get("Topic") != "call"+id {
			t.Fatalf("ring %+v %v", ring, service.headers[i])
		}
	}

	// a's app gets in, then b answers on the phone: the laptop stops ringing.
	joined(t, base, id, a, "PA_a")
	if call := bs.nextCall(); !slices.Equal(usersIn(call), []string{a.UserID}) || call.AnsweredAt != 0 {
		t.Fatalf("a in %+v", call)
	}
	joined(t, base, id, b, "PA_b")
	answered := bs.nextCall()
	if answered.AnsweredAt == 0 || len(answered.Participants) != 2 || answered.Version < 3 {
		t.Fatalf("answered %+v", answered)
	}
	if stop := service.waitFor(3)[2]; stop.device != "laptop" || !strings.Contains(stop.payload, `"reason":"answered"`) ||
		stop.urgency != "normal" {
		t.Fatalf("stop %+v", stop)
	}

	// A leaving from an older connection of b's counts for nothing; from
	// b's own, the call is over for both.
	left(t, base, id, b, "PA_old")
	bs.expectSilence()
	left(t, base, id, b, "PA_b")
	ended := bs.nextCall()
	if ended.EndedAt == 0 || ended.Reason != "ended" {
		t.Fatalf("ended %+v", ended)
	}
	lk.wasAsked(t, "DeleteRoom "+id)
	var calls struct {
		Calls []protocol.Call `json:"calls"`
	}
	a.must("GET", "/calls", nil, &calls)
	if len(calls.Calls) != 1 || calls.Calls[0].Reason != "ended" {
		t.Fatalf("GET /calls %+v", calls)
	}
	// One that ended cannot be joined again with its ID; a new one rings.
	if _, err := a.call(id, conv.ID); codeOf(err) != "call_ended" {
		t.Fatalf("ended again: %v", err)
	}
}

func TestVideoCalls(t *testing.T) {
	lk := newFakeLiveKit(t)
	base := startServer(t, withLiveKit(lk, time.Hour))
	service := newPushService(t)
	a := register(t, base, "a")
	b := register(t, base, "b")
	conv := a.createConversation("", b.UserID)
	service.subscribe(b, "b")
	bs := b.connect()

	// Started as a video call: so it rings, and so everyone hears of it.
	id := ulid.Make().String()
	join, err := a.videoCall(id, conv.ID)
	if err != nil || !join.Call.Video {
		t.Fatalf("join %+v, %v", join, err)
	}
	if call := bs.nextCall(); call.ID != id || !call.Video {
		t.Fatalf("frame %+v", call)
	}
	if ring := service.waitFor(1)[0]; !strings.Contains(ring.payload, `"video":true`) {
		t.Fatalf("ring %+v", ring)
	}
	// Answered with voice only, it stays a video call; so does a retry.
	if answer, err := b.call(ulid.Make().String(), conv.ID); err != nil || answer.Call.ID != id || !answer.Call.Video {
		t.Fatalf("answer %+v, %v", answer, err)
	}
	var calls struct {
		Calls []protocol.Call `json:"calls"`
	}
	b.must("GET", "/calls", nil, &calls)
	if len(calls.Calls) != 1 || !calls.Calls[0].Video {
		t.Fatalf("GET /calls %+v", calls)
	}

	// A voice call is not one.
	a.must("POST", "/calls/"+id+"/leave", struct{}{}, nil)
	voice, err := a.call(ulid.Make().String(), conv.ID)
	if err != nil || voice.Call.Video {
		t.Fatalf("voice %+v, %v", voice, err)
	}
}

func TestCallsDeclinedCancelledMissed(t *testing.T) {
	lk := newFakeLiveKit(t)
	base := startServer(t, withLiveKit(lk, time.Hour), withRingTimeout(300*time.Millisecond))
	service := newPushService(t)
	a := register(t, base, "a")
	b := register(t, base, "b")
	conv := a.createConversation("", b.UserID)
	service.subscribe(b, "b")
	bs := b.connect()

	// Declined: only by the one it rings.
	declined := ulid.Make().String()
	if _, err := a.call(declined, conv.ID); err != nil {
		t.Fatal(err)
	}
	bs.nextCall()
	if err := a.do("POST", "/calls/"+declined+"/decline", struct{}{}, nil); codeOf(err) != "not_ringing" {
		t.Fatalf("caller declines: %v", err)
	}
	var answer struct{ Call protocol.Call }
	b.must("POST", "/calls/"+declined+"/decline", struct{}{}, &answer)
	if answer.Call.Reason != "declined" {
		t.Fatalf("declined %+v", answer.Call)
	}
	if call := bs.nextCall(); call.Reason != "declined" {
		t.Fatalf("frame %+v", call)
	}
	lk.wasAsked(t, "DeleteRoom "+declined)
	if stop := service.waitFor(2)[1]; !strings.Contains(stop.payload, `"reason":"declined"`) || stop.urgency != "normal" {
		t.Fatalf("stop %+v", stop)
	}

	// Cancelled: the caller hangs up before an answer, which b sees as missed.
	cancelled := ulid.Make().String()
	if _, err := a.call(cancelled, conv.ID); err != nil {
		t.Fatal(err)
	}
	joined(t, base, cancelled, a, "PA_a")
	a.must("POST", "/calls/"+cancelled+"/leave", struct{}{}, &answer)
	if answer.Call.Reason != "cancelled" {
		t.Fatalf("cancelled %+v", answer.Call)
	}
	if stop := service.waitFor(4)[3]; !strings.Contains(stop.payload, `"reason":"cancelled"`) || stop.urgency != "high" ||
		service.headers[3].Get("TTL") != "86400" {
		t.Fatalf("stop %+v %v", stop, service.headers[3])
	}
	lk.wasAsked(t, "RemoveParticipant "+cancelled+" "+a.identity())

	// Missed: nobody answers in time.
	missed := ulid.Make().String()
	if _, err := a.call(missed, conv.ID); err != nil {
		t.Fatal(err)
	}
	joined(t, base, missed, a, "PA_a2")
	eventually(t, "the call is missed", func() bool {
		var calls struct{ Calls []protocol.Call }
		b.must("GET", "/calls", nil, &calls)
		return slices.ContainsFunc(calls.Calls, func(c protocol.Call) bool { return c.ID == missed && c.Reason == "missed" })
	})
	if stop := service.waitFor(6)[5]; !strings.Contains(stop.payload, `"reason":"missed"`) || stop.urgency != "high" {
		t.Fatalf("stop %+v", stop)
	}
}

func TestGroupCalls(t *testing.T) {
	lk := newFakeLiveKit(t)
	base := startServer(t, withLiveKit(lk, time.Hour))
	service := newPushService(t)
	a := register(t, base, "a")
	b := register(t, base, "b")
	c := register(t, base, "c")
	stranger := register(t, base, "stranger")
	group := a.createConversation("club", b.UserID, c.UserID)
	service.subscribe(b, "b")
	cs := c.connect()

	id := ulid.Make().String()
	if join, err := a.call(id, group.ID); err != nil || join.Call.Direct || join.Call.RingUntil != 0 {
		t.Fatalf("start %+v, %v", join, err)
	}
	// Drop in: another member gets the same call, whatever ID it asks with.
	if join, err := c.call(ulid.Make().String(), group.ID); err != nil || join.Call.ID != id {
		t.Fatalf("drop in %+v, %v", join, err)
	}
	if _, err := stranger.call(ulid.Make().String(), group.ID); statusOf(err) != http.StatusNotFound {
		t.Fatalf("stranger: %v", err)
	}
	cs.nextCall()
	// Groups do not ring.
	service.waitFor(0)

	joined(t, base, id, a, "PA_a")
	joined(t, base, id, c, "PA_c")
	cs.nextCall()
	if call := cs.nextCall(); len(call.Participants) != 2 {
		t.Fatalf("both in %+v", call)
	}
	// Someone not in the group who gets into the room is put out.
	joined(t, base, id, stranger, "PA_s")
	lk.wasAsked(t, "RemoveParticipant "+id+" "+stranger.identity())

	// Leaving the group leaves the call.
	a.must("POST", "/conversations/"+group.ID+"/leave", struct{}{}, nil)
	if call := cs.nextCall(); !slices.Equal(usersIn(call), []string{c.UserID}) || call.EndedAt != 0 {
		t.Fatalf("a left %+v", call)
	}
	lk.wasAsked(t, "RemoveParticipant "+id+" "+a.identity())
	left(t, base, id, c, "PA_c")
	if call := cs.nextCall(); call.Reason != "ended" {
		t.Fatalf("ended %+v", call)
	}
}

func TestCallWebhooksOnlyFromLiveKit(t *testing.T) {
	lk := newFakeLiveKit(t)
	// No app is old enough to be refused LiveKit's webhooks.
	base := startServer(t, withLiveKit(lk, time.Hour), withMinClient(1000))
	other := livekit.Keys{APIKey: liveKitKeys.APIKey, Secret: "somebody else's secret, of a fine length"}
	if status := webhook(t, base, other, "room_started", "01ROOM", nil); status != http.StatusUnauthorized {
		t.Fatalf("forged: %d", status)
	}
	// A room for no call (an old token) is closed.
	room := ulid.Make().String()
	if status := webhook(t, base, liveKitKeys, "room_started", room, nil); status != http.StatusOK {
		t.Fatalf("signed: %d", status)
	}
	lk.wasAsked(t, "DeleteRoom "+room)
}

func TestCallsFollowLiveKitsRooms(t *testing.T) {
	lk := newFakeLiveKit(t)
	base := startServer(t, withLiveKit(lk, 50*time.Millisecond))
	a := register(t, base, "a")
	b := register(t, base, "b")
	c := register(t, base, "c")
	group := a.createConversation("club", b.UserID, c.UserID)
	cs := c.connect()
	id := ulid.Make().String()
	if _, err := a.call(id, group.ID); err != nil {
		t.Fatal(err)
	}
	cs.nextCall()

	// LiveKit has a and b in the room, though only a's joining was heard.
	lk.setRoom(id, livekit.Participant{SID: "PA_a", Identity: a.identity()}, livekit.Participant{SID: "PA_b", Identity: b.identity()})
	joined(t, base, id, a, "PA_a")
	eventually(t, "b is found in the room", func() bool {
		var calls struct{ Calls []protocol.Call }
		c.must("GET", "/calls", nil, &calls)
		return len(calls.Calls) == 1 && len(calls.Calls[0].Participants) == 2
	})
	// Their leaving goes unheard: the call ends all the same.
	lk.setRoom(id)
	eventually(t, "the call ends", func() bool {
		var calls struct{ Calls []protocol.Call }
		c.must("GET", "/calls", nil, &calls)
		return len(calls.Calls) == 1 && calls.Calls[0].Reason == "ended"
	})
}

func TestDirectCallsAreForContacts(t *testing.T) {
	lk := newFakeLiveKit(t)
	base := startServer(t, withLiveKit(lk, time.Hour))
	a := register(t, base, "a")
	b := register(t, base, "b")
	conv := a.createConversation("", b.UserID)
	b.must("DELETE", "/contacts/"+a.UserID, nil, nil)
	if _, err := a.call(ulid.Make().String(), conv.ID); codeOf(err) != "not_a_contact" {
		t.Fatalf("no longer contacts: %v", err)
	}
}

func TestCallsWithOtherServersComeLater(t *testing.T) {
	lk := newFakeLiveKit(t)
	sota, kumiko, _, _, _, _ := contactsAcross(t, withLiveKit(lk, time.Hour))
	chat, err := sota.startChat(kumiko.UserID, kumiko.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := sota.call(ulid.Make().String(), chat.ID); codeOf(err) != "calls_unavailable" {
		t.Fatalf("across servers: %v", err)
	}
}
