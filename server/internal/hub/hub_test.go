package hub

import (
	"testing"
	"time"

	"hanashi/server/internal/protocol"
)

func TestRemoteStatuses(t *testing.T) {
	h := New()
	now := time.Now()
	h.SetRemoteStatus("kumiko@b.test", protocol.StatusOnline, now.Add(time.Minute))
	h.SetRemoteStatus("naoko@b.test", protocol.StatusFocus, now.Add(time.Hour))
	if s := h.status("kumiko@b.test"); s != protocol.StatusOnline {
		t.Fatalf("kumiko %s", s)
	}
	// Not said again in time: offline.
	if expired := h.ExpireRemote(now.Add(2 * time.Minute)); len(expired) != 1 || expired[0] != "kumiko@b.test" {
		t.Fatalf("expired %v", expired)
	}
	if s := h.status("kumiko@b.test"); s != protocol.StatusOffline {
		t.Fatalf("kumiko after %s", s)
	}
	h.SetRemoteStatus("naoko@b.test", protocol.StatusOffline, now.Add(time.Hour))
	if s := h.status("naoko@b.test"); s != protocol.StatusOffline {
		t.Fatalf("naoko %s", s)
	}
	if present := h.Present(); len(present) != 0 {
		t.Fatalf("users of this server present: %v", present)
	}
}
