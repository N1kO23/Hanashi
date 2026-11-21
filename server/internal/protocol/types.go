package protocol

import "encoding/json"

// SyncEvent is one entry of the event log. Data is a raw JSON object.
type SyncEvent struct {
	Seq  int64           `json:"seq"`
	Type string          `json:"type"`
	Conv string          `json:"conv"`
	TS   int64           `json:"ts"`
	Data json.RawMessage `json:"data"`
}

type MemberInfo struct {
	ID string `json:"id"`
}

type ConversationInfo struct {
	ID       string       `json:"id"`
	IsDirect bool         `json:"isDirect"`
	Members  []MemberInfo `json:"members"`
}

type SyncPage struct {
	Events []SyncEvent `json:"events"`
	Cursor int64       `json:"cursor"`
	More   bool        `json:"more"`
}

type ConversationSnapshot struct {
	Conversation ConversationInfo `json:"conversation"`
	ReadUpTo     int64            `json:"readUpTo"`
	Messages     []SyncEvent      `json:"messages"`
	MoreHistory  bool             `json:"moreHistory"`
}

type SyncSnapshot struct {
	Cursor        int64                  `json:"cursor"`
	Conversations []ConversationSnapshot `json:"conversations"`
}

type HistoryPage struct {
	Messages []SyncEvent `json:"messages"`
	More     bool        `json:"more"`
}

type AuthResult struct {
	UserID   string `json:"userId"`
	Token    string `json:"token"`
	DeviceID string `json:"deviceId"`
}

type DeviceInfo struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Platform   string `json:"platform"`
	CreatedAt  int64  `json:"createdAt"`
	LastSeenAt int64  `json:"lastSeenAt"`
	Current    bool   `json:"current"`
}

type ServerInfo struct {
	Host           string `json:"host"`
	Version        string `json:"version"`
	Registration   string `json:"registration"`
	MaxUploadBytes int64  `json:"maxUploadBytes"`
	// MinClient is the lowest client level this server takes.
	MinClient int `json:"minClient"`
	// VAPIDKey is the server's push key (base64url P-256 point); clients
	// register push subscriptions for it.
	VAPIDKey string `json:"vapidKey"`
	// Source is where the server's source code is (an http(s) URL), which
	// apps offer its users, as the AGPL asks of a server run for others.
	Source string `json:"source"`
}

// Integrations are services the operator set up for signed-in users.
type Integrations struct {
	// KlipyAPIKey is for GIF search; apps call KLIPY with it themselves.
	KlipyAPIKey string `json:"klipyApiKey,omitempty"`
	// Calls: the server carries voice calls (through LiveKit).
	Calls bool `json:"calls,omitempty"`
	// Video: calls may carry cameras and shared screens too, and a call of
	// two may be a video call (see Call.Video).
	Video bool `json:"video,omitempty"`
}

// Call is a conversation's voice call, as the server knows it (see
// docs/calls.md). Times are milliseconds since the Unix epoch.
type Call struct {
	ID   string `json:"id"`
	Conv string `json:"conv"`
	// Direct: the call of a chat of two, which rings.
	Direct bool `json:"direct"`
	// Video: started as a video call; its devices start with their cameras
	// on.
	Video         bool   `json:"video,omitempty"`
	StartedBy     string `json:"startedBy"`
	StartedDevice string `json:"startedDevice"`
	StartedAt     int64  `json:"startedAt"`
	// RingUntil is when a direct call nobody answered is missed.
	RingUntil  int64 `json:"ringUntil,omitempty"`
	AnsweredAt int64 `json:"answeredAt,omitempty"`
	EndedAt    int64 `json:"endedAt,omitempty"`
	// Reason is why it ended: one of the CallEnded* values.
	Reason string `json:"reason,omitempty"`
	// Version goes up with every change, so that apps keep the latest.
	Version      int64             `json:"version"`
	Participants []CallParticipant `json:"participants"`
}

// CallParticipant is a device of a user in a call.
type CallParticipant struct {
	User     string `json:"user"`
	Device   string `json:"device"`
	JoinedAt int64  `json:"joinedAt"`
}

// Why a call ended.
const (
	CallEnded     = "ended"
	CallDeclined  = "declined"
	CallMissed    = "missed"
	CallCancelled = "cancelled"
	CallFailed    = "failed"
)
