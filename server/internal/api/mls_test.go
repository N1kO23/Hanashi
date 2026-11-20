package api_test

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/oklog/ulid/v2"

	"hanashi/server/internal/protocol"
)

type inboxItem struct {
	ID         int64
	Type       string
	FromUser   string
	FromDevice string
	Data       struct {
		Conv  string
		Epoch int64
		Data  string
	}
}

func (d *device) inbox() []inboxItem {
	d.t.Helper()
	var res struct{ Items []inboxItem }
	d.must("GET", "/inbox", nil, &res)
	return res.Items
}

func TestLeases(t *testing.T) {
	base := startServer(t, withLeaseDuration(300*time.Millisecond))
	a1 := register(t, base, "a")
	a2 := login(t, base, "a", "laptop")
	b := register(t, base, "b")
	conv := a1.createConversation("", b.UserID)

	leaseID, epoch := a1.lease(conv.ID)
	if epoch != 1 || leaseID == "" {
		t.Fatalf("lease %q at epoch %d", leaseID, epoch)
	}
	if err := a2.do("POST", "/conversations/"+conv.ID+"/lease", map[string]any{}, nil); codeOf(err) != "lease_held" {
		t.Fatalf("second device: %v", err)
	}
	if again, _ := a1.lease(conv.ID); again == leaseID {
		t.Fatal("renewing must hand out a new lease")
	}
	outsider := register(t, base, "outsider")
	if err := outsider.do("POST", "/conversations/"+conv.ID+"/lease", map[string]any{}, nil); statusOf(err) != 404 {
		t.Fatalf("non-member: %v", err)
	}
	time.Sleep(400 * time.Millisecond)
	if err := a2.do("POST", "/conversations/"+conv.ID+"/lease", map[string]any{}, nil); err != nil {
		t.Fatalf("after expiry: %v", err)
	}
}

func TestLeasesForDevicesBehindAndGivenBack(t *testing.T) {
	base := startServer(t)
	a1 := register(t, base, "a")
	a2 := login(t, base, "a", "laptop")
	b := register(t, base, "b")
	conv := a1.createConversation("", b.UserID)
	path := "/conversations/" + conv.ID + "/lease"

	// A device whose group is behind gets none, and so holds up nobody.
	if err := a1.do("POST", path, map[string]any{"epoch": 0}, nil); codeOf(err) != "epoch_mismatch" {
		t.Fatalf("behind: %v", err)
	}
	var held struct {
		LeaseID string
		Epoch   int64
	}
	a2.must("POST", path, map[string]any{"epoch": 1}, &held)

	// Only the holder gives it back, and only the lease it was given.
	b.must("DELETE", path+"/"+held.LeaseID, nil, nil)
	a2.must("DELETE", path+"/someone-elses", nil, nil)
	if err := a1.do("POST", path, map[string]any{}, nil); codeOf(err) != "lease_held" {
		t.Fatalf("released by others: %v", err)
	}
	a2.must("DELETE", path+"/"+held.LeaseID, nil, nil)
	leaseID, _ := a1.lease(conv.ID)
	if leaseID == "" {
		t.Fatal("no lease after it was given back")
	}
}

func TestDebugLogSaysWhoDidWhatWithoutSecrets(t *testing.T) {
	base, logs := startServerLogging(t)
	a1 := register(t, base, "a")
	a2 := login(t, base, "a", "laptop")
	b := register(t, base, "b")
	conv := a1.createConversation("", b.UserID)
	path := "/conversations/" + conv.ID + "/lease"

	a1.lease(conv.ID)
	if err := a2.do("POST", path, map[string]any{"epoch": 0}, nil); codeOf(err) != "epoch_mismatch" {
		t.Fatalf("behind: %v", err)
	}
	if err := a2.do("POST", path, map[string]any{}, nil); codeOf(err) != "lease_held" {
		t.Fatalf("held: %v", err)
	}
	out := logs.String()
	for _, want := range []string{
		`msg="signed in" user=a@test.local device=` + a2.DeviceID + ` platform=test`,
		`msg="conversation created" user=a@test.local device=` + a1.DeviceID + ` conv=` + conv.ID,
		`msg="lease granted" user=a@test.local device=` + a1.DeviceID + ` conv=` + conv.ID + ` epoch=1`,
		`msg="lease refused: other epoch" user=a@test.local device=` + a2.DeviceID + ` conv=` + conv.ID +
			` device_epoch=0 epoch=1`,
		`msg="lease refused: held" user=a@test.local device=` + a2.DeviceID + ` conv=` + conv.ID + ` epoch=1 holder=` +
			a1.DeviceID,
		`msg=request method=POST path=` + path + ` status=409`,
		`user=a@test.local device=` + a2.DeviceID + ` error=lease_held message="Another device`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("log lacks %s", want)
		}
	}
	for _, secret := range []string{a1.Token, a2.Token, b.Token, "password123"} {
		if strings.Contains(out, secret) {
			t.Error("the log holds a secret")
		}
	}
	if t.Failed() {
		t.Log(out)
	}
}

func TestOnlyVerifiedDevicesChangeGroupsOrSend(t *testing.T) {
	base := startServer(t)
	a1 := register(t, base, "a")
	a1.setUpIdentity()
	b := register(t, base, "b")
	conv := a1.createConversation("", b.UserID)
	a1.must("POST", "/messages", a1.textEnvelope(conv.ID, "hi"), nil)

	// Signed in, but not verified yet; or left over from before a reset.
	a2 := login(t, base, "a", "laptop")
	a2.setUpDevice()
	refused := func(d *device, why string) {
		t.Helper()
		leasePath := "/conversations/" + conv.ID + "/lease"
		for name, err := range map[string]error{
			"lease":    d.do("POST", leasePath, map[string]any{}, nil),
			"commit":   d.do("POST", "/conversations/"+conv.ID+"/commits", commitBody("any", 2), nil),
			"message":  d.do("POST", "/messages", d.textEnvelope(conv.ID, "hello"), nil),
			"new chat": d.do("POST", "/conversations", newConversationBody(b.UserID), nil),
		} {
			if codeOf(err) != "not_verified" {
				t.Errorf("%s, %s: %v", why, name, err)
			}
		}
	}
	refused(a2, "not verified yet")

	// Reset on the laptop: the first device is the one left over now.
	a2.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(freshKey(t)), "reset": true}, nil)
	refused(a1, "after a reset elsewhere")
	// Users who never set up encryption are not checked.
	b.lease(conv.ID)
}

func newConversationBody(members ...string) map[string]any {
	return map[string]any{
		"id": ulid.Make().String(), "members": members, "mls": map[string]any{"epoch": 1, "groupInfo": fakeMLS},
	}
}

func TestCommits(t *testing.T) {
	base := startServer(t, withLeaseDuration(300*time.Millisecond))
	a1 := register(t, base, "a")
	a2 := login(t, base, "a", "laptop")
	b := register(t, base, "b")
	conv := a1.createConversation("", b.UserID)
	path := "/conversations/" + conv.ID + "/commits"

	if err := a1.do("POST", path, commitBody("nope", 1), nil); codeOf(err) != "lease_invalid" {
		t.Fatalf("without a lease: %v", err)
	}
	leaseID, epoch := a1.lease(conv.ID)
	if err := a1.do("POST", path, commitBody(leaseID, epoch+1), nil); codeOf(err) != "epoch_mismatch" {
		t.Fatalf("wrong epoch: %v", err)
	}
	if err := a2.do("POST", path, commitBody(leaseID, epoch), nil); codeOf(err) != "lease_invalid" {
		t.Fatalf("someone else's lease: %v", err)
	}

	s1, s2, sb := a1.connect(), a2.connect(), b.connect()
	var res struct{ Seq int64 }
	a1.must("POST", path, commitBody(leaseID, epoch), &res)
	for _, s := range []*socket{s1, s2, sb} {
		ev := s.nextEvent()
		var data struct {
			Epoch  int64
			Device string
			MLS    string
		}
		_ = json.Unmarshal(ev.Data, &data)
		if ev.Type != protocol.EventMLSCommit || ev.Seq != res.Seq || data.Epoch != 1 || data.Device != a1.DeviceID {
			t.Fatalf("commit event %+v %+v", ev, data)
		}
	}
	var gi struct {
		Epoch int64
		Data  string
	}
	b.must("GET", "/conversations/"+conv.ID+"/group-info", nil, &gi)
	if gi.Epoch != 2 || gi.Data != fakeMLS {
		t.Fatalf("group info %+v", gi)
	}
	// The lease is released and the epoch moved on.
	newLease, newEpoch := a2.lease(conv.ID)
	if newEpoch != 2 {
		t.Fatalf("epoch after commit: %d", newEpoch)
	}
	// An expired lease cannot commit.
	time.Sleep(400 * time.Millisecond)
	if err := a2.do("POST", path, commitBody(newLease, newEpoch), nil); codeOf(err) != "lease_invalid" {
		t.Fatalf("expired lease: %v", err)
	}
	// Commits over the WebSocket.
	leaseID, epoch = a2.lease(conv.ID)
	s2.send(map[string]any{"type": "commit", "rid": "c1", "conv": conv.ID, "commit": commitBody(leaseID, epoch)})
	if ack := s2.nextOfType("ack"); ack["rid"] != "c1" {
		t.Fatalf("ws commit: %v", ack)
	}
}

func TestMessagesMustBeForTheCurrentEpoch(t *testing.T) {
	base := startServer(t)
	a, b, c := register(t, base, "a"), register(t, base, "b"), register(t, base, "c")
	group := a.createConversation("Club", b.UserID)
	sent := b.textEnvelope(group.ID, "sent at epoch 1")
	b.must("POST", "/messages", sent, nil)

	if err := a.addMember(group.ID, c.UserID); err != nil {
		t.Fatal(err)
	}
	// b has not seen the commit yet: c could not read this, so it is refused.
	late := envelope(group.ID, b.UserID, b.DeviceID, "still at epoch 1")
	if err := b.do("POST", "/messages", late, nil); codeOf(err) != "epoch_mismatch" {
		t.Fatalf("stale epoch: %v", err)
	}
	// Retrying a message the server already took still succeeds.
	b.must("POST", "/messages", sent, nil)
	b.must("POST", "/messages", b.textEnvelope(group.ID, "at epoch 2"), nil)
}

func TestWelcomesReachInboxes(t *testing.T) {
	base := startServer(t)
	a := register(t, base, "a")
	b := register(t, base, "b")
	b2 := login(t, base, "b", "laptop")
	stranger := register(t, base, "stranger")
	sb := b.connect()

	id := ulid.Make().String()
	welcome := base64.StdEncoding.EncodeToString([]byte("welcome bytes"))
	body := func(device string) map[string]any {
		return map[string]any{"id": ulid.Make().String(), "members": []string{b.UserID}, "mls": map[string]any{
			"epoch": 1, "groupInfo": fakeMLS, "welcomes": []map[string]any{{"device": device, "data": welcome}},
		}}
	}
	a.makeContact(b.UserID)
	if err := a.do("POST", "/conversations", body(stranger.DeviceID), nil); statusOf(err) != 400 {
		t.Fatalf("welcome to a non-member: %v", err)
	}
	req := body(b.DeviceID)
	req["id"] = id
	a.must("POST", "/conversations", req, nil)

	// Live to the online device, before the event that announces the
	// conversation (so the device can join instead of joining externally),
	// and waiting in its inbox until acknowledged.
	frame := sb.next()
	if frame["type"] != "inbox" {
		t.Fatalf("first frame %v, want the welcome", frame)
	}
	item := frame["item"].(map[string]any)
	if item["type"] != protocol.InboxWelcome || item["fromUser"] != a.UserID {
		t.Fatalf("pushed item %v", item)
	}
	if ev := sb.nextEvent(); ev.Type != protocol.EventConversationCreated {
		t.Fatalf("then %v", ev.Type)
	}
	items := b.inbox()
	if len(items) != 1 || items[0].Data.Conv != id || items[0].Data.Epoch != 1 || items[0].Data.Data != welcome {
		t.Fatalf("inbox %+v", items)
	}
	if len(b2.inbox()) != 0 {
		t.Fatal("another device got the welcome")
	}
	b.must("POST", "/inbox/ack", map[string]any{"ids": []int64{items[0].ID}}, nil)
	if len(b.inbox()) != 0 {
		t.Fatal("acknowledged item still there")
	}
}

func TestAddMemberIsAtomicWithItsCommit(t *testing.T) {
	base := startServer(t)
	a, b, c := register(t, base, "a"), register(t, base, "b"), register(t, base, "c")
	group := a.createConversation("Club", b.UserID)
	a.makeContact(c.UserID)
	// Without a valid lease nothing happens: c is not added.
	err := a.do("POST", "/conversations/"+group.ID+"/members", map[string]any{"user": c.UserID, "commit": commitBody("nope", 1)}, nil)
	if codeOf(err) != "lease_invalid" {
		t.Fatalf("add without lease: %v", err)
	}
	if err := c.do("GET", "/conversations/"+group.ID+"/messages", nil, nil); statusOf(err) != 404 {
		t.Fatal("c was added although the commit failed")
	}
	sc := c.connect()
	leaseID, epoch := a.lease(group.ID)
	welcome := map[string]any{"device": c.DeviceID, "data": fakeMLS}
	a.must("POST", "/conversations/"+group.ID+"/members", map[string]any{"user": c.UserID, "commit": commitBody(leaseID, epoch, welcome)}, nil)
	// The welcome first, then the membership change, then the commit: members
	// must know c belongs before they see c's devices in the group.
	if f := sc.next(); f["type"] != "inbox" {
		t.Fatalf("first frame %v, want the welcome", f)
	}
	for _, want := range []string{protocol.EventMemberAdded, protocol.EventMLSCommit} {
		if ev := sc.nextEvent(); ev.Type != want {
			t.Fatalf("got %s, want %s", ev.Type, want)
		}
	}
	if items := c.inbox(); len(items) != 1 || items[0].Data.Epoch != epoch+1 {
		t.Fatalf("c's inbox %+v", items)
	}
	if err := a.addMember(group.ID, c.UserID); codeOf(err) != "already_member" {
		t.Fatalf("adding twice: %v", err)
	}
}

func TestKeyPackages(t *testing.T) {
	base := startServer(t)
	a := register(t, base, "a")
	b := register(t, base, "b")
	kp := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

	mls := a.setUpDevice()
	upload := map[string]any{"packages": []string{kp("kp1"), kp("kp2")}, "lastResort": kp("last")}
	if err := a.do("POST", "/keys/packages", upload, nil); codeOf(err) != "not_verified" {
		t.Fatalf("unverified device: %v", err)
	}
	idPub, idPriv := newKey(t)
	a.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(idPub)}, nil)
	if err := a.sign(idPriv, a.DeviceID, mls); err != nil {
		t.Fatal(err)
	}
	var count struct {
		Count      int
		LastResort bool
	}
	a.must("POST", "/keys/packages", upload, &count)
	if count.Count != 2 || !count.LastResort {
		t.Fatalf("count %+v", count)
	}

	b.makeContact(a.UserID)
	claim := func() map[string]string {
		var res struct{ Packages map[string]string }
		b.must("POST", "/keys/packages/claim", map[string]any{"devices": []string{a.DeviceID, b.DeviceID}}, &res)
		return res.Packages
	}
	for _, want := range []string{"kp1", "kp2", "last", "last"} {
		got := claim()
		if got[a.DeviceID] != kp(want) {
			t.Fatalf("claimed %q, want %q", got[a.DeviceID], want)
		}
		if _, ok := got[b.DeviceID]; ok {
			t.Fatal("b has no key packages")
		}
	}
	a.must("GET", "/keys/packages/count", nil, &count)
	if count.Count != 0 || !count.LastResort {
		t.Fatalf("after claims %+v", count)
	}
}
