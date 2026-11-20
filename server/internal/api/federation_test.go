package api_test

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/oklog/ulid/v2"

	"hanashi/server/internal/config"
	"hanashi/server/internal/protocol"
	"hanashi/server/internal/store"
)

// gate stands in front of a server, for the other one: it passes requests
// on, or while sends are shut answers transactions as a server that is down
// would; it can also lose answers, after passing the request on.
type gate struct {
	url       string
	target    atomic.Pointer[url.URL]
	shut      atomic.Bool
	shutSends atomic.Bool
	// Files passing turn into other bytes.
	tamperMedia atomic.Bool
	loseAnswers atomic.Int32
	// Transactions that came through, answered or not.
	sends atomic.Int32
}

func newGate(t *testing.T) *gate {
	g := &gate{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		proxy := httputil.NewSingleHostReverseProxy(g.target.Load())
		if g.shut.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		if g.tamperMedia.Load() && strings.HasSuffix(r.URL.Path, "/media") {
			proxy.ModifyResponse = func(resp *http.Response) error {
				data, _ := io.ReadAll(resp.Body)
				resp.Body.Close()
				for i := range data {
					data[i] ^= 0xff
				}
				resp.Body = io.NopCloser(bytes.NewReader(data))
				return nil
			}
		}
		if !strings.HasSuffix(r.URL.Path, "/send") {
			proxy.ServeHTTP(w, r)
			return
		}
		if g.shutSends.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		g.sends.Add(1)
		if g.loseAnswers.Add(-1) >= 0 {
			proxy.ServeHTTP(httptest.NewRecorder(), r)
			http.Error(w, "lost", http.StatusBadGateway)
			return
		}
		g.loseAnswers.Store(0)
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	g.url = srv.URL
	return g
}

// federatedPair starts servers of a.test and b.test that federate: what
// goes to each passes its gate. bOpts are b.test's own options.
func federatedPair(t *testing.T, bOpts ...serverOption) (a, b string, toA, toB *gate) {
	t.Helper()
	return federatedPairWith(t, nil, bOpts)
}

// federatedPairWith is federatedPair with options for each server.
func federatedPairWith(t *testing.T, aOpts, bOpts []serverOption) (a, b string, toA, toB *gate) {
	t.Helper()
	toA, toB = newGate(t), newGate(t)
	resolve := map[string]string{"a.test": toA.url, "b.test": toB.url}
	federating := func(host string) serverOption {
		return func(c *config.Config) {
			c.Host = host
			c.Federation = true
			c.FederationServers = map[string]bool{"a.test": true, "b.test": true}
			c.FederationResolve = resolve
		}
	}
	a = startServer(t, append([]serverOption{federating("a.test")}, aOpts...)...)
	b = startServer(t, append([]serverOption{federating("b.test")}, bOpts...)...)
	for g, base := range map[*gate]string{toA: a, toB: b} {
		u, _ := url.Parse(base)
		g.target.Store(u)
	}
	return a, b, toA, toB
}

// federatedServers starts a server of each of hosts, all federating with
// each other: what goes to each passes its gate. opts are every server's own.
func federatedServers(t *testing.T, hosts []string, opts ...serverOption) ([]string, []*gate) {
	t.Helper()
	gates := make([]*gate, len(hosts))
	resolve := map[string]string{}
	for i, host := range hosts {
		gates[i] = newGate(t)
		resolve[host] = gates[i].url
	}
	bases := make([]string, len(hosts))
	for i, host := range hosts {
		federating := func(c *config.Config) {
			c.Host = host
			c.Federation = true
			c.FederationServers = map[string]bool{}
			for _, h := range hosts {
				c.FederationServers[h] = true
			}
			c.FederationResolve = resolve
		}
		bases[i] = startServer(t, append([]serverOption{federating}, opts...)...)
		u, _ := url.Parse(bases[i])
		gates[i].target.Store(u)
	}
	return bases, gates
}

// eventually waits until cond holds: what one server tells another takes a
// moment.
func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("never: %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// delivered waits until nothing on base's server waits for another.
func delivered(t *testing.T, base string) {
	t.Helper()
	st, _ := stores.Load(base)
	eventually(t, "everything delivered", func() bool {
		waiting, err := st.(*store.Store).FederationDestinations(context.Background())
		return err == nil && len(waiting) == 0
	})
}

func TestContactsAcrossServers(t *testing.T) {
	a, b, _, _ := federatedPair(t)
	sota, kumiko := register(t, a, "sota"), register(t, b, "kumiko")
	if sota.UserID != "sota@a.test" || kumiko.UserID != "kumiko@b.test" {
		t.Fatalf("users %s, %s", sota.UserID, kumiko.UserID)
	}

	// Someone not there, or of a server nobody could reach, cannot be asked.
	if err := sota.do("POST", "/contacts/requests", map[string]any{"user": "nobody@b.test"}, nil); codeOf(err) != "user_not_found" {
		t.Fatalf("nobody: %v", err)
	}
	if err := sota.do("POST", "/contacts/requests", map[string]any{"user": "x@server.local"}, nil); codeOf(err) != "other_server" {
		t.Fatalf("a local network's: %v", err)
	}

	kCursor := kumiko.syncSince(0).Cursor
	if state := sota.request(kumiko.UserID); state != "outgoing" {
		t.Fatalf("request: %s", state)
	}
	eventually(t, "kumiko is asked", func() bool { return kumiko.contactState(sota.UserID) == "incoming" })
	expectEvents(t, "kumiko", kumiko.contactEvents(kCursor), sota.UserID+" incoming")

	sCursor := sota.syncSince(0).Cursor
	if err := kumiko.accept(sota.UserID); err != nil {
		t.Fatal(err)
	}
	eventually(t, "sota hears yes", func() bool { return sota.contactState(kumiko.UserID) == "accepted" })
	expectEvents(t, "sota", sota.contactEvents(sCursor), kumiko.UserID+" accepted")

	// Their keys come from her server.
	kumiko.setUpIdentity()
	var keys struct {
		UserID, IdentityKey string
		Devices             []struct{ DeviceID string }
	}
	sota.must("GET", "/keys/users/"+kumiko.UserID, nil, &keys)
	if keys.UserID != kumiko.UserID || keys.IdentityKey == "" || len(keys.Devices) != 1 || keys.Devices[0].DeviceID != kumiko.DeviceID {
		t.Fatalf("keys %+v", keys)
	}
	// Her profile only for those who share a conversation with her.
	if err := sota.do("GET", "/users/"+kumiko.UserID+"/profile", nil, nil); codeOf(err) != "not_found" {
		t.Fatalf("profile: %v", err)
	}
	if err := sota.do("GET", "/users/"+kumiko.UserID, nil, nil); err != nil {
		t.Fatalf("user: %v", err)
	}

	// A new device of hers: Sota hears her keys changed.
	sCursor = sota.syncSince(0).Cursor
	login(t, b, "kumiko", "phone").setUpDevice()
	eventually(t, "sota hears of her keys", func() bool {
		for _, e := range sota.syncSince(sCursor).Events {
			if e.Type == protocol.EventDeviceKeysChanged && strings.Contains(string(e.Data), kumiko.UserID) {
				return true
			}
		}
		return false
	})

	// Removing ends it for both.
	kumiko.must("DELETE", "/contacts/"+sota.UserID, nil, nil)
	eventually(t, "sota hears it ended", func() bool { return sota.contactState(kumiko.UserID) == "none" })
}

// To the one who asks, a request declined or blocked looks unanswered, across
// servers too: neither is told to their server.
func TestRefusalsAcrossServersAreNotRevealed(t *testing.T) {
	a, b, _, _ := federatedPair(t)
	sota, kumiko := register(t, a, "sota"), register(t, b, "kumiko")

	sota.request(kumiko.UserID)
	eventually(t, "kumiko is asked", func() bool { return kumiko.contactState(sota.UserID) == "incoming" })
	kumiko.must("POST", "/contacts/requests/"+sota.UserID+"/decline", map[string]any{}, nil)
	delivered(t, b)
	if sota.contactState(kumiko.UserID) != "outgoing" {
		t.Fatal("declining showed")
	}
	// Taking it back and asking again reaches nobody.
	sota.must("DELETE", "/contacts/requests/"+kumiko.UserID, nil, nil)
	sota.request(kumiko.UserID)
	delivered(t, a)
	if kumiko.contactState(sota.UserID) != "none" {
		t.Fatal("asking again after a no reached her")
	}

	// A contact blocked sees it end; asking again reaches nobody.
	naoko := register(t, a, "naoko")
	naoko.request(kumiko.UserID)
	eventually(t, "kumiko is asked", func() bool { return kumiko.contactState(naoko.UserID) == "incoming" })
	if err := kumiko.accept(naoko.UserID); err != nil {
		t.Fatal(err)
	}
	eventually(t, "naoko hears yes", func() bool { return naoko.contactState(kumiko.UserID) == "accepted" })
	kumiko.must("PUT", "/blocked/"+naoko.UserID, map[string]any{}, nil)
	eventually(t, "naoko sees it end", func() bool { return naoko.contactState(kumiko.UserID) == "none" })
	naoko.request(kumiko.UserID)
	delivered(t, a)
	if kumiko.contactState(naoko.UserID) != "blocked" {
		t.Fatal("asking after a block reached her")
	}
	// A request blocked is taken back, as far as the other server knows.
	yoko := register(t, b, "yoko")
	sota.request(yoko.UserID)
	eventually(t, "yoko is asked", func() bool { return yoko.contactState(sota.UserID) == "incoming" })
	sota.must("PUT", "/blocked/"+yoko.UserID, map[string]any{}, nil)
	eventually(t, "the request is gone", func() bool { return yoko.contactState(sota.UserID) == "none" })
}

func TestTwoAskingAtOnceAcrossServers(t *testing.T) {
	a, b, toA, toB := federatedPair(t)
	sota, kumiko := register(t, a, "sota"), register(t, b, "kumiko")
	// Each asks before the other's request arrives.
	toA.shutSends.Store(true)
	toB.shutSends.Store(true)
	sota.request(kumiko.UserID)
	kumiko.request(sota.UserID)
	toA.shutSends.Store(false)
	toB.shutSends.Store(false)
	eventually(t, "both are contacts", func() bool {
		return sota.contactState(kumiko.UserID) == "accepted" && kumiko.contactState(sota.UserID) == "accepted"
	})
}

func TestItemsWaitForAServerThatIsDown(t *testing.T) {
	a, b, _, toB := federatedPair(t)
	sota, kumiko := register(t, a, "sota"), register(t, b, "kumiko")
	toB.shutSends.Store(true)
	sota.request(kumiko.UserID)
	time.Sleep(300 * time.Millisecond)
	if kumiko.contactState(sota.UserID) != "none" {
		t.Fatal("arrived while her server was down")
	}
	toB.shutSends.Store(false)
	eventually(t, "kumiko is asked", func() bool { return kumiko.contactState(sota.UserID) == "incoming" })

	// An answer lost: the transaction comes again, and counts once.
	naoko := register(t, a, "naoko")
	kCursor := kumiko.syncSince(0).Cursor
	sends := toB.sends.Load()
	toB.loseAnswers.Store(1)
	naoko.request(kumiko.UserID)
	delivered(t, a)
	if toB.sends.Load()-sends < 2 {
		t.Fatal("not sent again")
	}
	expectEvents(t, "kumiko", kumiko.contactEvents(kCursor), naoko.UserID+" incoming")
}

func TestServersThatDoNotFederate(t *testing.T) {
	// As servers come: users of others are out of reach, and other servers
	// get nothing.
	base := startServer(t)
	sota := register(t, base, "sota")
	if err := sota.do("POST", "/contacts/requests", map[string]any{"user": "kumiko@b.test"}, nil); codeOf(err) != "other_server" {
		t.Fatalf("asking: %v", err)
	}
	for _, path := range []string{"/federation/v1/key", "/federation/v1/send"} {
		method := map[bool]string{true: "GET", false: "POST"}[strings.HasSuffix(path, "key")]
		req, _ := http.NewRequest(method, base+path, strings.NewReader("{}"))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s: %d", path, resp.StatusCode)
		}
	}

	// One federating, but not with the asker's.
	a, b, _, _ := federatedPair(t, func(c *config.Config) { c.FederationServers = map[string]bool{"c.test": true} })
	naoko, kumiko := register(t, a, "naoko"), register(t, b, "kumiko")
	if err := naoko.do("POST", "/contacts/requests", map[string]any{"user": kumiko.UserID}, nil); codeOf(err) != "other_server" {
		t.Fatalf("asking one not federating with us: %v", err)
	}
	// And nothing unsigned gets in.
	resp, err := http.Post(a+"/federation/v1/send", "application/json", strings.NewReader(`{"origin": "b.test"}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unsigned: %d", resp.StatusCode)
	}
}

// contactsAcross makes sota of a.test and kumiko of b.test contacts. Their
// direct chat is ordered by b.test: "kumiko@b.test" sorts first. opts are
// both servers' own.
func contactsAcross(t *testing.T, opts ...serverOption) (sota, kumiko *device, a, b string, toA, toB *gate) {
	t.Helper()
	a, b, toA, toB = federatedPairWith(t, opts, opts)
	sota, kumiko = register(t, a, "sota"), register(t, b, "kumiko")
	sota.request(kumiko.UserID)
	eventually(t, "kumiko is asked", func() bool { return kumiko.contactState(sota.UserID) == "incoming" })
	if err := kumiko.accept(sota.UserID); err != nil {
		t.Fatal(err)
	}
	eventually(t, "sota hears yes", func() bool { return sota.contactState(kumiko.UserID) == "accepted" })
	return sota, kumiko, a, b, toA, toB
}

// startChat starts d's direct chat with other, with a Welcome for device.
func (d *device) startChat(other, device string) (protocol.ConversationInfo, error) {
	var info protocol.ConversationInfo
	err := d.do("POST", "/conversations", map[string]any{
		"id": ulid.Make().String(), "members": []string{other}, "direct": true,
		"mls": map[string]any{"epoch": 1, "groupInfo": fakeMLS, "welcomes": []map[string]any{{"device": device, "data": fakeMLS}}},
	}, &info)
	return info, err
}

// texts is what d's server has of conv's history.
func (d *device) texts(conv string) []string {
	d.t.Helper()
	var history protocol.HistoryPage
	d.must("GET", "/conversations/"+conv+"/messages", nil, &history)
	out := []string{}
	for _, m := range history.Messages {
		out = append(out, envelopeText(m))
	}
	return out
}

func TestDirectChatAcrossServers(t *testing.T) {
	sota, kumiko, _, _, _, _ := contactsAcross(t)

	// Started on the server that does not order it: made at the other.
	chat, err := sota.startChat(kumiko.UserID, kumiko.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if !chat.IsDirect || len(chat.Members) != 2 {
		t.Fatalf("chat %+v", chat)
	}
	if inbox := kumiko.inbox(); len(inbox) != 1 || inbox[0].Data.Conv != chat.ID {
		t.Fatalf("her Welcome %+v", inbox)
	}
	if got := kumiko.snapshot().Conversations; len(got) != 1 || got[0].Conversation.ID != chat.ID {
		t.Fatalf("her chats %+v", got)
	}
	// Both asking for it get the one there is.
	if again, err := kumiko.startChat(sota.UserID, sota.DeviceID); err != nil || again.ID != chat.ID {
		t.Fatalf("hers: %+v, %v", again, err)
	}

	// Messages both ways, in the same order on both servers, each answered
	// with its server's own seq.
	first := sota.sendREST(chat.ID, "Hello from a")
	second := kumiko.sendREST(chat.ID, "Hello from b")
	third := sota.sendREST(chat.ID, "Again from a")
	if first <= 0 || third <= first {
		t.Fatalf("seqs %d, %d", first, third)
	}
	want := []string{"Hello from a", "Hello from b", "Again from a"}
	eventually(t, "both have everything", func() bool {
		return fmt.Sprint(sota.texts(chat.ID)) == fmt.Sprint(want) && fmt.Sprint(kumiko.texts(chat.ID)) == fmt.Sprint(want)
	})
	var events []string
	for _, e := range sota.syncSince(0).Events {
		if e.Conv == chat.ID {
			events = append(events, e.Type)
		}
	}
	if fmt.Sprint(events) != "[conversation_created message message message]" || second <= 0 {
		t.Fatalf("sota's events %v", events)
	}
	// Sent again (its answer lost): the one message.
	env := sota.textEnvelope(chat.ID, "Once")
	var one, two struct{ Seq int64 }
	sota.must("POST", "/messages", env, &one)
	sota.must("POST", "/messages", env, &two)
	if one.Seq != two.Seq {
		t.Fatalf("resent: %d, %d", one.Seq, two.Seq)
	}

	// Group changes go to the hub; its refusals come back as they are.
	leaseID, epoch := sota.lease(chat.ID)
	if err := kumiko.do("POST", "/conversations/"+chat.ID+"/lease", map[string]any{}, nil); codeOf(err) != "lease_held" {
		t.Fatalf("her lease: %v", err)
	}
	var committed struct{ Seq int64 }
	sota.must("POST", "/conversations/"+chat.ID+"/commits", commitBody(leaseID, epoch), &committed)
	if committed.Seq <= third {
		t.Fatalf("commit seq %d", committed.Seq)
	}
	stale := commitBody(leaseID, epoch)
	if err := sota.do("POST", "/conversations/"+chat.ID+"/commits", stale, nil); codeOf(err) != "lease_invalid" {
		t.Fatalf("again: %v", err)
	}
	var info struct{ Epoch int64 }
	sota.must("GET", "/conversations/"+chat.ID+"/group-info", nil, &info)
	if info.Epoch != epoch+1 {
		t.Fatalf("group info at %d", info.Epoch)
	}
	state := map[string]any{"epoch": epoch + 1, "data": b64([]byte("sealed"))}
	sota.must("PUT", "/conversations/"+chat.ID+"/state", state, nil)
	if err := kumiko.do("PUT", "/conversations/"+chat.ID+"/state", state, nil); codeOf(err) != "state_exists" {
		t.Fatalf("sealed twice: %v", err)
	}
	if err := sota.do("POST", "/messages", envelope(chat.ID, sota.UserID, sota.DeviceID, "old"), nil); codeOf(err) != "epoch_mismatch" {
		t.Fatalf("an old epoch: %v", err)
	}

	// Deleted for everyone: gone from both servers.
	var deleted struct{ Deleted int }
	sota.must("POST", "/messages/delete", map[string]any{"ids": []string{env["id"].(string)}}, &deleted)
	if deleted.Deleted != 1 {
		t.Fatalf("deleted %d", deleted.Deleted)
	}
	eventually(t, "gone from hers", func() bool { return !slices.Contains(kumiko.texts(chat.ID), "Once") })

	// The chat goes quiet when they are no longer contacts.
	kumiko.must("DELETE", "/contacts/"+sota.UserID, nil, nil)
	eventually(t, "sota hears it ended", func() bool { return sota.contactState(kumiko.UserID) == "none" })
	if err := sota.do("POST", "/messages", sota.textEnvelope(chat.ID, "Still?"), nil); codeOf(err) != "not_a_contact" {
		t.Fatalf("to a former contact: %v", err)
	}
}

func TestDirectChatStartedOnItsHub(t *testing.T) {
	sota, kumiko, _, b, _, _ := contactsAcross(t)
	// Her app looks his devices up first, as apps do before claiming.
	sota.setUpIdentity()
	sota.must("POST", "/keys/packages", map[string]any{"packages": []string{kp("his")}}, nil)
	kumiko.must("GET", "/keys/users/"+sota.UserID, nil, nil)
	var claimed struct{ Packages map[string]string }
	kumiko.must("POST", "/keys/packages/claim", map[string]any{"devices": []string{sota.DeviceID}}, &claimed)
	if claimed.Packages[sota.DeviceID] != kp("his") {
		t.Fatalf("claimed %+v", claimed)
	}
	// Someone not his contact claims nothing.
	yoko := register(t, b, "yoko")
	yoko.must("GET", "/keys/users/"+sota.UserID, nil, nil)
	if err := yoko.do("POST", "/keys/packages/claim", map[string]any{"devices": []string{sota.DeviceID}}, nil); codeOf(err) != "not_a_contact" {
		t.Fatalf("a stranger claiming: %v", err)
	}

	chat, err := kumiko.startChat(sota.UserID, sota.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	// His Welcome comes before the chat does.
	eventually(t, "sota has the chat", func() bool {
		for _, c := range sota.snapshot().Conversations {
			if c.Conversation.ID == chat.ID {
				return true
			}
		}
		return false
	})
	if inbox := sota.inbox(); len(inbox) != 1 || inbox[0].Data.Conv != chat.ID || inbox[0].Type != protocol.InboxWelcome {
		t.Fatalf("his Welcome %+v", inbox)
	}
	sota.sendREST(chat.ID, "Got it")
	eventually(t, "she has it", func() bool { return slices.Contains(kumiko.texts(chat.ID), "Got it") })
	// Sharing a conversation, each may read the other's profile.
	kumiko.must("PUT", "/profile", map[string]any{"version": 1, "ct": b64([]byte("ct")), "signature": b64(make([]byte, 64))}, nil)
	if err := sota.do("GET", "/users/"+kumiko.UserID+"/profile", nil, nil); err != nil {
		t.Fatalf("her profile: %v", err)
	}
}

func TestChatsAcrossServersWhenTheHubIsDown(t *testing.T) {
	sota, kumiko, _, b, toA, toB := contactsAcross(t)
	chat, err := sota.startChat(kumiko.UserID, kumiko.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	// Its hub down: no clear answer, and the same message goes once later.
	toB.shut.Store(true)
	env := sota.textEnvelope(chat.ID, "Are you there?")
	if err := sota.do("POST", "/messages", env, nil); statusOf(err) != http.StatusBadGateway {
		t.Fatalf("hub down: %v", err)
	}
	toB.shut.Store(false)
	sota.must("POST", "/messages", env, nil)

	// What it lost on its way is caught up from the hub.
	toA.shutSends.Store(true)
	kumiko.sendREST(chat.ID, "one")
	kumiko.sendREST(chat.ID, "two")
	st, _ := stores.Load(b)
	if err := st.(*store.Store).DropFederationItems(context.Background(), "a.test", 1<<62); err != nil {
		t.Fatal(err)
	}
	toA.shutSends.Store(false)
	kumiko.sendREST(chat.ID, "three")
	want := []string{"Are you there?", "one", "two", "three"}
	eventually(t, "sota catches up", func() bool { return fmt.Sprint(sota.texts(chat.ID)) == fmt.Sprint(want) })
}

// A server cannot draw someone of another into a chat with a stranger.
func TestNoChatAcrossServersWithAStranger(t *testing.T) {
	a, b, _, _ := federatedPair(t)
	naoko, kumiko := register(t, a, "naoko"), register(t, b, "kumiko")
	// Her server says they are contacts; his does not.
	naoko.setUpIdentity()
	kumiko.must("GET", "/keys/users/"+naoko.UserID, nil, nil)
	kumiko.setContactStates([3]string{kumiko.UserID, naoko.UserID, store.ContactAccepted},
		[3]string{naoko.UserID, kumiko.UserID, store.ContactAccepted})
	if _, err := kumiko.startChat(naoko.UserID, naoko.DeviceID); err != nil {
		t.Fatal(err)
	}
	delivered(t, b)
	if got := naoko.snapshot().Conversations; len(got) != 0 {
		t.Fatalf("drawn into %+v", got)
	}
	if got := naoko.inbox(); len(got) != 0 {
		t.Fatalf("a Welcome %+v", got)
	}
}

// getMedia downloads a file as apps do, naming the host that has it.
func (d *device) getMedia(hash, host string) (int, []byte) {
	d.t.Helper()
	req, _ := http.NewRequest("GET", d.base+"/media/"+hash+"?host="+url.QueryEscape(host), nil)
	req.Header.Set("Authorization", "Bearer "+d.Token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		d.t.Fatal(err)
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(res.Body)
	return res.StatusCode, data
}

func TestFilesAcrossServers(t *testing.T) {
	sota, kumiko, _, b, toA, _ := contactsAcross(t)
	_, up := sota.upload([]byte("a photo, encrypted"), "image/jpeg")
	photo := up["hash"].(string)

	// Not on her server: fetched from his, and kept.
	if status, data := kumiko.getMedia(photo, "a.test"); status != http.StatusOK || string(data) != "a photo, encrypted" {
		t.Fatalf("fetched: %d %q", status, data)
	}
	toA.shut.Store(true)
	if status, data := kumiko.getMedia(photo, "a.test"); status != http.StatusOK || string(data) != "a photo, encrypted" {
		t.Fatalf("kept: %d %q", status, data)
	}
	toA.shut.Store(false)

	// Nowhere, or said to be on a server not federated with: not found.
	_, up = sota.upload([]byte("another photo"), "image/jpeg")
	another := up["hash"].(string)
	if status, _ := kumiko.getMedia("sha256:"+strings.Repeat("0", 64), "a.test"); status != http.StatusNotFound {
		t.Fatalf("nowhere: %d", status)
	}
	if status, _ := kumiko.getMedia(another, "server.local"); status != http.StatusNotFound {
		t.Fatalf("a local network's: %d", status)
	}

	// Bytes that are not the file go on to the app, which checks them, but
	// are not kept.
	toA.tamperMedia.Store(true)
	if status, data := kumiko.getMedia(another, "a.test"); status != http.StatusOK || string(data) == "another photo" {
		t.Fatalf("altered: %d %q", status, data)
	}
	toA.tamperMedia.Store(false)
	st, _ := stores.Load(b)
	if _, err := st.(*store.Store).Media(context.Background(), another); err == nil {
		t.Fatal("kept bytes that were not the file")
	}
	if status, data := kumiko.getMedia(another, "a.test"); status != http.StatusOK || string(data) != "another photo" {
		t.Fatalf("again: %d %q", status, data)
	}
}

func TestVerificationMessagesAcrossServers(t *testing.T) {
	sota, kumiko, a, _, _, _ := contactsAcross(t)
	if _, err := sota.startChat(kumiko.UserID, kumiko.DeviceID); err != nil {
		t.Fatal(err)
	}
	send := func(d *device, to map[string]any) error {
		var res struct{ Delivered int }
		err := d.do("POST", "/inbox/send", map[string]any{"to": []map[string]any{to}, "type": "verification.request",
			"data": map[string]any{"txn": "1"}}, &res)
		if err == nil && res.Delivered != 1 {
			t.Fatalf("delivered %d", res.Delivered)
		}
		return err
	}
	if err := send(sota, map[string]any{"user": kumiko.UserID}); err != nil {
		t.Fatal(err)
	}
	if err := send(sota, map[string]any{"user": kumiko.UserID, "device": kumiko.DeviceID}); err != nil {
		t.Fatal(err)
	}
	eventually(t, "her device has both", func() bool {
		n := 0
		for _, item := range kumiko.inbox() {
			if item.Type == "verification.request" && item.FromUser == sota.UserID && item.FromDevice == sota.DeviceID {
				n++
			}
		}
		return n == 2
	})
	// Someone she shares no chat with cannot.
	naoko := register(t, a, "naoko")
	if err := send(naoko, map[string]any{"user": kumiko.UserID}); codeOf(err) != "not_a_contact" {
		t.Fatalf("a stranger: %v", err)
	}
}

// waitPresence waits for s to hear that user's status is status.
func waitPresence(t *testing.T, s *socket, user, status string) {
	t.Helper()
	deadline := time.After(10 * time.Second)
	for {
		select {
		case f := <-s.presence:
			if statuses, ok := f["statuses"].(map[string]any); ok {
				got, _ := statuses[user].(string)
				if got == status || (got == "" && status == "offline") {
					return
				}
			} else if f["user"] == user && f["status"] == status {
				return
			}
		case <-deadline:
			t.Fatalf("never heard %s is %s", user, status)
		}
	}
}

func TestTypingAndPresenceAcrossServers(t *testing.T) {
	fast := func(c *config.Config) { c.PresenceInterval = 200 * time.Millisecond }
	sota, kumiko, _, _, toA, _ := contactsAcross(t, fast)
	chat, err := sota.startChat(kumiko.UserID, kumiko.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	his := sota.connect()
	hers := kumiko.connect()
	waitPresence(t, his, kumiko.UserID, "online")

	hers.send(map[string]any{"type": "typing", "conv": chat.ID})
	if f := his.nextOfType("typing"); f["user"] != kumiko.UserID || f["conv"] != chat.ID {
		t.Fatalf("typing %v", f)
	}

	// Her server no longer heard: before long she is offline to him, and
	// back once it is heard again.
	toA.shut.Store(true)
	waitPresence(t, his, kumiko.UserID, "offline")
	toA.shut.Store(false)
	waitPresence(t, his, kumiko.UserID, "online")

	// She goes: offline at once.
	hers.ws.CloseNow()
	waitPresence(t, his, kumiko.UserID, "offline")
}

// befriend makes x and y contacts, x asking, as apps do across servers.
func befriend(t *testing.T, x, y *device) {
	t.Helper()
	x.request(y.UserID)
	eventually(t, y.UserID+" is asked", func() bool { return y.contactState(x.UserID) == "incoming" })
	if err := y.accept(x.UserID); err != nil {
		t.Fatal(err)
	}
	eventually(t, x.UserID+" hears yes", func() bool { return x.contactState(y.UserID) == "accepted" })
}

// startGroup makes d's group with members, and Welcomes for devices.
func (d *device) startGroup(members []string, devices ...string) protocol.ConversationInfo {
	d.t.Helper()
	welcomes := []map[string]any{}
	for _, device := range devices {
		welcomes = append(welcomes, map[string]any{"device": device, "data": fakeMLS})
	}
	var info protocol.ConversationInfo
	d.must("POST", "/conversations", map[string]any{"id": ulid.Make().String(), "members": members,
		"mls": map[string]any{"epoch": 1, "groupInfo": fakeMLS, "welcomes": welcomes}}, &info)
	return info
}

// addTo adds user, whose device gets a Welcome, to conv, as d.
func (d *device) addTo(conv, user, device string) error {
	leaseID, epoch := d.lease(conv)
	return d.do("POST", "/conversations/"+conv+"/members", map[string]any{"user": user,
		"commit": commitBody(leaseID, epoch, map[string]any{"device": device, "data": fakeMLS})}, nil)
}

// inConversation reports whether d's server has d in conv.
func (d *device) inConversation(conv string) bool {
	d.t.Helper()
	for _, c := range d.snapshot().Conversations {
		if c.Conversation.ID == conv {
			return true
		}
	}
	return false
}

func TestGroupsAcrossServers(t *testing.T) {
	a, b, _, _ := federatedPair(t)
	sota, naoko := register(t, a, "sota"), register(t, a, "naoko")
	kumiko, yoko := register(t, b, "kumiko"), register(t, b, "yoko")
	befriend(t, sota, kumiko)
	sota.makeContact(naoko.UserID)
	kumiko.makeContact(yoko.UserID)
	kumiko.setUpIdentity()
	sota.must("GET", "/keys/users/"+kumiko.UserID, nil, nil)

	// His group, with people of both servers: his server orders it, hers
	// has a copy.
	group := sota.startGroup([]string{kumiko.UserID, naoko.UserID}, kumiko.DeviceID)
	eventually(t, "kumiko has it", func() bool { return kumiko.inConversation(group.ID) })
	if inbox := kumiko.inbox(); len(inbox) != 1 || inbox[0].Data.Conv != group.ID {
		t.Fatalf("her Welcome %+v", inbox)
	}
	sota.sendREST(group.ID, "one")
	kumiko.sendREST(group.ID, "two")
	naoko.sendREST(group.ID, "three")
	want := "[one two three]"
	eventually(t, "the same everywhere", func() bool {
		return fmt.Sprint(sota.texts(group.ID)) == want && fmt.Sprint(kumiko.texts(group.ID)) == want
	})

	// Someone of her server, added by her, through his server.
	yoko.setUpIdentity()
	if err := kumiko.addTo(group.ID, yoko.UserID, yoko.DeviceID); err != nil {
		t.Fatal(err)
	}
	if !yoko.inConversation(group.ID) {
		t.Fatal("yoko is not in it")
	}
	if inbox := yoko.inbox(); len(inbox) != 1 || inbox[0].Data.Conv != group.ID {
		t.Fatalf("yoko's Welcome %+v", inbox)
	}
	eventually(t, "his server has her in it", func() bool {
		for _, c := range sota.snapshot().Conversations {
			if c.Conversation.ID == group.ID {
				return len(c.Conversation.Members) == 4
			}
		}
		return false
	})

	// Left from her server: out on both, and the others go on.
	kumiko.must("POST", "/conversations/"+group.ID+"/leave", map[string]any{}, nil)
	if kumiko.inConversation(group.ID) {
		t.Fatal("still in it")
	}
	eventually(t, "his server has her out", func() bool {
		for _, c := range sota.snapshot().Conversations {
			if c.Conversation.ID == group.ID {
				return len(c.Conversation.Members) == 3
			}
		}
		return false
	})
	sota.sendREST(group.ID, "four")
	eventually(t, "yoko has it", func() bool { return slices.Contains(yoko.texts(group.ID), "four") })
}

// A server joining a group has what was said before as history, which never
// comes to its users as new.
func TestServerJoiningAGroupGetsItsHistory(t *testing.T) {
	a, b, _, _ := federatedPair(t)
	sota, naoko := register(t, a, "sota"), register(t, a, "naoko")
	kumiko := register(t, b, "kumiko")
	befriend(t, sota, kumiko)
	sota.makeContact(naoko.UserID)
	group := sota.startGroup([]string{naoko.UserID})
	sota.sendREST(group.ID, "before her")
	naoko.sendREST(group.ID, "also before")

	kumiko.setUpIdentity()
	sota.must("GET", "/keys/users/"+kumiko.UserID, nil, nil)
	cursor := kumiko.syncSince(0).Cursor
	if err := sota.addTo(group.ID, kumiko.UserID, kumiko.DeviceID); err != nil {
		t.Fatal(err)
	}
	eventually(t, "kumiko has it, with its history", func() bool {
		return kumiko.inConversation(group.ID) && fmt.Sprint(kumiko.texts(group.ID)) == "[before her also before]"
	})
	var types []string
	for _, e := range kumiko.syncSince(cursor).Events {
		if e.Conv == group.ID {
			types = append(types, e.Type)
		}
	}
	if fmt.Sprint(types) != "[member_added mls_commit]" {
		t.Fatalf("new to her: %v", types)
	}
	if inbox := kumiko.inbox(); len(inbox) != 1 {
		t.Fatalf("her Welcome %+v", inbox)
	}
	sota.sendREST(group.ID, "after")
	eventually(t, "she has what comes after", func() bool { return slices.Contains(kumiko.texts(group.ID), "after") })
}

// A server never takes one of its users into a group of someone who is not
// their contact, whatever the hub says.
func TestNoGroupAcrossServersWithAStranger(t *testing.T) {
	a, b, _, _ := federatedPair(t)
	sota, naoko := register(t, a, "sota"), register(t, a, "naoko")
	yoko := register(t, b, "yoko")
	sota.makeContact(naoko.UserID)
	group := sota.startGroup([]string{naoko.UserID})
	sota.sendREST(group.ID, "for the club")

	// His server says they are contacts; hers does not.
	yoko.setUpIdentity()
	sota.must("GET", "/keys/users/"+yoko.UserID, nil, nil)
	sota.setContactStates([3]string{sota.UserID, yoko.UserID, store.ContactAccepted},
		[3]string{yoko.UserID, sota.UserID, store.ContactAccepted})
	if err := sota.addTo(group.ID, yoko.UserID, yoko.DeviceID); err != nil {
		t.Fatal(err)
	}
	st, _ := stores.Load(b)
	eventually(t, "her server has its copy", func() bool {
		_, at, err := st.(*store.Store).ConversationHub(context.Background(), group.ID)
		return err == nil && at > 0
	})
	delivered(t, a)
	if yoko.inConversation(group.ID) {
		t.Fatal("taken into a stranger's group")
	}
	if inbox := yoko.inbox(); len(inbox) != 0 {
		t.Fatalf("a Welcome from a stranger %+v", inbox)
	}
}

// threeServers starts servers of a.test, b.test and c.test, with Sota on
// a.test, Kumiko on b.test, and Naoko and Hiroko on c.test. Sota is a contact
// of Kumiko and of Naoko, Kumiko of Hiroko; all have device keys.
func threeServers(t *testing.T) (sota, kumiko, naoko, hiroko *device, gates []*gate) {
	t.Helper()
	bases, gates := federatedServers(t, []string{"a.test", "b.test", "c.test"})
	sota, kumiko = register(t, bases[0], "sota"), register(t, bases[1], "kumiko")
	naoko, hiroko = register(t, bases[2], "naoko"), register(t, bases[2], "hiroko")
	for _, d := range []*device{sota, kumiko, naoko, hiroko} {
		d.setUpIdentity()
	}
	befriend(t, sota, kumiko)
	befriend(t, sota, naoko)
	befriend(t, kumiko, hiroko)
	return sota, kumiko, naoko, hiroko, gates
}

func TestGroupAcrossThreeServers(t *testing.T) {
	sota, kumiko, naoko, hiroko, _ := threeServers(t)
	sota.must("GET", "/keys/users/"+kumiko.UserID, nil, nil)
	// His group, with Kumiko: his server orders it, hers has a copy.
	group := sota.startGroup([]string{kumiko.UserID}, kumiko.DeviceID)
	eventually(t, "kumiko has it", func() bool { return kumiko.inConversation(group.ID) })
	sota.sendREST(group.ID, "from a")
	kumiko.sendREST(group.ID, "from b")

	// Kumiko, of b.test, adds Hiroko, of c.test, which has nothing of the group:
	// through a.test, which orders it. c.test checks that the two are
	// contacts, and has the group from its start, as history.
	kumiko.must("GET", "/keys/users/"+hiroko.UserID, nil, nil)
	if err := kumiko.addTo(group.ID, hiroko.UserID, hiroko.DeviceID); err != nil {
		t.Fatal(err)
	}
	eventually(t, "hiroko has it, with its history", func() bool {
		return hiroko.inConversation(group.ID) && fmt.Sprint(hiroko.texts(group.ID)) == "[from a from b]"
	})
	if inbox := hiroko.inbox(); len(inbox) != 1 || inbox[0].FromUser != kumiko.UserID || inbox[0].Data.Conv != group.ID {
		t.Fatalf("hiroko's Welcome %+v", inbox)
	}

	// Sota adds Naoko, of c.test too, which has its copy now.
	sota.must("GET", "/keys/users/"+naoko.UserID, nil, nil)
	if err := sota.addTo(group.ID, naoko.UserID, naoko.DeviceID); err != nil {
		t.Fatal(err)
	}
	eventually(t, "naoko has it", func() bool { return naoko.inConversation(group.ID) })
	naoko.sendREST(group.ID, "from c")
	want := "[from a from b from c]"
	for _, d := range []*device{sota, kumiko, naoko, hiroko} {
		eventually(t, d.UserID+" has all of it", func() bool { return fmt.Sprint(d.texts(group.ID)) == want })
	}

	// Typing on c.test reaches a.test and b.test.
	his, hers := sota.connect(), kumiko.connect()
	hiroko.connect().send(map[string]any{"type": "typing", "conv": group.ID})
	for _, s := range []*socket{his, hers} {
		if f := s.nextOfType("typing"); f["user"] != hiroko.UserID {
			t.Fatalf("typing %v", f)
		}
	}

	// Deleted on b.test: gone from a.test and c.test.
	env := kumiko.textEnvelope(group.ID, "oops")
	kumiko.must("POST", "/messages", env, nil)
	eventually(t, "it reached c.test", func() bool { return slices.Contains(hiroko.texts(group.ID), "oops") })
	kumiko.must("POST", "/messages/delete", map[string]any{"ids": []string{env["id"].(string)}}, nil)
	for _, d := range []*device{sota, hiroko} {
		eventually(t, "gone from "+d.UserID+"'s server", func() bool { return !slices.Contains(d.texts(group.ID), "oops") })
	}

	// Naoko leaves, from c.test, where Hiroko stays in it.
	naoko.must("POST", "/conversations/"+group.ID+"/leave", map[string]any{}, nil)
	if naoko.inConversation(group.ID) {
		t.Fatal("naoko still in it")
	}
	kumiko.sendREST(group.ID, "after naoko")
	eventually(t, "hiroko has it", func() bool { return slices.Contains(hiroko.texts(group.ID), "after naoko") })
	for _, c := range sota.snapshot().Conversations {
		if c.Conversation.ID == group.ID && len(c.Conversation.Members) != 3 {
			t.Fatalf("members %+v", c.Conversation.Members)
		}
	}
}

func TestFilesAndVerificationAcrossThreeServers(t *testing.T) {
	sota, kumiko, naoko, _, _ := threeServers(t)
	for _, u := range []string{kumiko.UserID, naoko.UserID} {
		sota.must("GET", "/keys/users/"+u, nil, nil)
	}
	group := sota.startGroup([]string{kumiko.UserID, naoko.UserID}, kumiko.DeviceID, naoko.DeviceID)
	eventually(t, "both have it", func() bool { return kumiko.inConversation(group.ID) && naoko.inConversation(group.ID) })

	// A file uploaded on c.test, opened on a.test and b.test, each fetching it
	// from c.test.
	_, up := naoko.upload([]byte("a photo from c"), "image/jpeg")
	for _, d := range []*device{sota, kumiko} {
		if status, data := d.getMedia(up["hash"].(string), "c.test"); status != http.StatusOK || string(data) != "a photo from c" {
			t.Fatalf("%s: %d %q", d.UserID, status, data)
		}
	}

	// Kumiko and Naoko are no contacts, but share the group: they can verify
	// each other, b.test to c.test.
	var res struct{ Delivered int }
	kumiko.must("POST", "/inbox/send", map[string]any{"to": []map[string]any{{"user": naoko.UserID}},
		"type": "verification.request", "data": map[string]any{"txn": "1"}}, &res)
	eventually(t, "naoko's device has it", func() bool {
		for _, item := range naoko.inbox() {
			if item.Type == "verification.request" && item.FromUser == kumiko.UserID {
				return true
			}
		}
		return false
	})
	// Her keys change: Naoko's server hears, though they are no contacts.
	cursor := naoko.syncSince(0).Cursor
	login(t, kumiko.base, "kumiko", "phone").setUpDevice()
	eventually(t, "naoko hears of her keys", func() bool {
		for _, e := range naoko.syncSince(cursor).Events {
			if e.Type == protocol.EventDeviceKeysChanged && strings.Contains(string(e.Data), kumiko.UserID) {
				return true
			}
		}
		return false
	})
}

// A server down stops only what it orders: the group on a.test, not the
// direct chat of b.test and c.test.
func TestAThirdServerDownLeavesTheOthersBe(t *testing.T) {
	sota, kumiko, naoko, _, gates := threeServers(t)
	for _, u := range []string{kumiko.UserID, naoko.UserID} {
		sota.must("GET", "/keys/users/"+u, nil, nil)
	}
	group := sota.startGroup([]string{kumiko.UserID, naoko.UserID}, kumiko.DeviceID, naoko.DeviceID)
	eventually(t, "both have it", func() bool { return kumiko.inConversation(group.ID) && naoko.inConversation(group.ID) })
	befriend(t, kumiko, naoko)
	naoko.must("GET", "/keys/users/"+kumiko.UserID, nil, nil)
	// Ordered by b.test: "kumiko@b.test" sorts first.
	chat, err := naoko.startChat(kumiko.UserID, kumiko.DeviceID)
	if err != nil {
		t.Fatal(err)
	}

	gates[0].shut.Store(true)
	env := kumiko.textEnvelope(group.ID, "anyone?")
	if err := kumiko.do("POST", "/messages", env, nil); statusOf(err) != http.StatusBadGateway {
		t.Fatalf("to the group with its hub down: %v", err)
	}
	naoko.sendREST(chat.ID, "we are still here")
	eventually(t, "kumiko has it", func() bool { return slices.Contains(kumiko.texts(chat.ID), "we are still here") })

	gates[0].shut.Store(false)
	kumiko.must("POST", "/messages", env, nil)
	for _, d := range []*device{sota, naoko} {
		eventually(t, d.UserID+" has it", func() bool { return slices.Contains(d.texts(group.ID), "anyone?") })
	}
}

// Each other server may ask only so much at once. Its apps hear to try again
// later; what it tells waits as long as it is told, and arrives.
func TestOtherServersAreLimited(t *testing.T) {
	slow := func(c *config.Config) { c.FederationRate, c.FederationBurst = 0.2, 2 }
	a, b, _, toB := federatedPairWith(t, nil, []serverOption{slow})
	sota, kumiko := register(t, a, "sota"), register(t, b, "kumiko")
	// Asking takes two requests at her server: whether she is there, and the
	// request itself.
	sota.request(kumiko.UserID)
	eventually(t, "kumiko is asked", func() bool { return kumiko.contactState(sota.UserID) == "incoming" })
	if err := sota.do("GET", "/keys/users/"+kumiko.UserID, nil, nil); statusOf(err) != http.StatusTooManyRequests ||
		codeOf(err) != "too_many_requests" {
		t.Fatalf("a third at once: %v", err)
	}
	sends := toB.sends.Load()
	sota.must("DELETE", "/contacts/requests/"+kumiko.UserID, nil, nil)
	eventually(t, "the request is taken back", func() bool { return kumiko.contactState(sota.UserID) == "none" })
	if toB.sends.Load()-sends < 2 {
		t.Fatal("it was not over the limit")
	}
}
