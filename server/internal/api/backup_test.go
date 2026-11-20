package api_test

import (
	"encoding/base64"
	"strconv"
	"testing"

	"github.com/oklog/ulid/v2"
)

type backupEntries struct {
	Entries map[string]string `json:"entries"`
}

func (d *device) backUp(version int, entries map[string]string) (int, error) {
	list := []map[string]string{}
	for id, data := range entries {
		list = append(list, map[string]string{"id": id, "data": data})
	}
	var res struct{ Accepted int }
	err := d.do("POST", "/keys/backup", map[string]any{"identityVersion": version, "entries": list}, &res)
	return res.Accepted, err
}

func (d *device) backupOf(ids ...string) map[string]string {
	var res backupEntries
	d.must("POST", "/keys/backup/query", map[string]any{"ids": ids}, &res)
	return res.Entries
}

func TestDeletingMessages(t *testing.T) {
	base := startServer(t)
	a, b := register(t, base, "a"), register(t, base, "b")
	a.setUpIdentity()
	conv := a.createConversation("", b.UserID)
	send := func(d *device, text string) string {
		env := d.textEnvelope(conv.ID, text)
		d.must("POST", "/messages", env, nil)
		return env["id"].(string)
	}
	gone, kept, theirs := send(a, "oops"), send(a, "fine"), send(b, "mine")
	sealed := base64.StdEncoding.EncodeToString([]byte("sealed content key"))
	if n, err := a.backUp(1, map[string]string{gone: sealed, kept: sealed, theirs: sealed}); err != nil || n != 3 {
		t.Fatalf("backed up %d, %v", n, err)
	}

	// Only the sender's own messages go; unknown IDs are ignored.
	var res struct{ Deleted int }
	a.must("POST", "/messages/delete", map[string]any{"ids": []string{gone, theirs, ulid.Make().String()}}, &res)
	if res.Deleted != 1 {
		t.Fatalf("deleted %d", res.Deleted)
	}
	var history struct {
		Messages []struct {
			Data struct{ ID string }
		}
	}
	b.must("GET", "/conversations/"+conv.ID+"/messages", nil, &history)
	var ids []string
	for _, m := range history.Messages {
		ids = append(ids, m.Data.ID)
	}
	if len(ids) != 2 || ids[0] != kept || ids[1] != theirs {
		t.Fatalf("history %v", ids)
	}
	if got := a.backupOf(gone, kept, theirs); len(got) != 2 || got[gone] != "" {
		t.Fatalf("backup %v", got)
	}
	// Deleting again is harmless.
	a.must("POST", "/messages/delete", map[string]any{"ids": []string{gone}}, &res)
	if res.Deleted != 0 {
		t.Fatalf("deleted again %d", res.Deleted)
	}
	for name, ids := range map[string][]string{"none": {}, "not an id": {"x"}} {
		if err := a.do("POST", "/messages/delete", map[string]any{"ids": ids}, nil); statusOf(err) != 400 {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestKeyBackup(t *testing.T) {
	base := startServer(t)
	a, b, stranger := register(t, base, "a"), register(t, base, "b"), register(t, base, "stranger")
	a.setUpIdentity()
	conv := a.createConversation("", b.UserID)
	env := a.textEnvelope(conv.ID, "hi")
	a.must("POST", "/messages", env, nil)
	msgID := env["id"].(string)
	sealed := base64.StdEncoding.EncodeToString([]byte("sealed content key"))

	// Only for the current identity.
	if _, err := a.backUp(2, map[string]string{msgID: sealed}); codeOf(err) != "identity_changed" {
		t.Fatalf("stale identity: %v", err)
	}
	// Messages the user cannot see (or that do not exist) are ignored.
	laptop := login(t, base, "a", "laptop")
	onLaptop := laptop.connect()
	accepted, err := a.backUp(1, map[string]string{msgID: sealed, ulid.Make().String(): sealed})
	if err != nil || accepted != 1 {
		t.Fatalf("accepted %d, %v", accepted, err)
	}
	// The user's other devices hear about it: their waiting messages may be readable now.
	if f := onLaptop.nextOfType("backup"); f == nil {
		t.Fatal("no backup notice")
	}
	strangerID, _ := newKey(t)
	stranger.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(strangerID)}, nil)
	if accepted, _ := stranger.backUp(1, map[string]string{msgID: sealed}); accepted != 0 {
		t.Fatal("a non-member backed up another conversation's message")
	}
	// The first entry stays.
	other := base64.StdEncoding.EncodeToString([]byte("another"))
	if _, err := a.backUp(1, map[string]string{msgID: other}); err != nil {
		t.Fatal(err)
	}
	if got := a.backupOf(msgID, ulid.Make().String()); len(got) != 1 || got[msgID] != sealed {
		t.Fatalf("backup %v", got)
	}
	// Each user has their own backup.
	if got := b.backupOf(msgID); len(got) != 0 {
		t.Fatalf("b sees a's backup: %v", got)
	}

	for name, body := range map[string]map[string]any{
		"no entries": {"identityVersion": 1, "entries": []any{}},
		"bad id":     {"identityVersion": 1, "entries": []any{map[string]string{"id": "x", "data": sealed}}},
		"too large": {"identityVersion": 1, "entries": []any{map[string]string{
			"id": msgID, "data": base64.StdEncoding.EncodeToString(make([]byte, 600))}}},
	} {
		if err := a.do("POST", "/keys/backup", body, nil); statusOf(err) != 400 {
			t.Errorf("%s: %v", name, err)
		}
	}

	// Resetting the identity makes the old backup unreadable, so it goes.
	newPub, _ := newKey(t)
	a.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(newPub), "reset": true}, nil)
	if got := a.backupOf(msgID); len(got) != 0 {
		t.Fatalf("backup survived the reset: %v", got)
	}
	if _, err := a.backUp(1, map[string]string{msgID: sealed}); codeOf(err) != "identity_changed" {
		t.Fatalf("upload for the old identity: %v", err)
	}
}

func TestConversationKeyBackup(t *testing.T) {
	base := startServer(t)
	a, b, c := register(t, base, "a"), register(t, base, "b"), register(t, base, "c")
	a.setUpIdentity()
	conv := a.createConversation("Club", b.UserID)
	other := a.createConversation("", c.UserID)
	send := func(conv, text string) string {
		env := a.textEnvelope(conv, text)
		a.must("POST", "/messages", env, nil)
		return env["id"].(string)
	}
	// The second message has no entry: none of a's devices read it.
	first, _, last := send(conv.ID, "1"), send(conv.ID, "2"), send(conv.ID, "3")
	elsewhere := send(other.ID, "x")
	sealed := base64.StdEncoding.EncodeToString([]byte("sealed content key"))
	if _, err := a.backUp(1, map[string]string{first: sealed, last: sealed, elsewhere: sealed}); err != nil {
		t.Fatal(err)
	}

	type page struct {
		Entries []struct {
			ID   string
			Seq  int64
			Data string
		}
		More bool
	}
	var got page
	a.must("GET", "/keys/backup?conv="+conv.ID, nil, &got)
	// Only this conversation's messages with an entry, oldest first.
	if len(got.Entries) != 2 || got.Entries[0].ID != first || got.Entries[1].ID != last || got.More ||
		got.Entries[0].Data != sealed || got.Entries[0].Seq >= got.Entries[1].Seq {
		t.Fatalf("entries %+v", got)
	}
	a.must("GET", "/keys/backup?conv="+conv.ID+"&after="+strconv.FormatInt(got.Entries[0].Seq, 10), nil, &got)
	if len(got.Entries) != 1 || got.Entries[0].ID != last {
		t.Fatalf("after the first: %+v", got)
	}
	// Each user has their own backup, and only members may ask.
	b.must("GET", "/keys/backup?conv="+conv.ID, nil, &got)
	if len(got.Entries) != 0 {
		t.Fatalf("b sees a's backup: %+v", got)
	}
	if err := c.do("GET", "/keys/backup?conv="+conv.ID, nil, nil); statusOf(err) != 404 {
		t.Fatalf("non-member: %v", err)
	}
}
