package protocol

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

type fixtures struct {
	Valid   []json.RawMessage `json:"valid"`
	Invalid []struct {
		Reason   string          `json:"reason"`
		Envelope json.RawMessage `json:"envelope"`
	} `json:"invalid"`
}

// The same file is checked by the Dart tests in protocol/test.
func loadFixtures(t *testing.T) fixtures {
	data, err := os.ReadFile("../../../protocol/testdata/envelopes.json")
	if err != nil {
		t.Fatal(err)
	}
	var f fixtures
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestSharedValidEnvelopes(t *testing.T) {
	for _, raw := range loadFixtures(t).Valid {
		env, err := ParseEnvelope(raw)
		if err != nil {
			t.Errorf("rejected valid envelope %s: %v", raw, err)
			continue
		}
		// The relayed JSON must be the original, unchanged apart from whitespace.
		var original, relayed any
		_ = json.Unmarshal(raw, &original)
		_ = json.Unmarshal(env.Raw, &relayed)
		a, _ := json.Marshal(original)
		b, _ := json.Marshal(relayed)
		if string(a) != string(b) {
			t.Errorf("relayed envelope changed:\n%s\n%s", a, b)
		}
	}
}

func TestSharedInvalidEnvelopes(t *testing.T) {
	for _, c := range loadFixtures(t).Invalid {
		if _, err := ParseEnvelope(c.Envelope); err == nil {
			t.Errorf("accepted invalid envelope (%s)", c.Reason)
		}
	}
}

func TestBodySizeLimit(t *testing.T) {
	big := `{"v":3,"id":"01JB2Y8Q3M7W2V6T0Q9X4C5D6E","conv":"c","from":"a@b","device":"01JB2Y8Q3M7W2V6T0Q9X4C5D6F",` +
		`"ts":1,"type":"mls.app","body":{"epoch":0,"mls":"bQ==","ct":"` + strings.Repeat("A", MaxBodyBytes) + `"}}`
	if _, err := ParseEnvelope([]byte(big)); err == nil {
		t.Fatal("accepted an oversized body")
	}
}

func TestUserIDs(t *testing.T) {
	for id, want := range map[string]bool{
		"sota@chat.example.org":  true,
		"michiko@localhost:8080": true,
		"nohost":                 false,
		"@host":                  false,
		"Upper@host":             false,
		"name@bad host":          false,
		// 128 characters at most.
		"a@" + strings.Repeat("h", 126): true,
		"a@" + strings.Repeat("h", 127): false,
	} {
		if got := ValidUserID(id); got != want {
			t.Errorf("ValidUserID(%q) = %v, want %v", id, got, want)
		}
	}
}

func TestDeviceRecordMatchesSharedFixture(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/testdata/device_record.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct{ UserID, DeviceID, MLSSigKey, Message string }
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	if got := base64.StdEncoding.EncodeToString(DeviceRecordMessage(f.UserID, f.DeviceID, f.MLSSigKey)); got != f.Message {
		t.Fatalf("device record bytes differ from the Dart side:\n%s\n%s", got, f.Message)
	}
}
