package api_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"hanashi/server/internal/config"
	"hanashi/server/internal/protocol"
)

func withMinClient(level int) serverOption {
	return func(c *config.Config) { c.MinClient = level }
}

// asLevel sends a request as an app of a client level ("" says none), and
// answers its status and body.
func asLevel(t *testing.T, base, method, path, level string, body any) (int, map[string]any) {
	t.Helper()
	data, _ := json.Marshal(body)
	req, _ := http.NewRequest(method, base+path, bytes.NewReader(data))
	if level != "" {
		req.Header.Set(protocol.ClientHeader, level)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func TestAppsBelowTheMinimumAreRefused(t *testing.T) {
	base := startServer(t, withMinClient(2))
	signUp := map[string]any{"name": "sota", "password": "password123", "deviceName": "laptop", "platform": "test"}
	for _, level := range []string{"", "0", "1", "not a number"} {
		status, res := asLevel(t, base, "POST", "/auth/register", level, signUp)
		if status != http.StatusUpgradeRequired || res["error"] != "client_too_old" || res["message"] == nil {
			t.Fatalf("level %q: %d %v", level, status, res)
		}
	}
	// They can still find out what is needed.
	status, res := asLevel(t, base, "GET", "/server", "", nil)
	if status != http.StatusOK || res["minClient"] != float64(2) {
		t.Fatalf("server info: %d %v", status, res)
	}
	// It comes before the token is looked at.
	if status, res := asLevel(t, base, "GET", "/sync", "1", nil); res["error"] != "client_too_old" {
		t.Fatalf("signed out and too old: %d %v", status, res)
	}
	if status, res := asLevel(t, base, "GET", "/sync", "2", nil); res["error"] != "unauthorized" {
		t.Fatalf("signed out: %d %v", status, res)
	}
	for _, level := range []int{2, 3} {
		signUp["name"] = "user" + strconv.Itoa(level)
		if status, res := asLevel(t, base, "POST", "/auth/register", strconv.Itoa(level), signUp); status != http.StatusOK {
			t.Fatalf("level %d: %d %v", level, status, res)
		}
	}
}

func TestWebSocketsBelowTheMinimumAreRefused(t *testing.T) {
	base := startServer(t, withMinClient(2))
	_, signedUp := asLevel(t, base, "POST", "/auth/register", "2", map[string]any{
		"name": "sota", "password": "password123", "deviceName": "laptop", "platform": "test",
	})
	token := signedUp["token"]
	// The first frame back, and how the socket closes if it does.
	auth := func(frame map[string]any) (string, websocket.StatusCode) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(base, "http")+"/ws", nil)
		if err != nil {
			t.Fatal(err)
		}
		defer ws.CloseNow()
		data, _ := json.Marshal(frame)
		if err := ws.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatal(err)
		}
		_, data, err = ws.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var got struct{ Type, Error string }
		_ = json.Unmarshal(data, &got)
		if got.Type == protocol.FrameReady {
			return got.Type, -1
		}
		_, _, err = ws.Read(ctx)
		return got.Error, websocket.CloseStatus(err)
	}
	for _, frame := range []map[string]any{
		{"type": "auth", "token": token},
		{"type": "auth", "token": token, "client": 1},
		{"type": "auth", "token": "wrong", "client": 1},
	} {
		if refusal, status := auth(frame); refusal != "client_too_old" || status != 4002 {
			t.Fatalf("%v: %q, closed with %d", frame, refusal, status)
		}
	}
	if refusal, status := auth(map[string]any{"type": "auth", "token": "wrong", "client": 2}); refusal != "unauthorized" || status != 4001 {
		t.Fatalf("wrong token: %q, closed with %d", refusal, status)
	}
	if answer, _ := auth(map[string]any{"type": "auth", "token": token, "client": 2}); answer != protocol.FrameReady {
		t.Fatalf("level 2: %q", answer)
	}
}
