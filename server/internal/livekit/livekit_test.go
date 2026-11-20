package livekit

import (
	"context"
	"crypto/hmac"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

var keys = Keys{APIKey: "APIkey", Secret: "a secret long enough for HMAC-SHA256, at least 32 bytes"}

func decode(t *testing.T, token string) (map[string]any, map[string]any) {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("not a JWT: %q", token)
	}
	var header, payload map[string]any
	for i, out := range []*map[string]any{&header, &payload} {
		raw, err := b64.DecodeString(parts[i])
		if err != nil || json.Unmarshal(raw, out) != nil {
			t.Fatalf("part %d: %v", i, err)
		}
	}
	return header, payload
}

func TestJoinTokenSaysWhatLiveKitReads(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	token, err := keys.Token("kumiko@test.local/01DEVICE", JoinGrant("01CALL"), now, 10*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	header, claims := decode(t, token)
	if header["alg"] != "HS256" {
		t.Errorf("alg %v", header["alg"])
	}
	if claims["iss"] != "APIkey" || claims["sub"] != "kumiko@test.local/01DEVICE" ||
		claims["exp"] != float64(now.Add(10*time.Minute).Unix()) || claims["nbf"].(float64) > float64(now.Unix()) {
		t.Errorf("claims %v", claims)
	}
	video := claims["video"].(map[string]any)
	if video["room"] != "01CALL" || video["roomJoin"] != true || video["canPublish"] != true ||
		video["canSubscribe"] != true || video["canPublishData"] != true || video["canUpdateOwnMetadata"] != true {
		t.Errorf("video %v", video)
	}
	if sources := video["canPublishSources"].([]any); len(sources) != 4 || sources[0] != "microphone" ||
		sources[1] != "camera" || sources[2] != "screen_share" || sources[3] != "screen_share_audio" {
		t.Errorf("sources %v", sources)
	}
	// Signed with the secret.
	parts := strings.Split(token, ".")
	if signature, _ := b64.DecodeString(parts[2]); !hmac.Equal(signature, keys.mac(parts[0]+"."+parts[1])) {
		t.Error("not signed with the secret")
	}
}

func TestWebhooksOnlyFromOurLiveKit(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	body := []byte(`{"event":"participant_joined","room":{"name":"01CALL"},"participant":{"sid":"PA_1","identity":"a@b/D"}}`)
	auth, err := keys.SignWebhook(body, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := keys.Verify(auth, body, now); err != nil {
		t.Fatalf("our own: %v", err)
	}
	if err := keys.Verify("Bearer "+auth, body, now.Add(30*time.Second)); err != nil {
		t.Fatalf("with Bearer, a little later: %v", err)
	}
	event, err := ParseEvent(body)
	if err != nil || event.Event != "participant_joined" || event.Room.Name != "01CALL" || event.Participant.Identity != "a@b/D" {
		t.Fatalf("parsed %+v, %v", event, err)
	}

	other := Keys{APIKey: "APIkey", Secret: "another secret, also long enough to be a real one"}
	forged, _ := other.SignWebhook(body, now)
	wrongKey, _ := Keys{APIKey: "other", Secret: keys.Secret}.SignWebhook(body, now)
	unsigned := b64.EncodeToString([]byte(`{"alg":"none"}`)) + "." + strings.Split(auth, ".")[1] + "."
	for name, c := range map[string]struct {
		auth string
		body []byte
		at   time.Time
	}{
		"body changed":    {auth, []byte(strings.Replace(string(body), "a@b/D", "x@b/D", 1)), now},
		"another secret":  {forged, body, now},
		"another API key": {wrongKey, body, now},
		"alg none":        {unsigned, body, now},
		"expired":         {auth, body, now.Add(10 * time.Minute)},
		"not yet valid":   {auth, body, now.Add(-5 * time.Minute)},
		"no header":       {"", body, now},
		"not a token":     {"abc", body, now},
	} {
		if err := keys.Verify(c.auth, c.body, c.at); err != ErrNotSigned {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestRoomAPI(t *testing.T) {
	var calls []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_, claims := decode(t, strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
		video := claims["video"].(map[string]any)
		calls = append(calls, r.URL.Path+" "+string(body))
		switch r.URL.Path {
		case "/twirp/livekit.RoomService/ListParticipants":
			if video["roomAdmin"] != true || video["room"] != "01CALL" {
				t.Errorf("list grant %v", video)
			}
			w.Write([]byte(`{"participants":[{"sid":"PA_1","identity":"a@b/D","state":"ACTIVE"}]}`))
		case "/twirp/livekit.RoomService/DeleteRoom":
			if video["roomCreate"] != true {
				t.Errorf("delete grant %v", video)
			}
			w.WriteHeader(http.StatusNotFound)
			w.Write([]byte(`{"code":"not_found","msg":"room not found"}`))
		default:
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte(`{"code":"internal","msg":"down"}`))
		}
	}))
	defer server.Close()
	client := &Client{URL: server.URL, Keys: keys, HTTP: server.Client()}
	ctx := context.Background()
	participants, err := client.ListParticipants(ctx, "01CALL")
	if err != nil || len(participants) != 1 || participants[0].SID != "PA_1" || participants[0].Identity != "a@b/D" {
		t.Fatalf("list: %+v, %v", participants, err)
	}
	if err := client.DeleteRoom(ctx, "01CALL"); err != nil {
		t.Fatalf("a room not there is fine: %v", err)
	}
	if err := client.RemoveParticipant(ctx, "01CALL", "a@b/D"); err == nil || !strings.Contains(err.Error(), "internal") {
		t.Fatalf("an error says so: %v", err)
	}
	if len(calls) != 3 || calls[1] != `/twirp/livekit.RoomService/DeleteRoom {"room":"01CALL"}` {
		t.Errorf("calls %v", calls)
	}
}
