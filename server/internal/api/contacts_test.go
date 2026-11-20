package api_test

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/oklog/ulid/v2"

	"hanashi/server/internal/protocol"
	"hanashi/server/internal/store"
)

func (d *device) contactState(user string) string {
	d.t.Helper()
	var res struct {
		Contacts []struct{ User, State string }
	}
	d.must("GET", "/contacts", nil, &res)
	for _, c := range res.Contacts {
		if c.User == user {
			return c.State
		}
	}
	return "none"
}

func (d *device) request(user string) string {
	d.t.Helper()
	var res struct{ State string }
	d.must("POST", "/contacts/requests", map[string]any{"user": user}, &res)
	return res.State
}

// accept says yes to user, as apps do from client level 4: without the direct
// chat, which is a step of its own (directChat).
func (d *device) accept(user string) error {
	var res struct{ State string }
	if err := d.do("POST", "/contacts/requests/"+user+"/accept", map[string]any{}, &res); err != nil {
		return err
	}
	if res.State != "accepted" {
		d.t.Fatalf("accepted: %+v", res)
	}
	return nil
}

// directChat starts the direct chat of d and user, or gets the one they have.
func (d *device) directChat(user string) (protocol.ConversationInfo, error) {
	var info protocol.ConversationInfo
	err := d.do("POST", "/conversations", map[string]any{
		"id": ulid.Make().String(), "members": []string{user}, "direct": true, "mls": newGroupBody(),
	}, &info)
	return info, err
}

// contactEvents lists {user, state} of the contact events since cursor.
func (d *device) contactEvents(cursor int64) []string {
	d.t.Helper()
	out := []string{}
	for _, e := range d.syncSince(cursor).Events {
		if e.Type != protocol.EventContactChanged {
			continue
		}
		if e.Conv != "" {
			d.t.Fatalf("contact event in a conversation: %+v", e)
		}
		var data struct{ User, State string }
		_ = json.Unmarshal(e.Data, &data)
		out = append(out, data.User+" "+data.State)
	}
	return out
}

func expectEvents(t *testing.T, name string, got []string, want ...string) {
	t.Helper()
	if fmt.Sprint(got) != fmt.Sprint(append([]string{}, want...)) {
		t.Fatalf("%s: got %v, want %v", name, got, want)
	}
}

func TestContactRequestFlow(t *testing.T) {
	base := startServer(t)
	a, b := register(t, base, "a"), register(t, base, "b")
	a2 := login(t, base, "a", "phone")
	aCursor, bCursor := a.syncSince(0).Cursor, b.syncSince(0).Cursor

	if state := a.request(b.UserID); state != "outgoing" {
		t.Fatalf("request: %s", state)
	}
	if a.contactState(b.UserID) != "outgoing" || b.contactState(a.UserID) != "incoming" {
		t.Fatal("states after asking")
	}
	expectEvents(t, "a", a.contactEvents(aCursor), b.UserID+" outgoing")
	expectEvents(t, "a's other device", a2.contactEvents(aCursor), b.UserID+" outgoing")
	expectEvents(t, "b", b.contactEvents(bCursor), a.UserID+" incoming")
	// Asking changes nothing else: no chat exists yet.
	if len(a.snapshot().Conversations) != 0 || len(b.snapshot().Conversations) != 0 {
		t.Fatal("a chat before accepting")
	}

	// Asking again is harmless, and whoever was asked answers rather than asks.
	if state := a.request(b.UserID); state != "outgoing" {
		t.Fatalf("again: %s", state)
	}
	if state := b.request(a.UserID); state != "incoming" {
		t.Fatalf("the other way: %s", state)
	}

	// Only the one who was asked can accept.
	if err := a.accept(b.UserID); codeOf(err) != "no_request" {
		t.Fatalf("accepting one's own request: %v", err)
	}
	if _, err := a.directChat(b.UserID); codeOf(err) != "not_a_contact" {
		t.Fatalf("a direct chat before accepting: %v", err)
	}
	aCursor, bCursor = a.syncSince(0).Cursor, b.syncSince(0).Cursor
	if err := b.accept(a.UserID); err != nil {
		t.Fatal(err)
	}
	if a.contactState(b.UserID) != "accepted" || b.contactState(a.UserID) != "accepted" {
		t.Fatal("states after accepting")
	}
	expectEvents(t, "a", a.contactEvents(aCursor), b.UserID+" accepted")
	expectEvents(t, "b", b.contactEvents(bCursor), a.UserID+" accepted")
	// That is all it does: their chat is a step of its own.
	if events := a.syncSince(aCursor).Events; len(events) != 1 {
		t.Fatalf("a's events %+v", events)
	}
	// Accepting again (the answer got lost) changes nothing.
	if err := b.accept(a.UserID); err != nil {
		t.Fatal(err)
	}
	expectEvents(t, "a after accepting again", a.contactEvents(aCursor), b.UserID+" accepted")

	// Either can start their direct chat, which is the one both then get.
	aCursor = a.syncSince(0).Cursor
	info, err := b.directChat(a.UserID)
	if err != nil {
		t.Fatal(err)
	}
	if !info.IsDirect || len(info.Members) != 2 {
		t.Fatalf("direct chat %+v", info)
	}
	events := a.syncSince(aCursor).Events
	if len(events) != 1 || events[0].Type != protocol.EventConversationCreated {
		t.Fatalf("a's events %+v", events)
	}
	if theirs, err := a.directChat(b.UserID); err != nil || theirs.ID != info.ID {
		t.Fatalf("a's direct chat: %+v, %v", theirs, err)
	}
	if len(a.syncSince(aCursor).Events) != 1 {
		t.Fatal("events for a direct chat that existed")
	}
	if err := b.do("POST", "/conversations", map[string]any{
		"id": ulid.Make().String(), "members": []string{a.UserID, register(t, base, "c").UserID}, "direct": true,
		"mls": newGroupBody(),
	}, nil); codeOf(err) != "bad_request" {
		t.Fatalf("a direct chat of three: %v", err)
	}

	// Removing ends it for both; the chat stays, and goes quiet.
	a.sendREST(info.ID, "still friends")
	aCursor, bCursor = a.syncSince(0).Cursor, b.syncSince(0).Cursor
	b.must("DELETE", "/contacts/"+a.UserID, nil, nil)
	expectEvents(t, "a", a.contactEvents(aCursor), b.UserID+" none")
	expectEvents(t, "b", b.contactEvents(bCursor), a.UserID+" none")
	if err := a.do("POST", "/messages", a.textEnvelope(info.ID, "hello?"), nil); codeOf(err) != "not_a_contact" {
		t.Fatalf("message to a former contact: %v", err)
	}
	var history protocol.HistoryPage
	a.must("GET", "/conversations/"+info.ID+"/messages", nil, &history)
	if len(history.Messages) != 1 {
		t.Fatalf("history %+v", history)
	}

	// Becoming contacts again brings the same chat back.
	a.request(b.UserID)
	if err := b.accept(a.UserID); err != nil {
		t.Fatal(err)
	}
	a.sendREST(info.ID, "friends again")
	if again, err := b.directChat(a.UserID); err != nil || again.ID != info.ID {
		t.Fatalf("a new chat: %+v, %v; was %s", again, err, info.ID)
	}
}

// To the one who asks, a request declined or blocked stays one not answered
// yet: nothing tells them apart, and asking again reaches nobody.
func TestRefusalsAreNotRevealed(t *testing.T) {
	base := startServer(t)
	a, b := register(t, base, "a"), register(t, base, "b")

	a.request(b.UserID)
	aCursor, bCursor := a.syncSince(0).Cursor, b.syncSince(0).Cursor
	b.must("POST", "/contacts/requests/"+a.UserID+"/decline", map[string]any{}, nil)
	if a.contactState(b.UserID) != "outgoing" {
		t.Fatal("declining showed")
	}
	if b.contactState(a.UserID) != "none" {
		t.Fatal("declined request still showing")
	}
	expectEvents(t, "a after decline", a.contactEvents(aCursor))
	expectEvents(t, "b after decline", b.contactEvents(bCursor), a.UserID+" none")
	if err := b.accept(a.UserID); codeOf(err) != "no_request" {
		t.Fatalf("accepting what was declined: %v", err)
	}

	// Taking it back and asking again does not reach them either.
	bCursor = b.syncSince(0).Cursor
	a.must("DELETE", "/contacts/requests/"+b.UserID, nil, nil)
	if a.contactState(b.UserID) != "none" {
		t.Fatal("taken back, still showing")
	}
	if state := a.request(b.UserID); state != "outgoing" {
		t.Fatalf("again: %s", state)
	}
	expectEvents(t, "b after asking again", b.contactEvents(bCursor))
	if b.contactState(a.UserID) != "none" {
		t.Fatal("asking again reached them")
	}

	// b can still ask a, which is then answered as usual.
	if state := b.request(a.UserID); state != "outgoing" {
		t.Fatalf("b asking: %s", state)
	}
	if a.contactState(b.UserID) != "outgoing" {
		t.Fatalf("a's own request should stand: %s", a.contactState(b.UserID))
	}

	// Blocking.
	c, d := register(t, base, "c"), register(t, base, "d")
	d.must("PUT", "/blocked/"+c.UserID, map[string]any{}, nil)
	if d.contactState(c.UserID) != "blocked" || c.contactState(d.UserID) != "none" {
		t.Fatal("blocking showed")
	}
	dCursor := d.syncSince(0).Cursor
	if state := c.request(d.UserID); state != "outgoing" {
		t.Fatalf("asking someone who blocked you: %s", state)
	}
	expectEvents(t, "d", d.contactEvents(dCursor))
	if err := d.do("POST", "/contacts/requests", map[string]any{"user": c.UserID}, nil); codeOf(err) != "blocked" {
		t.Fatalf("asking someone one blocked: %v", err)
	}
	// Unblocking does not bring back what was asked meanwhile.
	d.must("DELETE", "/blocked/"+c.UserID, nil, nil)
	if d.contactState(c.UserID) != "none" {
		t.Fatalf("after unblocking: %s", d.contactState(c.UserID))
	}

	// A contact who gets blocked sees the contact end, nothing more.
	e, f := register(t, base, "e"), register(t, base, "f")
	info := e.createConversation("", f.UserID)
	f.must("PUT", "/blocked/"+e.UserID, map[string]any{}, nil)
	if e.contactState(f.UserID) != "none" || f.contactState(e.UserID) != "blocked" {
		t.Fatal("states after blocking a contact")
	}
	if err := e.do("POST", "/messages", e.textEnvelope(info.ID, "hi"), nil); codeOf(err) != "not_a_contact" {
		t.Fatalf("message: %v", err)
	}
}

func TestContactRequestLimits(t *testing.T) {
	base := startServer(t)
	a := register(t, base, "a")
	if err := a.do("POST", "/contacts/requests", map[string]any{"user": a.UserID}, nil); statusOf(err) != 400 {
		t.Fatalf("asking oneself: %v", err)
	}
	if err := a.do("POST", "/contacts/requests", map[string]any{"user": "nobody@" + testHost}, nil); codeOf(err) != "user_not_found" {
		t.Fatalf("nobody: %v", err)
	}
	if err := a.do("POST", "/contacts/requests", map[string]any{"user": "someone@other.example"}, nil); codeOf(err) != "other_server" {
		t.Fatalf("someone on another server: %v", err)
	}
	if err := a.do("DELETE", "/contacts/requests/someone@other.example", nil, nil); codeOf(err) != "other_server" {
		t.Fatalf("taking back a request to another server: %v", err)
	}
	if err := a.do("POST", "/contacts/requests", map[string]any{"user": "not an ID"}, nil); codeOf(err) != "user_not_found" {
		t.Fatalf("not an ID: %v", err)
	}
	var rows [][3]string
	for i := range 50 {
		other := register(t, base, fmt.Sprintf("u%d", i))
		rows = append(rows, [3]string{a.UserID, other.UserID, store.ContactRequested})
	}
	a.setContactStates(rows...)
	next := register(t, base, "next")
	if err := a.do("POST", "/contacts/requests", map[string]any{"user": next.UserID}, nil); codeOf(err) != "too_many_requests" {
		t.Fatalf("over the limit: %v", err)
	}
	a.must("DELETE", "/contacts/requests/"+rows[0][1], nil, nil)
	a.request(next.UserID)
}

// Nobody reaches a user, or spends their key packages, without asking first.
func TestStrangersAreKeptOut(t *testing.T) {
	base := startServer(t)
	a, stranger, other := register(t, base, "a"), register(t, base, "stranger"), register(t, base, "other")
	a.setUpIdentity()
	stranger.setUpIdentity()
	a.must("POST", "/keys/packages", map[string]any{"packages": []string{kp("one"), kp("two")}}, nil)

	claim := func(d *device) error {
		return d.do("POST", "/keys/packages/claim", map[string]any{"devices": []string{a.DeviceID}}, nil)
	}
	if err := claim(stranger); codeOf(err) != "not_a_contact" {
		t.Fatalf("a stranger claiming packages: %v", err)
	}
	var count struct{ Count int }
	a.must("GET", "/keys/packages/count", nil, &count)
	if count.Count != 2 {
		t.Fatalf("packages left: %d", count.Count)
	}
	// One's own devices are fine.
	if err := claim(a); err != nil {
		t.Fatalf("claiming one's own: %v", err)
	}

	// Asking gives the one asked the right to claim, not the one asking.
	stranger.request(a.UserID)
	if err := claim(stranger); codeOf(err) != "not_a_contact" {
		t.Fatalf("claiming after asking: %v", err)
	}
	var packages struct{ Packages map[string]string }
	stranger.must("POST", "/keys/packages", map[string]any{"packages": []string{kp("s")}}, nil)
	a.must("POST", "/keys/packages/claim", map[string]any{"devices": []string{stranger.DeviceID}}, &packages)
	if packages.Packages[stranger.DeviceID] != kp("s") {
		t.Fatalf("claim by the one asked: %v", packages)
	}

	// No chats with strangers, nor with someone who has only asked.
	if err := stranger.accept(a.UserID); codeOf(err) != "no_request" {
		t.Fatalf("accepting without being asked: %v", err)
	}
	if _, err := stranger.directChat(a.UserID); codeOf(err) != "not_a_contact" {
		t.Fatalf("a direct chat with a stranger: %v", err)
	}
	if _, err := a.directChat(stranger.UserID); codeOf(err) != "not_a_contact" {
		t.Fatalf("a direct chat with someone who has only asked: %v", err)
	}
	newGroup := func(members ...string) map[string]any {
		return map[string]any{"id": ulid.Make().String(), "members": members, "mls": newGroupBody()}
	}
	if err := stranger.do("POST", "/conversations", newGroup(a.UserID), nil); codeOf(err) != "not_a_contact" {
		t.Fatalf("a group with a stranger: %v", err)
	}
	if err := a.do("POST", "/conversations", newGroup(other.UserID), nil); codeOf(err) != "not_a_contact" {
		t.Fatalf("a group with someone who has only been asked: %v", err)
	}

	// Being added to a group takes being a contact of whoever adds.
	group := other.createConversation("Club", register(t, base, "friend").UserID)
	leaseID, epoch := other.lease(group.ID)
	err := other.do("POST", "/conversations/"+group.ID+"/members",
		map[string]any{"user": a.UserID, "commit": commitBody(leaseID, epoch)}, nil)
	if codeOf(err) != "not_a_contact" {
		t.Fatalf("added by a stranger: %v", err)
	}
	if other.do("POST", "/conversations/"+group.ID+"/lease", map[string]any{}, nil) != nil {
		t.Fatal("a refused add should keep the lease with its holder")
	}
}

func TestProfiles(t *testing.T) {
	base := startServer(t)
	a, b, stranger := register(t, base, "a"), register(t, base, "b"), register(t, base, "stranger")
	a.createConversation("", b.UserID)
	signature := b64(make([]byte, 64))
	record := func(version int, text string) map[string]any {
		return map[string]any{"version": version, "ct": b64([]byte(text)), "signature": signature}
	}
	aCursor, bCursor, strangerCursor := a.syncSince(0).Cursor, b.syncSince(0).Cursor, stranger.syncSince(0).Cursor

	if err := b.do("GET", "/users/"+a.UserID+"/profile", nil, nil); statusOf(err) != 404 {
		t.Fatalf("before: %v", err)
	}
	a.must("PUT", "/profile", record(5, "five"), nil)
	var got struct {
		User, CT, Signature string
		Version             int64
	}
	b.must("GET", "/users/"+a.UserID+"/profile", nil, &got)
	if got.User != a.UserID || got.Version != 5 || got.CT != b64([]byte("five")) || got.Signature != signature {
		t.Fatalf("record %+v", got)
	}

	// Going back is refused, also to the same version, and changes nothing.
	for _, version := range []int{4, 5} {
		if err := a.do("PUT", "/profile", record(version, "old"), nil); codeOf(err) != "stale_version" {
			t.Fatalf("version %d: %v", version, err)
		}
	}
	a.must("PUT", "/profile", record(6, "six"), nil)
	a.must("GET", "/users/"+a.UserID+"/profile", nil, &got)
	if got.Version != 6 || got.CT != b64([]byte("six")) {
		t.Fatalf("own record %+v", got)
	}

	// Those who may fetch it are told, without the record itself.
	for _, tc := range []struct {
		d      *device
		cursor int64
	}{{a, aCursor}, {b, bCursor}} {
		var versions []int64
		for _, e := range tc.d.syncSince(tc.cursor).Events {
			var data struct {
				User    string
				Version int64
				CT      string
			}
			_ = json.Unmarshal(e.Data, &data)
			if e.Type != protocol.EventProfileChanged || e.Conv != "" || data.User != a.UserID || data.CT != "" {
				t.Fatalf("event %+v", e)
			}
			versions = append(versions, data.Version)
		}
		if fmt.Sprint(versions) != "[5 6]" {
			t.Fatalf("%s told %v", tc.d.UserID, versions)
		}
	}

	// Strangers neither hear of it nor get it.
	if events := stranger.syncSince(strangerCursor).Events; len(events) != 0 {
		t.Fatalf("stranger's events %+v", events)
	}
	if err := stranger.do("GET", "/users/"+a.UserID+"/profile", nil, nil); statusOf(err) != 404 {
		t.Fatalf("stranger: %v", err)
	}
	stranger.request(a.UserID)
	if err := stranger.do("GET", "/users/"+a.UserID+"/profile", nil, nil); statusOf(err) != 404 {
		t.Fatalf("after only asking: %v", err)
	}

	for name, body := range map[string]map[string]any{
		"no version":    {"ct": b64([]byte("x")), "signature": signature},
		"no ciphertext": {"version": 9, "signature": signature},
		"bad signature": {"version": 9, "ct": b64([]byte("x")), "signature": b64([]byte("short"))},
		"too large":     {"version": 9, "ct": b64(make([]byte, 16*1024+1)), "signature": signature},
	} {
		if err := a.do("PUT", "/profile", body, nil); statusOf(err) != 400 {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestControlMessagesStayOutOfTheChat(t *testing.T) {
	base := startServer(t)
	a, b := register(t, base, "a"), register(t, base, "b")
	conv := a.createConversation("Club", b.UserID)
	cursor := b.syncSince(0).Cursor
	a.sendREST(conv.ID, "a message")
	control := a.textEnvelope(conv.ID, "a control message")
	control["type"] = protocol.TypeMLSControl
	var res struct{ Seq int64 }
	a.must("POST", "/messages", control, &res)
	var again struct{ Seq int64 }
	a.must("POST", "/messages", control, &again)
	if again.Seq != res.Seq {
		t.Fatalf("retry got seq %d, was %d", again.Seq, res.Seq)
	}

	// Delivered to devices in order...
	events := b.syncSince(cursor).Events
	if len(events) != 2 || events[0].Type != protocol.EventMessage || events[1].Type != protocol.EventControl ||
		envelopeText(events[1]) != "a control message" {
		t.Fatalf("events %+v", events)
	}
	// ...but no part of what a new device or an older page gets.
	var history protocol.HistoryPage
	a.must("GET", "/conversations/"+conv.ID+"/messages", nil, &history)
	if len(history.Messages) != 1 || envelopeText(history.Messages[0]) != "a message" {
		t.Fatalf("history %+v", history)
	}
	snapshot := login(t, base, "b", "new phone").snapshot()
	if len(snapshot.Conversations) != 1 || len(snapshot.Conversations[0].Messages) != 1 {
		t.Fatalf("snapshot %+v", snapshot)
	}
}

func TestGroupState(t *testing.T) {
	base := startServer(t)
	a, b, c, outsider := register(t, base, "a"), register(t, base, "b"), register(t, base, "c"), register(t, base, "outsider")
	a.makeContact(b.UserID)
	a.makeContact(c.UserID)
	sealed := func(text string) string { return b64([]byte("sealed " + text)) }
	groupState := func(d *device, conv string) (int64, string) {
		d.t.Helper()
		var g struct {
			Epoch int64
			State string
		}
		d.must("GET", "/conversations/"+conv+"/group-info", nil, &g)
		return g.Epoch, g.State
	}

	// Created with its state: it waits in the GroupInfo and the Welcomes.
	var info protocol.ConversationInfo
	a.must("POST", "/conversations", map[string]any{
		"id": ulid.Make().String(), "members": []string{b.UserID},
		"mls": map[string]any{"epoch": 3, "groupInfo": fakeMLS, "state": sealed("at 3"),
			"welcomes": []map[string]any{{"device": b.DeviceID, "data": fakeMLS}}},
	}, &info)
	conv := info.ID
	if epoch, state := groupState(b, conv); epoch != 3 || state != sealed("at 3") {
		t.Fatalf("after creating: %d %q", epoch, state)
	}
	var inbox struct {
		Items []struct {
			Data struct {
				State string
				Epoch int64
			}
		}
	}
	b.must("GET", "/inbox", nil, &inbox)
	if len(inbox.Items) != 1 || inbox.Items[0].Data.State != sealed("at 3") || inbox.Items[0].Data.Epoch != 3 {
		t.Fatalf("welcome %+v", inbox.Items)
	}

	// A commit brings the state of the epoch it starts, in its event too; and
	// a Welcome sent with it carries the same.
	cursor := b.syncSince(0).Cursor
	leaseID, epoch := a.lease(conv)
	commit := commitBody(leaseID, epoch, map[string]any{"device": c.DeviceID, "data": fakeMLS})
	commit["state"] = sealed("at 4")
	a.must("POST", "/conversations/"+conv+"/members", map[string]any{"user": c.UserID, "commit": commit}, nil)
	if epoch, state := groupState(b, conv); epoch != 4 || state != sealed("at 4") {
		t.Fatalf("after a commit: %d %q", epoch, state)
	}
	var event struct{ State string }
	for _, e := range b.syncSince(cursor).Events {
		if e.Type == protocol.EventMLSCommit {
			_ = json.Unmarshal(e.Data, &event)
		}
	}
	if event.State != sealed("at 4") {
		t.Fatalf("commit event's state %q", event.State)
	}
	c.must("GET", "/inbox", nil, &inbox)
	if len(inbox.Items) != 1 || inbox.Items[0].Data.State != sealed("at 4") {
		t.Fatalf("c's welcome %+v", inbox.Items)
	}

	// A commit without it (a device that joined by itself cannot read what
	// came before) leaves the epoch without one, for another member to seal.
	leaseID, epoch = c.lease(conv)
	c.must("POST", "/conversations/"+conv+"/commits", commitBody(leaseID, epoch), nil)
	if epoch, state := groupState(b, conv); epoch != 5 || state != "" {
		t.Fatalf("after a commit without state: %d %q", epoch, state)
	}
	put := func(d *device, epoch int64, text string) error {
		return d.do("PUT", "/conversations/"+conv+"/state", map[string]any{"epoch": epoch, "data": sealed(text)}, nil)
	}
	if err := put(outsider, 5, "x"); statusOf(err) != 404 {
		t.Fatalf("outsider: %v", err)
	}
	if err := put(b, 4, "for an earlier epoch"); codeOf(err) != "epoch_mismatch" {
		t.Fatalf("earlier epoch: %v", err)
	}
	if err := b.do("PUT", "/conversations/"+conv+"/state", map[string]any{"epoch": 5, "data": "not base64!"}, nil); statusOf(err) != 400 {
		t.Fatalf("bad data: %v", err)
	}
	cursor = c.syncSince(0).Cursor
	if err := put(b, 5, "at 5"); err != nil {
		t.Fatal(err)
	}
	if err := put(a, 5, "later"); codeOf(err) != "state_exists" {
		t.Fatalf("second: %v", err)
	}
	if epoch, state := groupState(c, conv); epoch != 5 || state != sealed("at 5") {
		t.Fatalf("sealed: %d %q", epoch, state)
	}
	events := c.syncSince(cursor).Events
	var healed struct {
		Epoch int64
		Data  string
		From  string
	}
	if len(events) != 1 || events[0].Type != protocol.EventGroupState || json.Unmarshal(events[0].Data, &healed) != nil ||
		healed.Epoch != 5 || healed.Data != sealed("at 5") || healed.From != b.UserID {
		t.Fatalf("c's events %+v", events)
	}
}

func kp(s string) string { return b64([]byte(s)) }
