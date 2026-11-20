// Package protocol implements the wire format described in docs/protocol.md.
// It must stay compatible with the Dart package in protocol/.
package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

const (
	// ClientHeader says an app's client level on every HTTP request.
	ClientHeader = "X-Hanashi-Client"
	// MinClient is the lowest client level this server works with: apps from
	// 0.9.0 on (see "Client levels" in docs/protocol.md), which sign, derive
	// and encrypt under labels of their own. Older ones are refused before
	// they can do anything.
	MinClient = 5
	// EnvelopeVersion is the wire envelope version: end-to-end encrypted.
	EnvelopeVersion = 3
	// MaxBodyBytes bounds an envelope's JSON-encoded body.
	MaxBodyBytes = 64 * 1024
	// TypeMLSApp is a chat message: an MLS application message carrying the
	// content key, plus the content encrypted with it.
	TypeMLSApp = "mls.app"
	// TypeMLSControl is built the same way but is not part of the chat: it
	// is delivered as a control event, and is left out of history.
	TypeMLSControl = "mls.control"
)

// Sync event types.
const (
	EventMessage             = "message"
	EventConversationCreated = "conversation_created"
	EventMemberAdded         = "member_added"
	EventMemberRemoved       = "member_removed"
	EventReadMarker          = "read_marker"
	// An envelope of type TypeMLSControl.
	EventControl = "control"
	// An MLS commit (data: {"epoch", "mls", "from", "device", "state"?}). Every
	// member device processes commits in seq order.
	EventMLSCommit = "mls_commit"
	// A member sealed the group's state for an epoch whose commit came without
	// it (data: {"epoch", "data", "from", "device"}).
	EventGroupState = "group_state"
	// User-level event (no conversation): a user's identity or device keys
	// changed; clients refetch GET /keys/users/{user}.
	EventDeviceKeysChanged = "device_keys_changed"
	// User-level event: a user published a new profile ({"user", "version"});
	// clients fetch it from GET /users/{user}/profile.
	EventProfileChanged = "profile_changed"
	// User-level event: the relationship with a user changed ({"user", "state"},
	// state as in GET /contacts, or "none").
	EventContactChanged = "contact_changed"
)

// DeviceRecordMessage is what a user's identity key signs to vouch for one
// of their devices. Clients build the same bytes.
func DeviceRecordMessage(userID, deviceID, mlsSigKey string) []byte {
	return []byte("hanashi-device-v1\n" + userID + "\n" + deviceID + "\n" + mlsSigKey)
}

// WebSocket frame types.
const (
	FrameAuth   = "auth"
	FrameReady  = "ready"
	FrameEvent  = "event"
	FrameSend   = "send"
	FrameRead   = "read"
	FrameAck    = "ack"
	FrameNack   = "nack"
	FrameTyping = "typing"
	FrameError  = "error"
	FrameCommit = "commit"
	FrameInbox  = "inbox"
	// FrameBackup tells a user's other devices that the key backup gained
	// entries, so messages waiting for keys may be readable now.
	FrameBackup = "backup"
	// FrameTrust tells a user's other devices that the user's attestations
	// (whom they verified) changed.
	FrameTrust = "trust"
	// FrameAccountData tells a user's other devices that one of the user's
	// account data blobs changed ({"name"}).
	FrameAccountData = "account_data"
	// FramePresence, server -> client: a user's status ({"user", "status"},
	// with "mode" for the user's own devices), or all of them at once
	// ({"statuses", "mode"}). Client -> server: whether the device is in use
	// ({"state": "active"|"idle"}), or without a state, a request for all of
	// them again.
	FramePresence = "presence"
	// FrameCall, server -> client: a call in one of the user's conversations
	// changed ({"call": Call}).
	FrameCall = "call"
)

// Presence: the status others see, and the mode a user chose.
const (
	StatusOnline  = "online"
	StatusIdle    = "idle"
	StatusFocus   = "focus"
	StatusOffline = "offline"

	// ModeAuto shows a user online while a device of theirs is in use, idle
	// otherwise.
	ModeAuto      = "auto"
	ModeFocus     = "focus"
	ModeInvisible = "invisible"
)

// Device inbox item types.
const (
	InboxWelcome = "mls.welcome"
)

var (
	ulidPattern = regexp.MustCompile(`^[0-7][0-9A-HJKMNP-TV-Z]{25}$`)
	namePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,31}$`)
	hostPattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:\d{1,5})?$`)
	hashPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
)

func IsULID(s string) bool        { return ulidPattern.MatchString(s) }
func ValidName(s string) bool     { return namePattern.MatchString(s) }
func ValidHost(s string) bool     { return hostPattern.MatchString(s) }
func IsContentHash(s string) bool { return hashPattern.MatchString(s) }

// MaxUserIDLength is the longest user ID, the size of every column that
// holds one: a host can make an ID of another server longer.
const MaxUserIDLength = 128

// ValidUserID reports whether s is a valid `name@host`.
func ValidUserID(s string) bool {
	at := strings.LastIndex(s, "@")
	return at > 0 && len(s) <= MaxUserIDLength && ValidName(s[:at]) && ValidHost(s[at+1:])
}

// FormatError describes why a payload does not follow the protocol.
type FormatError struct{ Msg string }

func (e *FormatError) Error() string { return e.Msg }

func formatErr(format string, args ...any) error { return &FormatError{fmt.Sprintf(format, args...)} }

// Envelope is a validated, end-to-end encrypted chat message. The server
// relays Raw unchanged (compacted); it cannot read the content.
type Envelope struct {
	Type   string
	ID     string
	Conv   string
	From   string
	Device string
	Epoch  int64
	TS     int64
	Raw    json.RawMessage
}

// ParseEnvelope validates an envelope the same way the Dart
// EncryptedEnvelope.fromJson does. Plaintext envelopes are rejected.
func ParseEnvelope(data []byte) (*Envelope, error) {
	obj, err := decodeObject(data)
	if err != nil {
		return nil, err
	}
	if v, ok := intField(obj, "v"); !ok || v != EnvelopeVersion {
		return nil, formatErr("v must be %d: messages must be end-to-end encrypted", EnvelopeVersion)
	}
	id, _ := obj["id"].(string)
	if !IsULID(id) {
		return nil, formatErr("id must be a ULID")
	}
	conv, _ := obj["conv"].(string)
	if conv == "" {
		return nil, formatErr("conv must be a string")
	}
	from, _ := obj["from"].(string)
	if !ValidUserID(from) {
		return nil, formatErr("from must be name@host")
	}
	device, _ := obj["device"].(string)
	if !IsULID(device) {
		return nil, formatErr("device must be a device ID")
	}
	ts, ok := intField(obj, "ts")
	if !ok {
		return nil, formatErr("ts must be an int")
	}
	typ, _ := obj["type"].(string)
	if typ != TypeMLSApp && typ != TypeMLSControl {
		return nil, formatErr("type must be %q or %q: messages must be end-to-end encrypted", TypeMLSApp, TypeMLSControl)
	}
	body, ok := obj["body"].(map[string]any)
	if !ok {
		return nil, formatErr("body must be an object")
	}
	if encoded, _ := json.Marshal(body); len(encoded) > MaxBodyBytes {
		return nil, formatErr("body is too large")
	}
	epoch, ok := intField(body, "epoch")
	if !ok || epoch < 0 {
		return nil, formatErr("body.epoch must be a non-negative int")
	}
	for _, key := range []string{"mls", "ct"} {
		value, _ := body[key].(string)
		if decoded, err := base64.StdEncoding.DecodeString(value); err != nil || len(decoded) == 0 {
			return nil, formatErr("body.%s must be non-empty base64", key)
		}
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, data); err != nil {
		return nil, formatErr("invalid JSON")
	}
	return &Envelope{Type: typ, ID: id, Conv: conv, From: from, Device: device, Epoch: epoch, TS: ts, Raw: compact.Bytes()}, nil
}

func decodeObject(data []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var obj map[string]any
	if err := dec.Decode(&obj); err != nil || obj == nil {
		return nil, formatErr("expected a JSON object")
	}
	if dec.More() {
		return nil, formatErr("unexpected data after the JSON object")
	}
	return obj, nil
}

// intField reads an integral JSON number (decoded with UseNumber).
func intField(m map[string]any, key string) (int64, bool) {
	n, ok := m[key].(json.Number)
	if !ok || strings.ContainsAny(n.String(), ".eE") {
		return 0, false
	}
	i, err := n.Int64()
	return i, err == nil
}
