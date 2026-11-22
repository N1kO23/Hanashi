package api_test

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"hanashi/server/internal/config"
	"hanashi/server/internal/store"
)

func withHandOverAll() serverOption {
	return func(c *config.Config) { c.HandOver = config.HandOverAll }
}

// withQuickHandOvers has a conversation that could not be handed over tried
// again soon, and with HANASHI_HAND_OVER=all, new ones found soon.
func withQuickHandOvers() serverOption {
	return func(c *config.Config) { c.HandOverRetry = 100 * time.Millisecond }
}

// withoutHubMove makes the server one from before 1.1.0, which cannot follow a move.
func withoutHubMove() serverOption {
	return func(c *config.Config) { c.NoHubMove = true }
}

// hubOf is who orders conv, as base's server has it.
func hubOf(t *testing.T, base, conv string) store.Hub {
	t.Helper()
	st, _ := stores.Load(base)
	hub, err := st.(*store.Store).ConversationHub(context.Background(), conv)
	if err != nil {
		t.Fatalf("%s has no %s: %v", base, conv, err)
	}
	return hub
}

// moved waits until the server of each of ds has conv ordered by hub, from
// term on.
func moved(t *testing.T, conv, hub string, term int64, ds ...*device) {
	t.Helper()
	for _, d := range ds {
		eventually(t, d.UserID+"'s server has it of "+hub, func() bool {
			at := hubOf(t, d.base, conv)
			if d.UserID[strings.LastIndex(d.UserID, "@")+1:] == hub {
				return at.Host == "" && at.Term == term
			}
			return at.Host == hub && at.Term == term
		})
	}
}

// everyoneHas waits until each of ds has want of conv's history.
func everyoneHas(t *testing.T, conv, want string, ds ...*device) {
	t.Helper()
	for _, d := range ds {
		eventually(t, d.UserID+" has "+want, func() bool { return fmt.Sprint(d.texts(conv)) == want })
	}
}

// A group goes on without the server it was made on, once none of its users
// are in it: that server hands it to the one with the most of its members,
// which can hand it on in turn. Servers that join later have all of it, from
// that hub.
func TestGroupMovesWhenItsServerIsLeft(t *testing.T) {
	bases, gates := federatedServers(t, []string{"a.test", "b.test", "c.test", "d.test", "e.test"})
	sota, kumiko := register(t, bases[0], "sota"), register(t, bases[1], "kumiko")
	naoko, hiroko := register(t, bases[2], "naoko"), register(t, bases[2], "hiroko")
	yoko, emi := register(t, bases[3], "yoko"), register(t, bases[4], "emi")
	for _, d := range []*device{sota, kumiko, naoko, hiroko, yoko, emi} {
		d.setUpIdentity()
	}
	befriend(t, sota, kumiko)
	befriend(t, sota, naoko)
	befriend(t, kumiko, hiroko)
	befriend(t, naoko, yoko)
	befriend(t, yoko, kumiko)
	befriend(t, yoko, emi)
	sota.must("GET", "/keys/users/"+kumiko.UserID, nil, nil)
	sota.must("GET", "/keys/users/"+naoko.UserID, nil, nil)
	group := sota.startGroup([]string{kumiko.UserID, naoko.UserID}, kumiko.DeviceID, naoko.DeviceID)
	eventually(t, "both have it", func() bool { return kumiko.inConversation(group.ID) && naoko.inConversation(group.ID) })
	kumiko.must("GET", "/keys/users/"+hiroko.UserID, nil, nil)
	if err := kumiko.addTo(group.ID, hiroko.UserID, hiroko.DeviceID); err != nil {
		t.Fatal(err)
	}
	sota.sendREST(group.ID, "from a")
	kumiko.sendREST(group.ID, "from b")

	// Sota leaves, the last of a.test: c.test has two of its members, and
	// orders it from then on.
	sota.must("POST", "/conversations/"+group.ID+"/leave", map[string]any{}, nil)
	moved(t, group.ID, "c.test", 1, sota, kumiko, naoko)
	gates[0].shut.Store(true)
	kumiko.sendREST(group.ID, "after a")
	naoko.sendREST(group.ID, "from c")
	everyoneHas(t, group.ID, "[from a from b after a from c]", kumiko, naoko, hiroko)
	// Commits go through c.test's lease.
	leaseID, epoch := kumiko.lease(group.ID)
	kumiko.must("POST", "/conversations/"+group.ID+"/commits", commitBody(leaseID, epoch), nil)

	// d.test, which has nothing of it, joins: it takes all of it from c.test,
	// a.test's part too.
	naoko.must("GET", "/keys/users/"+yoko.UserID, nil, nil)
	if err := naoko.addTo(group.ID, yoko.UserID, yoko.DeviceID); err != nil {
		t.Fatal(err)
	}
	eventually(t, "yoko has it, with its history", func() bool {
		return yoko.inConversation(group.ID) && fmt.Sprint(yoko.texts(group.ID)) == "[from a from b after a from c]"
	})
	moved(t, group.ID, "c.test", 1, yoko)
	yoko.sendREST(group.ID, "from d")
	everyoneHas(t, group.ID, "[from a from b after a from c from d]", kumiko, naoko, hiroko)

	// Kumiko leaves, then c.test's two: d.test, which came last and lacked
	// the start, orders it now.
	kumiko.must("POST", "/conversations/"+group.ID+"/leave", map[string]any{}, nil)
	naoko.must("POST", "/conversations/"+group.ID+"/leave", map[string]any{}, nil)
	hiroko.must("POST", "/conversations/"+group.ID+"/leave", map[string]any{}, nil)
	moved(t, group.ID, "d.test", 2, naoko, yoko)
	gates[2].shut.Store(true)
	yoko.sendREST(group.ID, "d alone")

	// Emi of e.test joins: everything, from d.test.
	yoko.must("GET", "/keys/users/"+emi.UserID, nil, nil)
	if err := yoko.addTo(group.ID, emi.UserID, emi.DeviceID); err != nil {
		t.Fatal(err)
	}
	all := "[from a from b after a from c from d d alone]"
	eventually(t, "emi has it, with its history", func() bool {
		return emi.inConversation(group.ID) && fmt.Sprint(emi.texts(group.ID)) == all
	})
	moved(t, group.ID, "d.test", 2, emi)

	// Kumiko comes back. Her server's copy is of c.test, which is gone: it
	// hears of the move from d.test.
	yoko.must("GET", "/keys/users/"+kumiko.UserID, nil, nil)
	if err := yoko.addTo(group.ID, kumiko.UserID, kumiko.DeviceID); err != nil {
		t.Fatal(err)
	}
	eventually(t, "kumiko is back", func() bool { return kumiko.inConversation(group.ID) })
	moved(t, group.ID, "d.test", 2, kumiko)
	kumiko.sendREST(group.ID, "back")
	all = "[from a from b after a from c from d d alone back]"
	everyoneHas(t, group.ID, all, kumiko, yoko, emi)
	for _, c := range emi.snapshot().Conversations {
		if c.Conversation.ID == group.ID && len(c.Conversation.Members) != 3 {
			t.Fatalf("members on e.test: %+v", c.Conversation.Members)
		}
	}
}

// Before its operator shuts it down, a server hands over every conversation
// that has members on other servers, also those its own users are still in,
// who go on through the new hub.
func TestHandOverAll(t *testing.T) {
	a, b, _, _ := federatedPairWith(t, []serverOption{withHandOverAll(), withQuickHandOvers()}, nil)
	sota, aiko, kumiko := register(t, a, "sota"), register(t, a, "aiko"), register(t, b, "kumiko")
	for _, d := range []*device{sota, aiko, kumiko} {
		d.setUpIdentity()
	}
	befriend(t, sota, kumiko)
	befriend(t, aiko, kumiko)
	sota.makeContact(aiko.UserID)
	sota.must("GET", "/keys/users/"+kumiko.UserID, nil, nil)
	group := sota.startGroup([]string{kumiko.UserID, aiko.UserID}, kumiko.DeviceID)
	// Ordered by a.test: "aiko@a.test" sorts first.
	aiko.must("GET", "/keys/users/"+kumiko.UserID, nil, nil)
	chat, err := aiko.startChat(kumiko.UserID, kumiko.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if hubOf(t, a, chat.ID).Host != "" {
		t.Fatal("the chat is not a.test's")
	}
	// Ordered by a.test, with nobody elsewhere: it stays.
	own := sota.createConversation("ours", aiko.UserID)

	moved(t, group.ID, "b.test", 1, sota, kumiko)
	moved(t, chat.ID, "b.test", 1, aiko, kumiko)
	sota.sendREST(group.ID, "through b")
	kumiko.sendREST(group.ID, "from b")
	aiko.sendREST(chat.ID, "hi from a")
	everyoneHas(t, group.ID, "[through b from b]", sota, aiko, kumiko)
	everyoneHas(t, chat.ID, "[hi from a]", aiko, kumiko)
	if hub := hubOf(t, a, own.ID); hub.Host != "" || hub.Term != 0 {
		t.Fatalf("its own moved: %+v", hub)
	}
}

// A conversation moves only if every server of its members can follow it.
func TestNoMoveToServersThatCannotFollow(t *testing.T) {
	bases, _ := federatedServersWith(t, []string{"a.test", "b.test", "c.test"}, func(host string) []serverOption {
		if host == "c.test" {
			return []serverOption{withoutHubMove()}
		}
		return []serverOption{withQuickHandOvers()}
	})
	sota, kumiko, naoko := register(t, bases[0], "sota"), register(t, bases[1], "kumiko"), register(t, bases[2], "naoko")
	for _, d := range []*device{sota, kumiko, naoko} {
		d.setUpIdentity()
	}
	befriend(t, sota, kumiko)
	befriend(t, sota, naoko)
	sota.must("GET", "/keys/users/"+kumiko.UserID, nil, nil)
	sota.must("GET", "/keys/users/"+naoko.UserID, nil, nil)
	group := sota.startGroup([]string{kumiko.UserID, naoko.UserID}, kumiko.DeviceID, naoko.DeviceID)
	eventually(t, "both have it", func() bool { return kumiko.inConversation(group.ID) && naoko.inConversation(group.ID) })
	sota.must("POST", "/conversations/"+group.ID+"/leave", map[string]any{}, nil)
	// a.test tries again and again; it stays where it is, and goes on.
	time.Sleep(500 * time.Millisecond)
	for _, d := range []*device{sota, kumiko, naoko} {
		if hub := hubOf(t, d.base, group.ID); hub.Term != 0 {
			t.Fatalf("moved on %s: %+v", d.base, hub)
		}
	}
	kumiko.sendREST(group.ID, "still a")
	everyoneHas(t, group.ID, "[still a]", kumiko, naoko)
}

// What a server relays to a hub that has just handed the conversation over
// is answered "conv_moved", and goes through the new hub when the app asks
// again.
func TestAskedAgainAfterAMove(t *testing.T) {
	sota, kumiko, naoko, hiroko, gates := threeServers(t)
	for _, u := range []string{kumiko.UserID, naoko.UserID} {
		sota.must("GET", "/keys/users/"+u, nil, nil)
	}
	group := sota.startGroup([]string{kumiko.UserID, naoko.UserID}, kumiko.DeviceID, naoko.DeviceID)
	eventually(t, "both have it", func() bool { return kumiko.inConversation(group.ID) && naoko.inConversation(group.ID) })
	kumiko.must("GET", "/keys/users/"+hiroko.UserID, nil, nil)
	if err := kumiko.addTo(group.ID, hiroko.UserID, hiroko.DeviceID); err != nil {
		t.Fatal(err)
	}
	delivered(t, sota.base)
	env := kumiko.textEnvelope(group.ID, "during the move")

	// b.test hears nothing for now: the move does not reach it.
	gates[1].shutSends.Store(true)
	sota.must("POST", "/conversations/"+group.ID+"/leave", map[string]any{}, nil)
	moved(t, group.ID, "c.test", 1, sota, naoko)
	if hub := hubOf(t, kumiko.base, group.ID); hub.Host != "a.test" {
		t.Fatalf("b.test heard: %+v", hub)
	}
	if err := kumiko.do("POST", "/messages", env, nil); statusOf(err) != http.StatusServiceUnavailable ||
		codeOf(err) != "conv_moved" {
		t.Fatalf("to the old hub: %v", err)
	}
	// Told so, b.test asked a.test what it missed.
	moved(t, group.ID, "c.test", 1, kumiko)
	gates[1].shutSends.Store(false)
	kumiko.must("POST", "/messages", env, nil)
	everyoneHas(t, group.ID, "[during the move]", kumiko, naoko, hiroko)
}
