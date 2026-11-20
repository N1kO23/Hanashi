package api_test

import (
	"strings"
	"testing"
)

func (d *device) sendToDevices(to []map[string]string, typ string, data any) (int, error) {
	var res struct{ Delivered int }
	err := d.do("POST", "/inbox/send", map[string]any{"to": to, "type": typ, "data": data}, &res)
	return res.Delivered, err
}

func TestDeviceMessages(t *testing.T) {
	base := startServer(t)
	phone := register(t, base, "sota")
	laptop := login(t, base, "sota", "laptop")
	desktop := login(t, base, "sota", "desktop")
	kumiko := register(t, base, "kumiko")
	stranger := register(t, base, "stranger")
	onDesktop := desktop.connect()
	request := map[string]any{"txn": "T1", "mode": "device"}

	// To all of one's own other devices: not back to the sender.
	n, err := laptop.sendToDevices([]map[string]string{{"user": phone.UserID}}, "verification.request", request)
	if err != nil || n != 2 {
		t.Fatalf("delivered %d, %v", n, err)
	}
	frame := onDesktop.nextOfType("inbox")
	item := frame["item"].(map[string]any)
	if item["type"] != "verification.request" || item["fromDevice"] != laptop.DeviceID || item["data"].(map[string]any)["txn"] != "T1" {
		t.Fatalf("pushed %v", item)
	}
	if len(phone.inbox()) != 1 || len(laptop.inbox()) != 0 {
		t.Fatal("wrong inboxes")
	}
	// To one device.
	if n, err := phone.sendToDevices([]map[string]string{{"user": phone.UserID, "device": laptop.DeviceID}}, "verification.accept", map[string]any{"txn": "T1"}); err != nil || n != 1 {
		t.Fatalf("one device: %d, %v", n, err)
	}

	// Contacts only: strangers cannot be pestered.
	if _, err := stranger.sendToDevices([]map[string]string{{"user": kumiko.UserID}}, "verification.request", request); codeOf(err) != "not_a_contact" {
		t.Fatalf("stranger: %v", err)
	}
	phone.createConversation("", kumiko.UserID)
	if n, err := phone.sendToDevices([]map[string]string{{"user": kumiko.UserID}}, "verification.request", request); err != nil || n != 1 {
		t.Fatalf("contact: %d, %v", n, err)
	}

	for name, body := range map[string]map[string]any{
		"not verification": {"to": []map[string]string{{"user": phone.UserID}}, "type": "mls.welcome", "data": request},
		"not an object":    {"to": []map[string]string{{"user": phone.UserID}}, "type": "verification.key", "data": "x"},
		"too large":        {"to": []map[string]string{{"user": phone.UserID}}, "type": "verification.key", "data": map[string]any{"x": strings.Repeat("a", 17*1024)}},
		"nobody":           {"to": []map[string]string{}, "type": "verification.key", "data": request},
	} {
		if err := laptop.do("POST", "/inbox/send", body, nil); statusOf(err) != 400 {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := laptop.sendToDevices([]map[string]string{{"user": phone.UserID, "device": kumiko.DeviceID}}, "verification.key", request); codeOf(err) != "device_not_found" {
		t.Fatalf("someone else's device: %v", err)
	}
}

func TestAttestations(t *testing.T) {
	base := startServer(t)
	phone := register(t, base, "sota")
	laptop := login(t, base, "sota", "laptop")
	kumiko := register(t, base, "kumiko")
	idPub, _ := newKey(t)
	phone.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(idPub)}, nil)
	onLaptop := laptop.connect()

	attestations := func(d *device) map[string]string {
		// A fresh value each time: decoding into a used map would merge.
		var res struct{ Attestations map[string]string }
		d.must("GET", "/keys/attestations", nil, &res)
		return res.Attestations
	}
	phone.must("PUT", "/keys/attestations/"+kumiko.UserID, map[string]any{"data": "signed statement"}, nil)
	// The user's other devices hear about it.
	onLaptop.nextOfType("trust")
	if got := attestations(laptop); got[kumiko.UserID] != "signed statement" {
		t.Fatalf("attestations %v", got)
	}
	// Each user sees only their own.
	if got := attestations(kumiko); len(got) != 0 {
		t.Fatalf("kumiko sees %v", got)
	}
	if err := phone.do("PUT", "/keys/attestations/nobody@test.local", map[string]any{"data": "x"}, nil); codeOf(err) != "user_not_found" {
		t.Fatalf("unknown user: %v", err)
	}
	if err := phone.do("PUT", "/keys/attestations/"+kumiko.UserID, map[string]any{"data": strings.Repeat("x", 5000)}, nil); statusOf(err) != 400 {
		t.Fatalf("too large: %v", err)
	}

	// Signed with the old identity: a reset removes them.
	newPub, _ := newKey(t)
	phone.must("PUT", "/keys/identity", map[string]any{"identityKey": b64(newPub), "reset": true}, nil)
	if got := attestations(phone); len(got) != 0 {
		t.Fatalf("after reset %v", got)
	}
	phone.must("PUT", "/keys/attestations/"+kumiko.UserID, map[string]any{"data": "again"}, nil)
	phone.must("PUT", "/keys/attestations/"+kumiko.UserID, map[string]any{"data": "newer"}, nil)
	if got := attestations(phone); len(got) != 1 || got[kumiko.UserID] != "newer" {
		t.Fatalf("a new statement replaces the old one: %v", got)
	}
}
