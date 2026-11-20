// Package livekit speaks with the LiveKit server that carries calls (see
// docs/calls.md): the tokens apps join a call's room with, the webhooks
// LiveKit sends about rooms, and LiveKit's room API. Tokens are JWTs signed
// with HMAC-SHA256 and the API secret LiveKit and this server share.
package livekit

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"time"
)

var b64 = base64.RawURLEncoding

// Keys are what LiveKit knows this server by.
type Keys struct {
	APIKey string
	Secret string
}

// Grant is what a token allows in LiveKit's rooms (LiveKit's "video" grant,
// the fields used here).
type Grant struct {
	Room       string `json:"room,omitempty"`
	RoomJoin   bool   `json:"roomJoin,omitempty"`
	RoomCreate bool   `json:"roomCreate,omitempty"`
	RoomAdmin  bool   `json:"roomAdmin,omitempty"`
	// Only for joining: LiveKit allows each unless it is false.
	CanPublish           *bool `json:"canPublish,omitempty"`
	CanSubscribe         *bool `json:"canSubscribe,omitempty"`
	CanPublishData       *bool `json:"canPublishData,omitempty"`
	CanUpdateOwnMetadata *bool `json:"canUpdateOwnMetadata,omitempty"`
	// CanPublishSources limits what may be published: "microphone",
	// "camera", "screen_share", "screen_share_audio".
	CanPublishSources []string `json:"canPublishSources,omitempty"`
}

type claims struct {
	Issuer    string `json:"iss"`
	Subject   string `json:"sub,omitempty"`
	ID        string `json:"jti,omitempty"`
	NotBefore int64  `json:"nbf"`
	Expires   int64  `json:"exp"`
	Video     *Grant `json:"video,omitempty"`
	// Sha256 is in webhook tokens: the body's hash.
	Sha256 string `json:"sha256,omitempty"`
}

// JoinGrant lets identity into room to speak, show its camera and share its
// screen with its sound, and to hear and see the others. It may send data
// messages, which the apps encrypt, for the others to see whose voice goes
// out, and set its own attributes, for them to see it deafened (apps show
// neither LiveKit's names nor its metadata).
func JoinGrant(room string) Grant {
	yes := true
	return Grant{
		Room:                 room,
		RoomJoin:             true,
		CanPublish:           &yes,
		CanSubscribe:         &yes,
		CanPublishData:       &yes,
		CanUpdateOwnMetadata: &yes,
		CanPublishSources:    []string{"microphone", "camera", "screen_share", "screen_share_audio"},
	}
}

// Token signs a token for identity (empty for this server's own calls to
// LiveKit's API) with grant, valid for ttl from now.
func (k Keys) Token(identity string, grant Grant, now time.Time, ttl time.Duration) (string, error) {
	return k.sign(claims{
		Issuer:  k.APIKey,
		Subject: identity,
		ID:      identity,
		// A little early, for clocks that differ.
		NotBefore: now.Add(-10 * time.Second).Unix(),
		Expires:   now.Add(ttl).Unix(),
		Video:     &grant,
	})
}

func (k Keys) sign(c claims) (string, error) {
	payload, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	signed := b64.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`)) + "." + b64.EncodeToString(payload)
	return signed + "." + b64.EncodeToString(k.mac(signed)), nil
}

func (k Keys) mac(signed string) []byte {
	m := hmac.New(sha256.New, []byte(k.Secret))
	m.Write([]byte(signed))
	return m.Sum(nil)
}
