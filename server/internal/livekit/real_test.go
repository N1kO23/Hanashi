package livekit

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// liveKitImage is the LiveKit server the opt-in test runs against.
const liveKitImage = "livekit/livekit-server:v1.13.11"

type hook struct {
	auth string
	body []byte
}

// TestAgainstRealLiveKit checks tokens, the room API and webhooks with a real
// LiveKit server in Docker (host network): HANASHI_TEST_LIVEKIT=1 runs it.
func TestAgainstRealLiveKit(t *testing.T) {
	if os.Getenv("HANASHI_TEST_LIVEKIT") == "" {
		t.Skip("HANASHI_TEST_LIVEKIT=1 runs this against LiveKit in Docker")
	}
	hooks := make(chan hook, 16)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		hooks <- hook{r.Header.Get("Authorization"), body}
	})}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })

	config := filepath.Join(t.TempDir(), "livekit.yaml")
	if err := os.WriteFile(config, fmt.Appendf(nil, `port: 17880
bind_addresses: ["127.0.0.1"]
rtc:
  tcp_port: 17881
  udp_port: 17882
  use_external_ip: false
keys:
  %s: %s
webhook:
  api_key: %s
  urls: ["http://%s/hook"]
`, keys.APIKey, keys.Secret, keys.APIKey, listener.Addr()), 0o644); err != nil {
		t.Fatal(err)
	}
	exec.Command("docker", "rm", "-f", "hanashi-test-livekit").Run()
	run := exec.Command("docker", "run", "--rm", "-d", "--name", "hanashi-test-livekit", "--network", "host",
		"-v", config+":/livekit.yaml:ro", liveKitImage, "--config", "/livekit.yaml")
	if out, err := run.CombinedOutput(); err != nil {
		t.Fatalf("starting LiveKit: %v\n%s", err, out)
	}
	t.Cleanup(func() { exec.Command("docker", "rm", "-f", "hanashi-test-livekit").Run() })
	base := "http://127.0.0.1:17880"
	deadline := time.Now().Add(30 * time.Second)
	for {
		if res, err := http.Get(base); err == nil {
			res.Body.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("LiveKit did not start")
		}
		time.Sleep(200 * time.Millisecond)
	}

	// LiveKit takes our join token, and no other.
	validate := func(token string) int {
		res, err := http.Get(base + "/rtc/validate?access_token=" + token)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}
	token, _ := keys.Token("kumiko@test.local/01HZXQ8Z7K3V5M2N4P6R8T0W9Y", JoinGrant("01CALL"), time.Now(), time.Minute)
	if status := validate(token); status != http.StatusOK {
		t.Errorf("our token: %d", status)
	}
	forged, _ := Keys{APIKey: keys.APIKey, Secret: "not the secret LiveKit has, but as long"}.Token("x@y/z", JoinGrant("01CALL"), time.Now(), time.Minute)
	if status := validate(forged); status == http.StatusOK {
		t.Errorf("forged token taken")
	}

	// The room API, and what LiveKit says of it by webhook, signed.
	ctx := context.Background()
	client := &Client{URL: base, Keys: keys, HTTP: http.DefaultClient}
	nextHook := func(want string) Event {
		t.Helper()
		for {
			select {
			case h := <-hooks:
				if err := keys.Verify(h.auth, h.body, time.Now()); err != nil {
					t.Fatalf("LiveKit's webhook: %v (%q)", err, h.auth)
				}
				event, err := ParseEvent(h.body)
				if err != nil {
					t.Fatal(err)
				}
				if event.Event == want {
					return event
				}
			case <-time.After(15 * time.Second):
				t.Fatalf("no %s webhook", want)
			}
		}
	}
	if participants, err := client.ListParticipants(ctx, "nowhere"); err != nil || len(participants) != 0 {
		t.Fatalf("list of no room: %v, %v", participants, err)
	}
	if err := client.call(ctx, "CreateRoom", Grant{RoomCreate: true}, map[string]string{"name": "01CALL"}, nil); err != nil {
		t.Fatal(err)
	}
	if event := nextHook("room_started"); event.Room == nil || event.Room.Name != "01CALL" {
		t.Fatalf("room_started %+v", event)
	}
	if participants, err := client.ListParticipants(ctx, "01CALL"); err != nil || len(participants) != 0 {
		t.Fatalf("list: %v, %v", participants, err)
	}
	if err := client.RemoveParticipant(ctx, "01CALL", "nobody@test.local/01HZXQ8Z7K3V5M2N4P6R8T0W9Y"); err != nil {
		t.Fatalf("remove nobody: %v", err)
	}
	if err := client.DeleteRoom(ctx, "01CALL"); err != nil {
		t.Fatal(err)
	}
	nextHook("room_finished")
}
