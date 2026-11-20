package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"hanashi/server/internal/protocol"
)

// ErrStaleIdentity: the request was made for an identity the user has
// since replaced.
var ErrStaleIdentity = errors.New("identity changed")

// AddKeyBackup stores encrypted message keys (message ID -> data) for
// userID and returns how many it accepted. An existing entry for a message
// is kept. Only messages of the user's conversations are accepted, and only
// for the current identity: a reset makes old backups unreadable, deletes
// them, and must not race with a device still uploading for the old one.
func (s *Store) AddKeyBackup(ctx context.Context, userID string, identityVersion int, entries map[string]string) (int, error) {
	if len(entries) == 0 {
		return 0, nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var version int
	// Locks the row an identity reset updates, so the two cannot interleave.
	err = tx.QueryRowContext(ctx, `SELECT identity_version FROM user_keys WHERE user_id = ? FOR UPDATE`, userID).Scan(&version)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && version != identityVersion) {
		return 0, ErrStaleIdentity
	} else if err != nil {
		return 0, err
	}
	args := []any{userID}
	for id := range entries {
		args = append(args, id)
	}
	rows, err := tx.QueryContext(ctx, `
		SELECT e.msg_id FROM events e JOIN members m ON m.conv_id = e.conv_id AND m.user_id = ?
		WHERE e.msg_id IN (?`+strings.Repeat(", ?", len(entries)-1)+`)`, args...)
	if err != nil {
		return 0, err
	}
	var visible []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, err
		}
		visible = append(visible, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	if len(visible) > 0 {
		values := make([]any, 0, 3*len(visible))
		for _, id := range visible {
			values = append(values, userID, id, entries[id])
		}
		if _, err := tx.ExecContext(ctx, `INSERT IGNORE INTO key_backup (user_id, msg_id, data) VALUES (?, ?, ?)`+
			strings.Repeat(", (?, ?, ?)", len(visible)-1), values...); err != nil {
			return 0, err
		}
	}
	return len(visible), tx.Commit()
}

// KeyBackup returns the user's backup entries for the given message IDs;
// messages without one are left out.
func (s *Store) KeyBackup(ctx context.Context, userID string, ids []string) (map[string]string, error) {
	out := map[string]string{}
	if len(ids) == 0 {
		return out, nil
	}
	args := []any{userID}
	for _, id := range ids {
		args = append(args, id)
	}
	rows, err := s.db.QueryContext(ctx, `SELECT msg_id, data FROM key_backup WHERE user_id = ? AND msg_id IN (?`+
		strings.Repeat(", ?", len(ids)-1)+`)`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id, data string
		if err := rows.Scan(&id, &data); err != nil {
			return nil, err
		}
		out[id] = data
	}
	return out, rows.Err()
}

// BackupEntry is one message's key backup entry, with where the message is.
type BackupEntry struct {
	ID   string `json:"id"`
	Seq  int64  `json:"seq"`
	Data string `json:"data"`
}

// ConversationKeyBackup returns the user's backup entries for the messages of
// convID after seq after, oldest first, at most limit.
func (s *Store) ConversationKeyBackup(ctx context.Context, userID, convID string, after int64, limit int) ([]BackupEntry, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT e.seq, e.msg_id, b.data FROM events e
		JOIN key_backup b ON b.user_id = ? AND b.msg_id = e.msg_id
		WHERE e.conv_id = ? AND e.type = ? AND e.seq > ?
		ORDER BY e.seq LIMIT ?`, userID, convID, protocol.EventMessage, after, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []BackupEntry{}
	for rows.Next() {
		var e BackupEntry
		if err := rows.Scan(&e.Seq, &e.ID, &e.Data); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// DeleteMessages removes the stored ciphertext of sender's own messages among
// ids, with everyone's key backup entries for them: they deleted them for
// everyone. Other ids are ignored. Returns how many were deleted, and the
// conversations they were in.
func (tx *Tx) DeleteMessages(sender string, ids []string) (int, []string, error) {
	if len(ids) == 0 {
		return 0, nil, nil
	}
	args := []any{protocol.EventMessage, sender}
	for _, id := range ids {
		args = append(args, id)
	}
	rows, err := tx.q.QueryContext(tx.ctx, `
		SELECT msg_id, conv_id FROM events WHERE type = ? AND sender = ?
		AND msg_id IN (?`+strings.Repeat(", ?", len(ids)-1)+`) FOR UPDATE`, args...)
	if err != nil {
		return 0, nil, err
	}
	var own, convs []string
	for rows.Next() {
		var id, conv string
		if err := rows.Scan(&id, &conv); err != nil {
			rows.Close()
			return 0, nil, err
		}
		own = append(own, id)
		if !contains(convs, conv) {
			convs = append(convs, conv)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil || len(own) == 0 {
		return 0, nil, err
	}
	in := "?" + strings.Repeat(", ?", len(own)-1)
	ownArgs := make([]any, len(own))
	for i, id := range own {
		ownArgs[i] = id
	}
	if _, err := tx.q.ExecContext(tx.ctx, `DELETE FROM events WHERE msg_id IN (`+in+`)`, ownArgs...); err != nil {
		return 0, nil, err
	}
	if _, err := tx.q.ExecContext(tx.ctx, `DELETE FROM key_backup WHERE msg_id IN (`+in+`)`, ownArgs...); err != nil {
		return 0, nil, err
	}
	return len(own), convs, nil
}
