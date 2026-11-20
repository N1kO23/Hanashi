package api_test

import (
	"strings"
	"testing"
)

func TestAccountData(t *testing.T) {
	base := startServer(t)
	phone := register(t, base, "sota")
	laptop := login(t, base, "sota", "laptop")
	kumiko := register(t, base, "kumiko")
	idPub, _ := newKey(t)
	phone.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(idPub)}, nil)
	onLaptop := laptop.connect()

	if err := laptop.do("GET", "/account-data/profile", nil, nil); statusOf(err) != 404 {
		t.Fatalf("before: %v", err)
	}
	var put struct{ Version int64 }
	phone.must("PUT", "/account-data/profile", map[string]any{"data": "sealed v1"}, &put)
	if put.Version != 1 {
		t.Fatalf("first version %d", put.Version)
	}
	phone.must("PUT", "/account-data/profile", map[string]any{"data": "sealed v2", "version": 1}, &put)
	if put.Version != 2 {
		t.Fatalf("second version %d", put.Version)
	}
	// The user's other devices hear about it, and read the latest.
	if f := onLaptop.nextOfType("account_data"); f["name"] != "profile" {
		t.Fatalf("frame %v", f)
	}
	var res struct {
		Data    string
		Version int64
	}
	laptop.must("GET", "/account-data/profile", nil, &res)
	if res.Data != "sealed v2" || res.Version != 2 {
		t.Fatalf("data %q at %d", res.Data, res.Version)
	}
	// A device that read an earlier version cannot overwrite what it never saw.
	for name, version := range map[string]int64{"none": 0, "earlier": 1, "later": 3} {
		err := laptop.do("PUT", "/account-data/profile", map[string]any{"data": "lost", "version": version}, nil)
		if codeOf(err) != "version_conflict" {
			t.Errorf("%s: %v", name, err)
		}
	}
	laptop.must("GET", "/account-data/profile", nil, &res)
	if res.Data != "sealed v2" {
		t.Fatalf("overwritten: %q", res.Data)
	}
	// Each user has their own.
	if err := kumiko.do("GET", "/account-data/profile", nil, nil); statusOf(err) != 404 {
		t.Fatalf("kumiko: %v", err)
	}
	for name, tc := range map[string]struct{ path, data string }{
		"bad name":  {"/account-data/Profile!", "x"},
		"empty":     {"/account-data/profile", ""},
		"too large": {"/account-data/profile", strings.Repeat("x", 256*1024+1)},
	} {
		if err := phone.do("PUT", tc.path, map[string]any{"data": tc.data}, nil); statusOf(err) != 400 {
			t.Errorf("%s: %v", name, err)
		}
	}

	// Encrypted with the old backup secret: a reset removes it.
	newPub, _ := newKey(t)
	phone.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(newPub), "reset": true}, nil)
	if err := phone.do("GET", "/account-data/profile", nil, nil); statusOf(err) != 404 {
		t.Fatalf("after reset: %v", err)
	}
}
