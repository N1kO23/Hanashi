package api_test

import (
	"encoding/json"
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/oklog/ulid/v2"

	"hanashi/server/internal/config"
	"hanashi/server/internal/protocol"
)

func TestAccounts(t *testing.T) {
	base := startServer(t)
	yuriko := register(t, base, "yuriko")
	if yuriko.UserID != "yuriko@"+testHost {
		t.Fatalf("user id %q", yuriko.UserID)
	}
	var info protocol.ServerInfo
	yuriko.must("GET", "/server", nil, &info)
	if info.Host != testHost || info.Registration != "open" {
		t.Fatalf("server info %+v", info)
	}

	anon := &device{t: t, base: base}
	if err := anon.auth("/auth/register", "yuriko", "x"); codeOf(err) != "name_taken" {
		t.Fatalf("duplicate name: %v", err)
	}
	if err := anon.auth("/auth/register", "Bad Name!", "x"); statusOf(err) != 400 {
		t.Fatalf("bad name: %v", err)
	}
	err := anon.do("POST", "/auth/login", map[string]any{"name": "yuriko", "password": "nope-nope"}, nil)
	if codeOf(err) != "invalid_credentials" {
		t.Fatalf("wrong password: %v", err)
	}
	second := login(t, base, "yuriko", "phone")
	if second.UserID != yuriko.UserID || second.Token == yuriko.Token {
		t.Fatal("second device must get its own token")
	}
}

func TestRegistrationModes(t *testing.T) {
	closed := startServer(t, withRegistration(config.RegistrationClosed))
	if err := (&device{t: t, base: closed}).auth("/auth/register", "a", "x"); codeOf(err) != "registration_closed" {
		t.Fatalf("closed: %v", err)
	}
	invite := startServer(t, withRegistration(config.RegistrationInvite, "sesame"))
	d := &device{t: t, base: invite}
	if err := d.auth("/auth/register", "a", "x"); codeOf(err) != "invalid_invite" {
		t.Fatalf("invite without code: %v", err)
	}
	d.must("POST", "/auth/register", map[string]any{"name": "a", "password": "password123", "inviteCode": "sesame"}, nil)
}

func TestInvalidToken(t *testing.T) {
	d := register(t, startServer(t), "a")
	d.Token = "forged"
	if err := d.do("GET", "/sync", nil, nil); statusOf(err) != 401 {
		t.Fatalf("forged token: %v", err)
	}
}

func TestIntegrationsAreForSignedInUsers(t *testing.T) {
	base := startServer(t, withKlipyAPIKey("klipy-key_1"))
	var got protocol.Integrations
	register(t, base, "a").must("GET", "/integrations", nil, &got)
	if got.KlipyAPIKey != "klipy-key_1" {
		t.Fatalf("integrations %+v", got)
	}
	anon := &device{t: t, base: base}
	if err := anon.do("GET", "/integrations", nil, nil); statusOf(err) != 401 {
		t.Fatalf("without a token: %v", err)
	}
	var info map[string]any
	anon.must("GET", "/server", nil, &info)
	for key, value := range info {
		if value == "klipy-key_1" {
			t.Fatalf("/server shows the key as %q", key)
		}
	}

	// Without a key: nothing.
	var none map[string]any
	register(t, startServer(t), "b").must("GET", "/integrations", nil, &none)
	if len(none) != 0 {
		t.Fatalf("integrations without a key: %v", none)
	}
}

func TestConversations(t *testing.T) {
	base := startServer(t)
	a, b := register(t, base, "a"), register(t, base, "b")
	first := a.createConversation("", b.UserID)
	if !first.IsDirect {
		t.Fatalf("direct chat %+v", first)
	}
	newConversation := func(members ...string) map[string]any {
		return map[string]any{"id": ulid.Make().String(), "members": members, "mls": newGroupBody()}
	}
	if err := a.do("POST", "/conversations", newConversation(b.UserID, "c@"+testHost), nil); codeOf(err) != "user_not_found" {
		t.Fatalf("unknown member: %v", err)
	}
	if err := a.do("POST", "/conversations", newConversation(), nil); statusOf(err) != 400 {
		t.Fatalf("nobody else: %v", err)
	}
	c := register(t, base, "c")
	group := a.createConversation("Seminar", b.UserID, c.UserID)
	if group.IsDirect || len(group.Members) != 3 {
		t.Fatalf("group %+v", group)
	}
	// A group of two is not a direct chat.
	if pair := a.createConversation("Pair", b.UserID); pair.IsDirect {
		t.Fatalf("pair %+v", pair)
	}
}

func TestNonMembersAreKeptOut(t *testing.T) {
	base := startServer(t)
	a, b, outsider := register(t, base, "a"), register(t, base, "b"), register(t, base, "outsider")
	conv := a.createConversation("", b.UserID)
	a.sendREST(conv.ID, "secret")
	if err := outsider.do("GET", "/conversations/"+conv.ID+"/messages", nil, nil); statusOf(err) != 404 {
		t.Fatalf("history: %v", err)
	}
	ack := outsider.connect().sendWS(outsider.textEnvelope(conv.ID, "hi"))
	if ack["type"] != "nack" || ack["error"] != "not_found" {
		t.Fatalf("send: %v", ack)
	}
	if len(outsider.syncSince(0).Events) != 0 {
		t.Fatal("outsider sees events")
	}
}

func TestMembershipChanges(t *testing.T) {
	base := startServer(t)
	a, b, c := register(t, base, "a"), register(t, base, "b"), register(t, base, "c")
	group := a.createConversation("Club", b.UserID)
	a.sendREST(group.ID, "before c joined")
	cCursor := c.syncSince(0).Cursor

	if err := a.addMember(group.ID, c.UserID); err != nil {
		t.Fatal(err)
	}
	// c learns about the conversation, then sees the commit that added them.
	events := c.syncSince(cCursor).Events
	if len(events) != 2 || events[0].Type != protocol.EventMemberAdded || events[1].Type != protocol.EventMLSCommit {
		t.Fatalf("c's events %+v", events)
	}
	var history protocol.HistoryPage
	c.must("GET", "/conversations/"+group.ID+"/messages", nil, &history)
	if len(history.Messages) != 1 || envelopeText(history.Messages[0]) != "before c joined" {
		t.Fatalf("history %+v", history)
	}

	bCursor := b.syncSince(0).Cursor
	b.must("POST", "/conversations/"+group.ID+"/leave", map[string]any{}, nil)
	bEvents := b.syncSince(bCursor).Events
	if len(bEvents) != 1 || bEvents[0].Type != protocol.EventMemberRemoved {
		t.Fatalf("leaver's events %+v", bEvents)
	}
	afterLeave := b.syncSince(0).Cursor
	a.sendREST(group.ID, "after b left")
	if len(b.syncSince(afterLeave).Events) != 0 {
		t.Fatal("leaver still receives messages")
	}
	var types []string
	for _, e := range c.syncSince(cCursor).Events {
		types = append(types, e.Type)
	}
	if want := []string{"member_added", "mls_commit", "member_removed", "message"}; !slices.Equal(types, want) {
		t.Fatalf("c's events %v, want %v", types, want)
	}
}

func TestSendOverWebSocketReachesEveryDevice(t *testing.T) {
	base := startServer(t)
	a1 := register(t, base, "a")
	a2 := login(t, base, "a", "desktop")
	b := register(t, base, "b")
	conv := a1.createConversation("", b.UserID)
	s1, s2, sb := a1.connect(), a2.connect(), b.connect()

	env := a1.textEnvelope(conv.ID, "Hello from my phone")
	ack := s1.sendWS(env)
	if ack["type"] != "ack" {
		t.Fatalf("send: %v", ack)
	}
	seq := int64(ack["seq"].(float64))
	for _, s := range []*socket{s1, s2, sb} {
		ev := s.nextEvent()
		if ev.Seq != seq || ev.Type != protocol.EventMessage || envelopeText(ev) != "Hello from my phone" {
			t.Fatalf("event %+v", ev)
		}
	}
}

func TestRetriesAreIdempotent(t *testing.T) {
	base := startServer(t)
	a, b := register(t, base, "a"), register(t, base, "b")
	conv := a.createConversation("", b.UserID)
	s := a.connect()
	env := a.textEnvelope(conv.ID, "once")
	first, second := s.sendWS(env), s.sendWS(env)
	if first["seq"] != second["seq"] {
		t.Fatalf("retry got a new seq: %v vs %v", first, second)
	}
	count := 0
	for _, e := range b.syncSince(0).Events {
		if e.Type == protocol.EventMessage {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("%d copies stored", count)
	}
	forged := map[string]any{}
	for k, v := range env {
		forged[k] = v
	}
	forged["from"] = b.UserID
	forged["device"] = b.DeviceID
	if ack := b.connect().sendWS(forged); ack["error"] != "id_conflict" {
		t.Fatalf("same ID from someone else: %v", ack)
	}
	if ack := s.sendWS(envelope(conv.ID, b.UserID, a.DeviceID, "x")); ack["error"] != "forbidden" {
		t.Fatalf("sending as someone else: %v", ack)
	}
	if ack := s.sendWS(map[string]any{"v": 1, "id": "nope"}); ack["error"] != "bad_request" {
		t.Fatalf("malformed envelope: %v", ack)
	}
}

func TestOfflineDeviceCatchesUp(t *testing.T) {
	base := startServer(t)
	phone := register(t, base, "a")
	desktop := login(t, base, "a", "desktop")
	b := register(t, base, "b")
	conv := phone.createConversation("", b.UserID)
	cursor := desktop.syncSince(0).Cursor

	phone.sendREST(conv.ID, "one")
	b.sendREST(conv.ID, "two")
	phone.sendREST(conv.ID, "three")
	c := register(t, base, "c")
	other := b.createConversation("", c.UserID)
	b.sendREST(other.ID, "not for a")

	page := desktop.syncSince(cursor)
	var texts []string
	for _, e := range page.Events {
		texts = append(texts, envelopeText(e))
	}
	if !slices.Equal(texts, []string{"one", "two", "three"}) || page.More {
		t.Fatalf("caught up on %v", texts)
	}
	if len(desktop.syncSince(page.Cursor).Events) != 0 {
		t.Fatal("events after the final cursor")
	}
}

func TestSyncPages(t *testing.T) {
	base := startServer(t)
	a, b := register(t, base, "a"), register(t, base, "b")
	conv := a.createConversation("", b.UserID)
	for i := range 5 {
		a.sendREST(conv.ID, fmt.Sprintf("m%d", i))
	}
	var texts []string
	var cursor int64
	for {
		var page protocol.SyncPage
		b.must("GET", fmt.Sprintf("/sync?since=%d&limit=2", cursor), nil, &page)
		for _, e := range page.Events {
			if e.Type == protocol.EventMessage {
				texts = append(texts, envelopeText(e))
			}
		}
		cursor = page.Cursor
		if !page.More {
			break
		}
	}
	if !slices.Equal(texts, []string{"m0", "m1", "m2", "m3", "m4"}) {
		t.Fatalf("paged %v", texts)
	}
}

// Seqs come from AUTO_INCREMENT; the append lock must make commit order match
// seq order, or a device syncing mid-burst could skip a message forever.
func TestConcurrentSendersKeepSeqOrder(t *testing.T) {
	base := startServer(t)
	observer := register(t, base, "observer")
	var senders []*device
	members := []string{observer.UserID}
	for i := range 4 {
		d := register(t, base, fmt.Sprintf("s%d", i))
		senders = append(senders, d)
		members = append(members, d.UserID)
	}
	group := observer.createConversation("Busy", members[1:]...)
	live := observer.connect()

	var wg sync.WaitGroup
	var cursors []int64
	var mu sync.Mutex
	const perSender = 25
	// A reader syncs incrementally while the senders write.
	stop := make(chan struct{})
	seen := map[int64]bool{}
	go func() {
		var cursor int64
		for {
			page := observer.syncSince(cursor)
			mu.Lock()
			for _, e := range page.Events {
				seen[e.Seq] = true
			}
			cursors = append(cursors, page.Cursor)
			mu.Unlock()
			cursor = page.Cursor
			select {
			case <-stop:
				return
			default:
			}
		}
	}()
	for _, d := range senders {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s := d.connect()
			for i := range perSender {
				if ack := s.sendWS(d.textEnvelope(group.ID, fmt.Sprint(i))); ack["type"] != "ack" {
					t.Errorf("send: %v", ack)
				}
			}
		}()
	}
	wg.Wait()
	close(stop)

	all := observer.syncSince(0).Events
	var messages []protocol.SyncEvent
	for _, e := range all {
		if e.Type == protocol.EventMessage {
			messages = append(messages, e)
		}
	}
	if len(messages) != 4*perSender {
		t.Fatalf("stored %d messages", len(messages))
	}
	// Live events arrive in strictly increasing seq order.
	var last int64
	for range messages {
		ev := live.nextEvent()
		if ev.Seq <= last {
			t.Fatalf("live seq %d after %d", ev.Seq, last)
		}
		last = ev.Seq
	}
	// The incremental reader, plus one final sync from its last cursor,
	// saw every message: nothing was skipped by a cursor jump.
	mu.Lock()
	finalCursor := cursors[len(cursors)-1]
	mu.Unlock()
	for _, e := range observer.syncSince(finalCursor).Events {
		seen[e.Seq] = true
	}
	for _, m := range messages {
		if !seen[m.Seq] {
			t.Fatalf("incremental sync skipped seq %d", m.Seq)
		}
	}
}

func TestReadStateSyncsToOwnDevicesOnly(t *testing.T) {
	base := startServer(t)
	a1 := register(t, base, "a")
	a2 := login(t, base, "a", "desktop")
	b := register(t, base, "b")
	conv := a1.createConversation("", b.UserID)
	seq := b.sendREST(conv.ID, "are you there?")
	s1, s2, sb := a1.connect(), a2.connect(), b.connect()

	s1.send(map[string]any{"type": "read", "rid": "r1", "conv": conv.ID, "upTo": seq})
	if ack := s1.nextOfType("ack"); ack["rid"] != "r1" || int64(ack["readUpTo"].(float64)) != seq {
		t.Fatalf("read ack %v", ack)
	}
	ev := s2.nextEvent()
	var data struct{ UpTo int64 }
	_ = json.Unmarshal(ev.Data, &data)
	if ev.Type != protocol.EventReadMarker || data.UpTo != seq {
		t.Fatalf("read marker event %+v", ev)
	}
	sb.expectSilence()

	// Moving the marker backwards is a no-op.
	s1.send(map[string]any{"type": "read", "rid": "r2", "conv": conv.ID, "upTo": 0})
	if ack := s1.nextOfType("ack"); int64(ack["readUpTo"].(float64)) != seq {
		t.Fatalf("marker moved back: %v", ack)
	}
	s2.expectSilence()
}

func TestSnapshotAndHistory(t *testing.T) {
	base := startServer(t)
	a, b := register(t, base, "a"), register(t, base, "b")
	conv := a.createConversation("", b.UserID)
	for i := range 35 {
		b.sendREST(conv.ID, fmt.Sprintf("m%d", i))
	}
	last := a.sendREST(conv.ID, "caught up")
	a.must("POST", "/conversations/"+conv.ID+"/read", map[string]any{"upTo": last}, nil)

	fresh := login(t, base, "a", "new laptop")
	snap := fresh.snapshot()
	if len(snap.Conversations) != 1 {
		t.Fatalf("snapshot %+v", snap)
	}
	c := snap.Conversations[0]
	if c.ReadUpTo != last || len(c.Messages) != 30 || !c.MoreHistory || snap.Cursor < last {
		t.Fatalf("snapshot conversation: readUpTo=%d messages=%d more=%v", c.ReadUpTo, len(c.Messages), c.MoreHistory)
	}
	if envelopeText(c.Messages[0]) != "m6" || envelopeText(c.Messages[29]) != "caught up" {
		t.Fatal("snapshot holds the wrong messages")
	}
	var older protocol.HistoryPage
	fresh.must("GET", fmt.Sprintf("/conversations/%s/messages?before=%d&limit=10", conv.ID, c.Messages[0].Seq), nil, &older)
	var texts []string
	for _, e := range older.Messages {
		texts = append(texts, envelopeText(e))
	}
	if !slices.Equal(texts, []string{"m0", "m1", "m2", "m3", "m4", "m5"}) || older.More {
		t.Fatalf("older history %v more=%v", texts, older.More)
	}
}

func TestTypingReachesOthersOnly(t *testing.T) {
	base := startServer(t)
	a1 := register(t, base, "a")
	a2 := login(t, base, "a", "desktop")
	b := register(t, base, "b")
	conv := a1.createConversation("", b.UserID)
	s1, s2, sb := a1.connect(), a2.connect(), b.connect()
	s1.send(map[string]any{"type": "typing", "conv": conv.ID})
	if f := sb.next(); f["type"] != "typing" || f["user"] != a1.UserID || f["conv"] != conv.ID {
		t.Fatalf("typing frame %v", f)
	}
	s2.expectSilence()
}

func TestDevices(t *testing.T) {
	base := startServer(t)
	phone := register(t, base, "a")
	laptop := login(t, base, "a", "work laptop")
	laptopSocket := laptop.connect()

	var res struct{ Devices []protocol.DeviceInfo }
	phone.must("GET", "/devices", nil, &res)
	if len(res.Devices) != 2 {
		t.Fatalf("devices %+v", res.Devices)
	}
	for _, d := range res.Devices {
		if d.Current != (d.ID == phone.DeviceID) {
			t.Fatalf("current flag wrong: %+v", d)
		}
	}

	phone.must("DELETE", "/devices/"+laptop.DeviceID, nil, nil)
	if f := laptopSocket.next(); f["error"] != "session_revoked" {
		t.Fatalf("revoked socket got %v", f)
	}
	select {
	case <-laptopSocket.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("revoked socket stayed open")
	}
	if err := laptop.do("GET", "/sync", nil, nil); statusOf(err) != 401 {
		t.Fatalf("revoked token: %v", err)
	}
	if err := phone.do("DELETE", "/devices/"+laptop.DeviceID, nil, nil); statusOf(err) != 404 {
		t.Fatalf("second revoke: %v", err)
	}
}

func TestLogoutEndsOnlyThisDevice(t *testing.T) {
	base := startServer(t)
	phone := register(t, base, "a")
	laptop := login(t, base, "a", "laptop")
	laptop.must("POST", "/auth/logout", map[string]any{}, nil)
	if err := laptop.do("GET", "/devices", nil, nil); statusOf(err) != 401 {
		t.Fatalf("logged-out token: %v", err)
	}
	phone.must("GET", "/devices", nil, nil)
}
