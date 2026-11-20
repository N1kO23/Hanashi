package api_test

import (
	"testing"
	"time"

	"github.com/coder/websocket"
)

func (s *socket) nextPresence() map[string]any {
	s.t.Helper()
	select {
	case f := <-s.presence:
		return f
	case <-time.After(5 * time.Second):
		s.t.Fatal("timed out waiting for presence")
		return nil
	}
}

func (s *socket) expectNoPresence() {
	s.t.Helper()
	select {
	case f := <-s.presence:
		s.t.Fatalf("unexpected presence %v", f)
	case <-time.After(300 * time.Millisecond):
	}
}

// expectStatus waits for user's status; with mode, as the user's own device hears it.
func (s *socket) expectStatus(user, status string, mode ...string) {
	s.t.Helper()
	f := s.nextPresence()
	want := map[string]any{"type": "presence", "user": user, "status": status}
	if len(mode) > 0 {
		want["mode"] = mode[0]
	}
	if len(f) != len(want) {
		s.t.Fatalf("presence %v, want %v", f, want)
	}
	for k, v := range want {
		if f[k] != v {
			s.t.Fatalf("presence %v, want %v", f, want)
		}
	}
}

func statusesOf(f map[string]any) map[string]any {
	statuses, _ := f["statuses"].(map[string]any)
	return statuses
}

func TestPresence(t *testing.T) {
	base := startServer(t)
	a, b, stranger := register(t, base, "a"), register(t, base, "b"), register(t, base, "stranger")
	a.setUpIdentity()
	a.createConversation("", b.UserID)

	// On connecting, a device hears everyone it shares a conversation with
	// who is not offline (itself included), then its own status.
	onB := b.connect()
	if f := onB.nextPresence(); len(statusesOf(f)) != 1 || statusesOf(f)[b.UserID] != "online" || f["mode"] != "auto" {
		t.Fatalf("b's first presence %v", f)
	}
	onB.expectStatus(b.UserID, "online", "auto")
	onA := a.connect()
	if f := onA.nextPresence(); len(statusesOf(f)) != 2 || statusesOf(f)[b.UserID] != "online" {
		t.Fatalf("a's first presence %v", f)
	}
	onA.expectStatus(a.UserID, "online", "auto")
	onB.expectStatus(a.UserID, "online")

	// Strangers hear nothing, and nothing about them is told.
	onStranger := stranger.connect()
	if f := onStranger.nextPresence(); len(statusesOf(f)) != 1 {
		t.Fatalf("the stranger's first presence %v", f)
	}
	onA.expectNoPresence()

	// A device not in use makes a idle; only a change is told.
	onA.send(map[string]any{"type": "presence", "state": "idle"})
	onB.expectStatus(a.UserID, "idle")
	onA.expectStatus(a.UserID, "idle", "auto")
	onA.send(map[string]any{"type": "presence", "state": "idle"})
	onB.expectNoPresence()

	// A mode is for all of a's devices, and stays across connections.
	a.must("PUT", "/presence", map[string]any{"mode": "focus"}, nil)
	onB.expectStatus(a.UserID, "focus")
	// Also for a device that is not connected.
	var mode struct{ Mode string }
	a.must("GET", "/presence", nil, &mode)
	if mode.Mode != "focus" {
		t.Fatalf("mode %q", mode.Mode)
	}
	onA.expectStatus(a.UserID, "focus", "focus")
	a.must("PUT", "/presence", map[string]any{"mode": "invisible"}, nil)
	onB.expectStatus(a.UserID, "offline")
	onA.expectStatus(a.UserID, "offline", "invisible")
	laptop := login(t, base, "a", "laptop")
	onLaptop := laptop.connect()
	if f := onLaptop.nextPresence(); f["mode"] != "invisible" || statusesOf(f)[a.UserID] != nil {
		t.Fatalf("the laptop's first presence %v", f)
	}
	onB.expectNoPresence()
	a.must("PUT", "/presence", map[string]any{"mode": "auto"}, nil)
	onB.expectStatus(a.UserID, "online") // The laptop is in use.

	// Gone once no device of a's is connected.
	onA.ws.Close(websocket.StatusNormalClosure, "")
	onB.expectNoPresence()
	onLaptop.ws.Close(websocket.StatusNormalClosure, "")
	onB.expectStatus(a.UserID, "offline")

	// Asking again gets everyone's status again.
	onB.send(map[string]any{"type": "presence"})
	if f := onB.nextPresence(); len(statusesOf(f)) != 1 {
		t.Fatalf("asked again %v", f)
	}
	if err := a.do("PUT", "/presence", map[string]any{"mode": "away"}, nil); statusOf(err) != 400 {
		t.Fatalf("bad mode: %v", err)
	}
}
