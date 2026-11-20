package store

import (
	"context"
	"strings"

	"hanashi/server/internal/protocol"
)

// Calls: the voice calls of conversations, as the server knows them from
// apps and from LiveKit (see docs/calls.md). Times are milliseconds; 0 is
// "not (yet)".

type Call struct {
	ID            string
	Conv          string
	Direct        bool
	StartedBy     string
	StartedDevice string
	StartedAt     int64
	// Video: started as a video call.
	Video      bool
	RingUntil  int64
	AnsweredAt int64
	// FirstJoinedAt is when the first device got into the call's room.
	FirstJoinedAt int64
	EndedAt       int64
	Reason        string
	Version       int64
	Participants  []CallParticipant
}

// CallParticipant is a device in a call: SID is its connection to LiveKit.
type CallParticipant struct {
	User     string
	Device   string
	SID      string
	JoinedAt int64
}

func (c *Call) Active() bool { return c.EndedAt == 0 }

// Has reports whether user has a device in the call.
func (c *Call) Has(user string) bool {
	for _, p := range c.Participants {
		if p.User == user {
			return true
		}
	}
	return false
}

// Wire is the call as apps see it.
func (c *Call) Wire() protocol.Call {
	participants := make([]protocol.CallParticipant, 0, len(c.Participants))
	for _, p := range c.Participants {
		participants = append(participants, protocol.CallParticipant{User: p.User, Device: p.Device, JoinedAt: p.JoinedAt})
	}
	return protocol.Call{
		ID:            c.ID,
		Conv:          c.Conv,
		Direct:        c.Direct,
		Video:         c.Video,
		StartedBy:     c.StartedBy,
		StartedDevice: c.StartedDevice,
		StartedAt:     c.StartedAt,
		RingUntil:     c.RingUntil,
		AnsweredAt:    c.AnsweredAt,
		EndedAt:       c.EndedAt,
		Reason:        c.Reason,
		Version:       c.Version,
		Participants:  participants,
	}
}

const callColumns = `id, conv_id, direct, video, started_by, started_device, started_at, COALESCE(ring_until, 0),
	COALESCE(answered_at, 0), COALESCE(first_joined_at, 0), COALESCE(ended_at, 0), COALESCE(end_reason, ''), version`

// callsWhere returns the calls that where (a condition on calls) picks, with
// their participants, oldest first.
func callsWhere(ctx context.Context, q querier, where string, args ...any) ([]*Call, error) {
	rows, err := q.QueryContext(ctx, `SELECT `+callColumns+` FROM calls WHERE `+where+` ORDER BY started_at, id`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var calls []*Call
	byID := map[string]*Call{}
	for rows.Next() {
		c := &Call{}
		if err := rows.Scan(&c.ID, &c.Conv, &c.Direct, &c.Video, &c.StartedBy, &c.StartedDevice, &c.StartedAt, &c.RingUntil,
			&c.AnsweredAt, &c.FirstJoinedAt, &c.EndedAt, &c.Reason, &c.Version); err != nil {
			return nil, err
		}
		calls = append(calls, c)
		byID[c.ID] = c
	}
	if err := rows.Err(); err != nil || len(calls) == 0 {
		return calls, err
	}
	ids := make([]any, 0, len(calls))
	for _, c := range calls {
		ids = append(ids, c.ID)
	}
	rows, err = q.QueryContext(ctx, `SELECT call_id, user_id, device_id, sid, joined_at FROM call_participants
		WHERE call_id IN (?`+strings.Repeat(",?", len(ids)-1)+`) ORDER BY joined_at, device_id`, ids...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var p CallParticipant
		if err := rows.Scan(&id, &p.User, &p.Device, &p.SID, &p.JoinedAt); err != nil {
			return nil, err
		}
		byID[id].Participants = append(byID[id].Participants, p)
	}
	return calls, rows.Err()
}

func oneCall(calls []*Call, err error) (*Call, error) {
	if err != nil {
		return nil, err
	}
	if len(calls) == 0 {
		return nil, ErrNotFound
	}
	return calls[0], nil
}

// Call returns a call, ended or not.
func (tx *Tx) Call(id string) (*Call, error) {
	return oneCall(callsWhere(tx.ctx, tx.q, `id = ?`, id))
}

// ActiveCall returns the call going on in a conversation.
func (tx *Tx) ActiveCall(conv string) (*Call, error) {
	return oneCall(callsWhere(tx.ctx, tx.q, `active_conv = ?`, conv))
}

// ActiveCallsOf returns the calls going on that user has a device in.
func (tx *Tx) ActiveCallsOf(user string) ([]*Call, error) {
	return callsWhere(tx.ctx, tx.q,
		`ended_at IS NULL AND id IN (SELECT call_id FROM call_participants WHERE user_id = ?)`, user)
}

// InsertCall starts a call. A conversation that has one going on already
// gives a duplicate-key error (see IsDuplicate), as does an ID in use.
func (tx *Tx) InsertCall(c *Call) error {
	c.Version = 1
	_, err := tx.q.ExecContext(tx.ctx, `INSERT INTO calls (id, conv_id, direct, video, started_by, started_device,
		started_at, ring_until, version, active_conv) VALUES (?, ?, ?, ?, ?, ?, ?, NULLIF(?, 0), 1, ?)`,
		c.ID, c.Conv, c.Direct, c.Video, c.StartedBy, c.StartedDevice, c.StartedAt, c.RingUntil, c.Conv)
	return err
}

// SaveCall writes what changed about a call (when it was answered, joined
// or ended) and moves its version on.
func (tx *Tx) SaveCall(c *Call) error {
	_, err := tx.q.ExecContext(tx.ctx, `UPDATE calls SET ring_until = NULLIF(?, 0), answered_at = NULLIF(?, 0),
		first_joined_at = NULLIF(?, 0), ended_at = NULLIF(?, 0), end_reason = NULLIF(?, ''),
		active_conv = IF(? = 0, conv_id, NULL), version = version + 1
		WHERE id = ?`, c.RingUntil, c.AnsweredAt, c.FirstJoinedAt, c.EndedAt, c.Reason, c.EndedAt, c.ID)
	if err == nil {
		c.Version++
	}
	return err
}

// PutCallParticipant notes that a device is in a call, through the LiveKit
// connection p.SID (a newer one replaces an older one of the device).
func (tx *Tx) PutCallParticipant(call string, p CallParticipant) error {
	_, err := tx.q.ExecContext(tx.ctx, `INSERT INTO call_participants (call_id, device_id, user_id, sid, joined_at)
		VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE user_id = VALUES(user_id), sid = VALUES(sid),
		joined_at = VALUES(joined_at)`, call, p.Device, p.User, p.SID, p.JoinedAt)
	return err
}

// RemoveCallParticipant notes that a device left a call: through connection
// sid, or with sid "", whatever connection it had. It reports whether the
// device was in the call (with that connection).
func (tx *Tx) RemoveCallParticipant(call, device, sid string) (bool, error) {
	res, err := tx.q.ExecContext(tx.ctx, `DELETE FROM call_participants WHERE call_id = ? AND device_id = ?
		AND (? = '' OR sid = ?)`, call, device, sid, sid)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// CallsFor returns the calls of a user's conversations that are going on or
// ended at since or later.
func (s *Store) CallsFor(ctx context.Context, user string, since int64) ([]*Call, error) {
	return callsWhere(ctx, s.db, `conv_id IN (SELECT conv_id FROM members WHERE user_id = ?)
		AND (ended_at IS NULL OR ended_at >= ?)`, user, since)
}

// ActiveCalls returns every call going on.
func (s *Store) ActiveCalls(ctx context.Context) ([]*Call, error) {
	return callsWhere(ctx, s.db, `ended_at IS NULL`)
}

// PurgeCalls forgets calls that ended before a time.
func (s *Store) PurgeCalls(ctx context.Context, before int64) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM calls WHERE ended_at IS NOT NULL AND ended_at < ?`, before)
	return err
}
