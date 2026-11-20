package livekit

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// ErrNotSigned: a webhook that LiveKit (holding the API secret) did not send,
// or whose body changed on the way.
var ErrNotSigned = errors.New("livekit: webhook not signed by this server's LiveKit")

// leeway allows for clocks that differ.
const leeway = time.Minute

// Event is what a webhook says happened in a room (the fields used here).
// LiveKit's events include room_started, room_finished, participant_joined
// and participant_left.
type Event struct {
	ID          string       `json:"id"`
	Event       string       `json:"event"`
	Room        *Room        `json:"room,omitempty"`
	Participant *Participant `json:"participant,omitempty"`
}

type Room struct {
	SID  string `json:"sid"`
	Name string `json:"name"`
}

// Participant is someone in a room: Identity is what their token was made
// for, SID this one connection of theirs.
type Participant struct {
	SID      string `json:"sid"`
	Identity string `json:"identity"`
}

// Verify checks that body comes from the LiveKit server holding the secret:
// auth, the request's Authorization header, must be a token it signed for
// this API key that says the body's SHA-256.
func (k Keys) Verify(auth string, body []byte, now time.Time) error {
	token := strings.TrimPrefix(auth, "Bearer ")
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return ErrNotSigned
	}
	var header struct {
		Alg string `json:"alg"`
	}
	if raw, err := b64.DecodeString(parts[0]); err != nil || json.Unmarshal(raw, &header) != nil || header.Alg != "HS256" {
		return ErrNotSigned
	}
	signature, err := b64.DecodeString(parts[2])
	if err != nil || !hmac.Equal(signature, k.mac(parts[0]+"."+parts[1])) {
		return ErrNotSigned
	}
	var c claims
	if raw, err := b64.DecodeString(parts[1]); err != nil || json.Unmarshal(raw, &c) != nil {
		return ErrNotSigned
	}
	if c.Issuer != k.APIKey || (c.NotBefore != 0 && now.Add(leeway).Unix() < c.NotBefore) ||
		(c.Expires != 0 && now.Add(-leeway).Unix() > c.Expires) {
		return ErrNotSigned
	}
	sum := sha256.Sum256(body)
	if subtle.ConstantTimeCompare([]byte(c.Sha256), []byte(base64.StdEncoding.EncodeToString(sum[:]))) != 1 {
		return ErrNotSigned
	}
	return nil
}

// ParseEvent reads a webhook's body, once Verify took it.
func ParseEvent(body []byte) (Event, error) {
	var e Event
	err := json.Unmarshal(body, &e)
	return e, err
}

// SignWebhook signs body as LiveKit does: for tests.
func (k Keys) SignWebhook(body []byte, now time.Time) (string, error) {
	sum := sha256.Sum256(body)
	return k.sign(claims{
		Issuer:    k.APIKey,
		NotBefore: now.Unix(),
		Expires:   now.Add(5 * time.Minute).Unix(),
		Sha256:    base64.StdEncoding.EncodeToString(sum[:]),
	})
}
