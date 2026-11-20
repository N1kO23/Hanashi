package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
)

// Users of other servers

// EnsureRemoteUser gives a user of another server a row, with no password:
// they can never sign in here (sign-in takes names of this server's host),
// and everything that names users can name them.
func (s *Store) EnsureRemoteUser(ctx context.Context, userID string) error {
	return ensureRemoteUser(ctx, s.db, userID)
}

func (tx *Tx) EnsureRemoteUser(userID string) error { return ensureRemoteUser(tx.ctx, tx.q, userID) }

func ensureRemoteUser(ctx context.Context, q querier, userID string) error {
	_, err := q.ExecContext(ctx, `INSERT IGNORE INTO users (id, password_hash, created_at) VALUES (?, '', ?)`,
		userID, now())
	return err
}

// SetRemoteDevices records which devices a user of another server has, as
// their server last said.
func (s *Store) SetRemoteDevices(ctx context.Context, userID string, deviceIDs []string) error {
	sqlTx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer sqlTx.Rollback()
	if _, err := sqlTx.ExecContext(ctx, `DELETE FROM remote_devices WHERE user_id = ?`, userID); err != nil {
		return err
	}
	for _, id := range deviceIDs {
		// A device ID taken by another user (of here, or of another server)
		// stays theirs.
		if _, err := sqlTx.ExecContext(ctx,
			`INSERT IGNORE INTO remote_devices (device_id, user_id, updated_at) VALUES (?, ?, ?)`,
			id, userID, now()); err != nil {
			return err
		}
	}
	return sqlTx.Commit()
}

// RemoteDeviceOwner is the user of another server a device belongs to.
func (s *Store) RemoteDeviceOwner(ctx context.Context, deviceID string) (string, error) {
	return remoteDeviceOwner(ctx, s.db, deviceID)
}

func (tx *Tx) RemoteDeviceOwner(deviceID string) (string, error) {
	return remoteDeviceOwner(tx.ctx, tx.q, deviceID)
}

func remoteDeviceOwner(ctx context.Context, q querier, deviceID string) (string, error) {
	var owner string
	err := q.QueryRowContext(ctx, `SELECT user_id FROM remote_devices WHERE device_id = ?`, deviceID).Scan(&owner)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return owner, err
}

// RequestsFrom counts the unanswered requests of users of host.
func (tx *Tx) RequestsFrom(host string) (int, error) {
	var n int
	err := tx.q.QueryRowContext(tx.ctx, `SELECT COUNT(*) FROM contacts WHERE owner LIKE ? AND state = ?`,
		"%@"+host, ContactRequested).Scan(&n)
	return n, err
}

// RemoteContactHosts lists the other servers whose users are contacts of
// userID.
func (tx *Tx) RemoteContactHosts(userID, ownHost string) ([]string, error) {
	peers, err := strings0(tx.q.QueryContext(tx.ctx, `SELECT peer FROM contacts WHERE owner = ? AND state = ?`,
		userID, ContactAccepted))
	if err != nil {
		return nil, err
	}
	var hosts []string
	for _, peer := range peers {
		host := peer[strings.LastIndex(peer, "@")+1:]
		if host != ownHost && !contains(hosts, host) {
			hosts = append(hosts, host)
		}
	}
	return hosts, nil
}

// ContactsOfRemoteUser lists the users of this server who are contacts of a
// user of another server.
func (tx *Tx) ContactsOfRemoteUser(userID string) ([]string, error) {
	return strings0(tx.q.QueryContext(tx.ctx, `SELECT owner FROM contacts WHERE peer = ? AND state = ?`,
		userID, ContactAccepted))
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// The outgoing queue

// QueuedItem is one item on its way to another server.
type QueuedItem struct {
	ID        int64
	Item      string
	CreatedAt int64
}

// QueueFederationItem puts an item on its way to destination, in the same
// transaction as the change it tells of.
func (tx *Tx) QueueFederationItem(destination, item string) error {
	_, err := tx.q.ExecContext(tx.ctx,
		`INSERT INTO federation_queue (destination, item, created_at) VALUES (?, ?, ?)`, destination, item, now())
	return err
}

// FederationDestinations lists the servers with items waiting.
func (s *Store) FederationDestinations(ctx context.Context) ([]string, error) {
	return strings0(s.db.QueryContext(ctx, `SELECT DISTINCT destination FROM federation_queue`))
}

// FederationItems are the first items waiting for destination, oldest first,
// at most limit of them and about maxBytes.
func (s *Store) FederationItems(ctx context.Context, destination string, limit, maxBytes int) ([]QueuedItem, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, item, created_at FROM federation_queue WHERE destination = ? ORDER BY id LIMIT ?`,
		destination, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []QueuedItem
	size := 0
	for rows.Next() {
		var item QueuedItem
		if err := rows.Scan(&item.ID, &item.Item, &item.CreatedAt); err != nil {
			return nil, err
		}
		if size += len(item.Item); len(out) > 0 && size > maxBytes {
			break
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

// DropFederationItems forgets destination's items up to and including upTo,
// once it has them.
func (s *Store) DropFederationItems(ctx context.Context, destination string, upTo int64) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM federation_queue WHERE destination = ? AND id <= ?`, destination, upTo)
	return err
}

// ExpireFederationItems drops destination's items made before before; how
// many there were.
func (s *Store) ExpireFederationItems(ctx context.Context, destination string, before int64) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM federation_queue WHERE destination = ? AND created_at < ?`,
		destination, before)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// FederationServer is how sending to another server goes.
type FederationServer struct {
	NextAttempt int64
	Failures    int
	LastError   string
}

func (s *Store) FederationServer(ctx context.Context, host string) (FederationServer, error) {
	var f FederationServer
	var lastError sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT next_attempt, failures, last_error FROM federation_servers WHERE host = ?`,
		host).Scan(&f.NextAttempt, &f.Failures, &lastError)
	if errors.Is(err, sql.ErrNoRows) {
		return FederationServer{}, nil
	}
	f.LastError = lastError.String
	return f, err
}

func (s *Store) SetFederationServer(ctx context.Context, host string, f FederationServer) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO federation_servers (host, next_attempt, failures, last_error, updated_at) VALUES (?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE next_attempt = VALUES(next_attempt), failures = VALUES(failures),
		last_error = VALUES(last_error), updated_at = VALUES(updated_at)`,
		host, f.NextAttempt, f.Failures, nullable(f.LastError), now())
	return err
}

// Incoming items

// FederationCursor is the last item applied of origin's stream ("" and 0 if
// none was).
func (tx *Tx) FederationCursor(origin string) (stream string, last int64, err error) {
	err = tx.q.QueryRowContext(tx.ctx, `SELECT stream, last_item FROM federation_inbound WHERE origin = ?`, origin).
		Scan(&stream, &last)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, nil
	}
	return stream, last, err
}

func (tx *Tx) SetFederationCursor(origin, stream string, last int64) error {
	_, err := tx.q.ExecContext(tx.ctx, `
		INSERT INTO federation_inbound (origin, stream, last_item, updated_at) VALUES (?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE stream = VALUES(stream), last_item = VALUES(last_item), updated_at = VALUES(updated_at)`,
		origin, stream, last, now())
	return err
}

// Conversations another server orders

// ConversationHub is the server that orders a conversation ("" for this one),
// and the last of its events this one has.
func (s *Store) ConversationHub(ctx context.Context, conv string) (string, int64, error) {
	return conversationHub(ctx, s.db, conv)
}

func (tx *Tx) ConversationHub(conv string) (string, int64, error) {
	return conversationHub(tx.ctx, tx.q, conv)
}

func conversationHub(ctx context.Context, q querier, conv string) (string, int64, error) {
	var hub sql.NullString
	var seq int64
	err := q.QueryRowContext(ctx, `SELECT hub, hub_seq FROM conversations WHERE id = ?`, conv).Scan(&hub, &seq)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, ErrNotFound
	}
	return hub.String, seq, err
}

// CreateMirror stores a conversation that hub orders, as it says it is.
func (tx *Tx) CreateMirror(id, hub, createdBy string, members []string, directKey *string, epoch int64) error {
	if _, err := tx.q.ExecContext(tx.ctx, `
		INSERT INTO conversations (id, direct_key, created_by, created_at, epoch, hub) VALUES (?, ?, ?, ?, ?, ?)`,
		id, directKey, createdBy, now(), epoch, hub); err != nil {
		return err
	}
	for _, m := range members {
		if err := tx.AddMember(id, m); err != nil {
			return err
		}
	}
	return nil
}

// SetHubSeq notes the last of the hub's events a mirrored conversation has.
func (tx *Tx) SetHubSeq(conv string, seq int64) error {
	_, err := tx.q.ExecContext(tx.ctx, `UPDATE conversations SET hub_seq = ? WHERE id = ?`, seq, conv)
	return err
}

// SeqOfHubEvent is the seq here of the hub's event hubSeq of conv.
func (s *Store) SeqOfHubEvent(ctx context.Context, conv string, hubSeq int64) (int64, error) {
	var seq int64
	err := s.db.QueryRowContext(ctx, `SELECT seq FROM events WHERE conv_id = ? AND hub_seq = ?`, conv, hubSeq).Scan(&seq)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	return seq, err
}

// PreviousConvEvent is the seq of conv's last event that its members see,
// before seq (0 if none).
func (tx *Tx) PreviousConvEvent(conv string, seq int64) (int64, error) {
	var prev int64
	err := tx.q.QueryRowContext(tx.ctx, `
		SELECT COALESCE(MAX(seq), 0) FROM events WHERE conv_id = ? AND target_user IS NULL AND seq < ?`,
		conv, seq).Scan(&prev)
	return prev, err
}

// ConvEvent is an event of a conversation as another server is told of it.
type ConvEvent struct {
	Seq           int64
	Type          string
	TS            int64
	Data          json.RawMessage
	MsgID, Sender string
}

// ConvEventsSince lists conv's events its members see after since, oldest
// first, at most limit.
func (s *Store) ConvEventsSince(ctx context.Context, conv string, since int64, limit int) ([]ConvEvent, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT seq, type, ts, payload, msg_id, sender FROM events
		WHERE conv_id = ? AND target_user IS NULL AND seq > ? ORDER BY seq LIMIT ?`, conv, since, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ConvEvent{}
	for rows.Next() {
		var e ConvEvent
		var payload string
		var msgID, sender sql.NullString
		if err := rows.Scan(&e.Seq, &e.Type, &e.TS, &payload, &msgID, &sender); err != nil {
			return nil, err
		}
		e.Data, e.MsgID, e.Sender = json.RawMessage(payload), msgID.String, sender.String
		out = append(out, e)
	}
	return out, rows.Err()
}

// RemoteMemberHosts lists the other servers whose users are members of conv.
func (tx *Tx) RemoteMemberHosts(conv, ownHost string) ([]string, error) {
	return remoteMemberHosts(tx.ctx, tx.q, conv, ownHost)
}

func (s *Store) RemoteMemberHosts(ctx context.Context, conv, ownHost string) ([]string, error) {
	return remoteMemberHosts(ctx, s.db, conv, ownHost)
}

func remoteMemberHosts(ctx context.Context, q querier, conv, ownHost string) ([]string, error) {
	members, err := memberIDs(ctx, q, conv)
	if err != nil {
		return nil, err
	}
	var hosts []string
	for _, m := range members {
		host := m[strings.LastIndex(m, "@")+1:]
		if host != ownHost && !contains(hosts, host) {
			hosts = append(hosts, host)
		}
	}
	return hosts, nil
}

// HasContactOn reports whether user has an accepted contact of host.
func (tx *Tx) HasContactOn(user, host string) (bool, error) {
	var one int
	err := tx.q.QueryRowContext(tx.ctx, `SELECT 1 FROM contacts WHERE owner = ? AND state = ? AND peer LIKE ? LIMIT 1`,
		user, ContactAccepted, "%@"+host).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// SessionIDs lists the devices of a user of this server.
func (tx *Tx) SessionIDs(user string) ([]string, error) {
	return strings0(tx.q.QueryContext(tx.ctx, `SELECT id FROM sessions WHERE user_id = ? ORDER BY id`, user))
}

// HistoryOnly is the target user of an event a copy keeps as history only:
// from before any of this server's users were in the conversation, it is
// read with the history, never sent to anyone as new.
const HistoryOnly = "~history"

// IsContact reports whether user has accepted other as a contact.
func (s *Store) IsContact(ctx context.Context, user, other string) (bool, error) {
	state, err := contactState(ctx, s.db, user, other)
	return state == ContactAccepted, err
}
