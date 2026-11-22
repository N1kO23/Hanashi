package config

import (
	"testing"

	"hanashi/server/internal/protocol"
)

func TestPublicHost(t *testing.T) {
	for host, want := range map[string]bool{
		"example.org":      true,
		"chat.example.org": true,
		"abc234.onion":     true,
		"localhost":        false,
		"app.localhost":    false,
		"hanashi.local":    false,
		"server":           false,
		"192.168.1.10":     false,
		"example.org:8080": false,
		"localhost:8080":   false,
	} {
		if got := PublicHost(host); got != want {
			t.Errorf("PublicHost(%q) = %v, want %v", host, got, want)
		}
	}
}

func TestMinClient(t *testing.T) {
	load := func(value string) (Config, error) {
		env := map[string]string{"HANASHI_DB_DSN": "dsn", "HANASHI_MIN_CLIENT": value}
		return FromEnv(func(key string) (string, bool) {
			v, ok := env[key]
			return v, ok
		})
	}
	cfg, err := load("")
	if err != nil || cfg.MinClient != protocol.MinClient {
		t.Fatalf("unset: %d, %v", cfg.MinClient, err)
	}
	cfg, err = load("7")
	if err != nil || cfg.MinClient != 7 {
		t.Fatalf("raised: %d, %v", cfg.MinClient, err)
	}
	for _, bad := range []string{"-1", "soon", "1.5"} {
		if _, err := load(bad); err == nil {
			t.Errorf("%q was taken", bad)
		}
	}
}

func TestSourceURL(t *testing.T) {
	load := func(value string) (Config, error) {
		env := map[string]string{"HANASHI_DB_DSN": "dsn", "HANASHI_SOURCE_URL": value}
		return FromEnv(func(key string) (string, bool) {
			v, ok := env[key]
			return v, ok
		})
	}
	cfg, err := load("")
	if err != nil || cfg.SourceURL != DefaultSourceURL {
		t.Fatalf("unset: %q, %v", cfg.SourceURL, err)
	}
	cfg, err = load("https://git.example.org/chat/hanashi")
	if err != nil || cfg.SourceURL != "https://git.example.org/chat/hanashi" {
		t.Fatalf("set: %q, %v", cfg.SourceURL, err)
	}
	for _, bad := range []string{"git.example.org/hanashi", "ftp://example.org/hanashi.tar", "https://", "mailto:a@b.c"} {
		if _, err := load(bad); err == nil {
			t.Errorf("%q was taken", bad)
		}
	}
}

func TestFederation(t *testing.T) {
	load := func(env map[string]string) (Config, error) {
		env["HANASHI_DB_DSN"] = "dsn"
		return FromEnv(func(key string) (string, bool) {
			v, ok := env[key]
			return v, ok
		})
	}
	cfg, err := load(map[string]string{})
	if err != nil || cfg.Federation || len(cfg.FederationServers) != 0 || len(cfg.FederationResolve) != 0 ||
		cfg.FederationRate != 100 || cfg.HandOver != HandOverGroupsLeft {
		t.Fatalf("unset: %+v, %v", cfg, err)
	}
	if cfg, err := load(map[string]string{"HANASHI_FEDERATION_RATE": "2.5"}); err != nil || cfg.FederationRate != 2.5 {
		t.Fatalf("rate: %v, %v", cfg.FederationRate, err)
	}
	cfg, err = load(map[string]string{
		"HANASHI_FEDERATION":         "on",
		"HANASHI_FEDERATION_SERVERS": " Example.org, chat.example.net ",
		"HANASHI_FEDERATION_RESOLVE": "a.test=http://127.0.0.1:8081/, b.test=https://b.example",
	})
	if err != nil || !cfg.Federation {
		t.Fatalf("on: %v", err)
	}
	if !cfg.FederationServers["example.org"] || !cfg.FederationServers["chat.example.net"] || len(cfg.FederationServers) != 2 {
		t.Fatalf("servers %v", cfg.FederationServers)
	}
	if cfg.FederationResolve["a.test"] != "http://127.0.0.1:8081" || cfg.FederationResolve["b.test"] != "https://b.example" {
		t.Fatalf("resolve %v", cfg.FederationResolve)
	}
	cfg, err = load(map[string]string{"HANASHI_FEDERATION": "on", "HANASHI_FEDERATION_SERVERS": "*"})
	if err != nil || !cfg.FederationAnyServer || len(cfg.FederationServers) != 0 {
		t.Fatalf("any server: %+v, %v", cfg, err)
	}
	// Before shutting it down, everything it orders goes to other servers.
	cfg, err = load(map[string]string{"HANASHI_FEDERATION": "on", "HANASHI_FEDERATION_SERVERS": "*", "HANASHI_HAND_OVER": "all"})
	if err != nil || cfg.HandOver != HandOverAll {
		t.Fatalf("hand over all: %v, %v", cfg.HandOver, err)
	}
	for _, bad := range []map[string]string{
		{"HANASHI_FEDERATION": "yes"},
		// On, it needs to know with whom: a list, or * for any.
		{"HANASHI_FEDERATION": "on"},
		{"HANASHI_FEDERATION": "on", "HANASHI_FEDERATION_SERVERS": "*, example.org"},
		{"HANASHI_FEDERATION_SERVERS": "not a host"},
		{"HANASHI_FEDERATION_RESOLVE": "a.test"},
		{"HANASHI_FEDERATION_RESOLVE": "a.test=ftp://a"},
		{"HANASHI_FEDERATION_RESOLVE": "a.test=http://"},
		{"HANASHI_FEDERATION_RATE": "0"},
		{"HANASHI_FEDERATION_RATE": "fast"},
		{"HANASHI_FEDERATION": "on", "HANASHI_FEDERATION_SERVERS": "*", "HANASHI_HAND_OVER": "some"},
		// Without federation, there is nobody to hand anything to.
		{"HANASHI_HAND_OVER": "all"},
	} {
		if _, err := load(bad); err == nil {
			t.Errorf("%v was taken", bad)
		}
	}
}

func TestLiveKit(t *testing.T) {
	load := func(env map[string]string) (Config, error) {
		env["HANASHI_DB_DSN"] = "dsn"
		return FromEnv(func(key string) (string, bool) {
			v, ok := env[key]
			return v, ok
		})
	}
	cfg, err := load(map[string]string{})
	if err != nil || cfg.Calls() {
		t.Fatalf("none set: calls %v, %v", cfg.Calls(), err)
	}
	cfg, err = load(map[string]string{
		"HANASHI_LIVEKIT_URL":        "wss://calls.example.org/",
		"HANASHI_LIVEKIT_API_KEY":    "key",
		"HANASHI_LIVEKIT_API_SECRET": "secret",
	})
	if err != nil || !cfg.Calls() || cfg.LiveKitURL != "wss://calls.example.org" || cfg.LiveKitAPIURL != "https://calls.example.org" {
		t.Fatalf("all set: %+v, %v", cfg, err)
	}
	cfg, err = load(map[string]string{
		"HANASHI_LIVEKIT_URL":        "ws://localhost:7880",
		"HANASHI_LIVEKIT_API_URL":    "http://livekit:7880",
		"HANASHI_LIVEKIT_API_KEY":    "key",
		"HANASHI_LIVEKIT_API_SECRET": "secret",
	})
	if err != nil || cfg.LiveKitAPIURL != "http://livekit:7880" || cfg.CallRingTimeout == 0 {
		t.Fatalf("own API URL: %+v, %v", cfg, err)
	}
	for _, env := range []map[string]string{
		{"HANASHI_LIVEKIT_URL": "wss://calls.example.org"},
		{"HANASHI_LIVEKIT_API_KEY": "key", "HANASHI_LIVEKIT_API_SECRET": "secret"},
		{"HANASHI_LIVEKIT_API_URL": "http://livekit:7880"},
		{"HANASHI_LIVEKIT_URL": "https://calls.example.org", "HANASHI_LIVEKIT_API_KEY": "key", "HANASHI_LIVEKIT_API_SECRET": "secret"},
		{"HANASHI_LIVEKIT_URL": "wss://calls.example.org", "HANASHI_LIVEKIT_API_URL": "ftp://x", "HANASHI_LIVEKIT_API_KEY": "key", "HANASHI_LIVEKIT_API_SECRET": "secret"},
	} {
		if _, err := load(env); err == nil {
			t.Errorf("%v: no error", env)
		}
	}
}
