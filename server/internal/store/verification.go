package store

import (
	"context"
	"database/sql"
	"errors"
)

// SharesConversation reports whether two users are in a conversation together.
func (s *Store) SharesConversation(ctx context.Context, a, b string) (bool, error) {
	return sharesConversation(ctx, s.db, a, b)
}

func (tx *Tx) SharesConversation(a, b string) (bool, error) {
	return sharesConversation(tx.ctx, tx.q, a, b)
}

func sharesConversation(ctx context.Context, q querier, a, b string) (bool, error) {
	var one int
	err := q.QueryRowContext(ctx, `
		SELECT 1 FROM members m1 JOIN members m2 ON m1.conv_id = m2.conv_id
		WHERE m1.user_id = ? AND m2.user_id = ? LIMIT 1`, a, b).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// AddInboxItems puts the same item into several devices' inboxes.
func (s *Store) AddInboxItems(ctx context.Context, deviceIDs []string, item InboxItem) ([]InboxItem, error) {
	sqlTx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer sqlTx.Rollback()
	tx := &Tx{q: sqlTx, ctx: ctx}
	out := make([]InboxItem, 0, len(deviceIDs))
	for _, device := range deviceIDs {
		added, err := tx.AddInboxItem(device, item)
		if err != nil {
			return nil, err
		}
		out = append(out, added)
	}
	return out, sqlTx.Commit()
}

// PutAttestation stores signer's statement about target (opaque to the server).
func (s *Store) PutAttestation(ctx context.Context, signer, target, data string) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO trust_attestations (signer_user, target_user, data, updated_at) VALUES (?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE data = VALUES(data), updated_at = VALUES(updated_at)`, signer, target, data, now())
	return err
}

// Attestations returns signer's statements by target user.
func (s *Store) Attestations(ctx context.Context, signer string) (map[string]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT target_user, data FROM trust_attestations WHERE signer_user = ?`, signer)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var target, data string
		if err := rows.Scan(&target, &data); err != nil {
			return nil, err
		}
		out[target] = data
	}
	return out, rows.Err()
}
