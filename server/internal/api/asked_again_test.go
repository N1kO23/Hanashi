package api_test

import (
	"testing"

	"github.com/oklog/ulid/v2"

	"hanashi/server/internal/protocol"
	"hanashi/server/internal/store"
)

// countEvents counts d's events of a type since cursor.
func countEvents(d *device, cursor int64, typ string) int {
	n := 0
	for _, e := range d.syncSince(cursor).Events {
		if e.Type == typ {
			n++
		}
	}
	return n
}

// An app whose answer got lost asks again with the same request, and must not
// get a second conversation, or its members a second Welcome.
func TestCreatingAgainGetsTheSameConversation(t *testing.T) {
	base := startServer(t)
	a, b, c := register(t, base, "a"), register(t, base, "b"), register(t, base, "c")
	a.makeContact(b.UserID)
	id := ulid.Make().String()
	body := map[string]any{"id": id, "members": []string{b.UserID}, "mls": map[string]any{
		"epoch": 1, "groupInfo": fakeMLS,
		"welcomes": []map[string]any{{"device": b.DeviceID, "data": fakeMLS}},
	}}
	var first, again protocol.ConversationInfo
	a.must("POST", "/conversations", body, &first)
	a.must("POST", "/conversations", body, &again)
	if first.ID != id || again.ID != id || len(again.Members) != 2 {
		t.Fatalf("first %+v, again %+v", first, again)
	}
	if n := countEvents(b, 0, protocol.EventConversationCreated); n != 1 {
		t.Fatalf("%d conversation_created events", n)
	}
	if n := len(b.inbox()); n != 1 {
		t.Fatalf("%d Welcomes", n)
	}
	// Nobody else can take it over.
	c.makeContact(b.UserID)
	if err := c.do("POST", "/conversations", body, nil); codeOf(err) != "id_taken" {
		t.Fatalf("someone else's: %v", err)
	}
}

func TestStartingADirectChatAgainGetsTheSameChat(t *testing.T) {
	base := startServer(t)
	a, b := register(t, base, "a"), register(t, base, "b")
	a.request(b.UserID)
	if err := b.accept(a.UserID); err != nil {
		t.Fatal(err)
	}
	body := map[string]any{"id": ulid.Make().String(), "members": []string{a.UserID}, "direct": true, "mls": map[string]any{
		"epoch": 1, "groupInfo": fakeMLS,
		"welcomes": []map[string]any{{"device": a.DeviceID, "data": fakeMLS}},
	}}
	var first, again protocol.ConversationInfo
	b.must("POST", "/conversations", body, &first)
	b.must("POST", "/conversations", body, &again)
	if again.ID != first.ID {
		t.Fatalf("first %+v, again %+v", first, again)
	}
	if n := countEvents(a, 0, protocol.EventConversationCreated); n != 1 {
		t.Fatalf("%d conversation_created events", n)
	}
	if n := len(a.inbox()); n != 1 {
		t.Fatalf("%d Welcomes", n)
	}
	// Once they are no longer contacts, there is nothing to accept.
	a.must("DELETE", "/contacts/"+b.UserID, nil, nil)
	if err := b.accept(a.UserID); codeOf(err) != "no_request" {
		t.Fatalf("after it ended: %v", err)
	}
	if got := b.contactState(a.UserID); got != store.ViewNone {
		t.Fatalf("after it ended, %q", got)
	}
}
