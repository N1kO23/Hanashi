package store

import (
	"context"
	"database/sql"
	"errors"
)

// Conversation MLS state

func (tx *Tx) ConversationEpoch(convID string) (int64, error) {
	var epoch int64
	err := tx.q.QueryRowContext(tx.ctx, `SELECT epoch FROM conversations WHERE id = ?`, convID).Scan(&epoch)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	return epoch, err
}

func (tx *Tx) SetConversationEpoch(convID string, epoch int64) error {
	_, err := tx.q.ExecContext(tx.ctx, `UPDATE conversations SET epoch = ? WHERE id = ?`, epoch, convID)
	return err
}

// GroupInfo is the latest MLS GroupInfo (base64), which new devices use to
// join by external commit.
type GroupInfo struct {
	Epoch int64
	Data  string
	// State is the group's state sealed for Epoch (opaque, base64); empty until
	// some member has sealed it.
	State string
}

func (s *Store) GroupInfo(ctx context.Context, convID string) (*GroupInfo, error) {
	return groupInfo(ctx, s.db, convID)
}

func (tx *Tx) GroupInfo(convID string) (*GroupInfo, error) { return groupInfo(tx.ctx, tx.q, convID) }

func groupInfo(ctx context.Context, q querier, convID string) (*GroupInfo, error) {
	var g GroupInfo
	var state sql.NullString
	err := q.QueryRowContext(ctx, `SELECT epoch, data, state FROM group_info WHERE conv_id = ?`, convID).
		Scan(&g.Epoch, &g.Data, &state)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	g.State = state.String
	return &g, err
}

// PutGroupInfo stores the GroupInfo of a new epoch, and the group's state
// sealed for it if the commit came with it ("" otherwise).
func (tx *Tx) PutGroupInfo(convID string, epoch int64, data, state string) error {
	_, err := tx.q.ExecContext(tx.ctx,
		`INSERT INTO group_info (conv_id, epoch, data, state, updated_at) VALUES (?, ?, ?, ?, ?)
		 ON DUPLICATE KEY UPDATE epoch = VALUES(epoch), data = VALUES(data), state = VALUES(state),
		 updated_at = VALUES(updated_at)`,
		convID, epoch, data, nullable(state), now())
	return err
}

// PutGroupState stores the state sealed for the current epoch if it has none
// yet; whether it did.
func (tx *Tx) PutGroupState(convID string, state string) (bool, error) {
	res, err := tx.q.ExecContext(tx.ctx,
		`UPDATE group_info SET state = ?, updated_at = ? WHERE conv_id = ? AND state IS NULL`, state, now(), convID)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// Commit leases

type Lease struct {
	ID        string
	DeviceID  string
	ExpiresAt int64
}

func (tx *Tx) Lease(convID string) (*Lease, error) {
	var l Lease
	err := tx.q.QueryRowContext(tx.ctx, `SELECT lease_id, device_id, expires_at FROM commit_leases WHERE conv_id = ?`, convID).
		Scan(&l.ID, &l.DeviceID, &l.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return &l, err
}

func (tx *Tx) PutLease(convID string, l Lease) error {
	_, err := tx.q.ExecContext(tx.ctx,
		`INSERT INTO commit_leases (conv_id, lease_id, device_id, expires_at) VALUES (?, ?, ?, ?)
		 ON DUPLICATE KEY UPDATE lease_id = VALUES(lease_id), device_id = VALUES(device_id), expires_at = VALUES(expires_at)`,
		convID, l.ID, l.DeviceID, l.ExpiresAt)
	return err
}

func (tx *Tx) DeleteLease(convID string) error {
	_, err := tx.q.ExecContext(tx.ctx, `DELETE FROM commit_leases WHERE conv_id = ?`, convID)
	return err
}

// ReleaseLease deletes the lease if it is still the one deviceID was given
// and reports whether it was; otherwise (expired, renewed or used up) there
// is nothing to do.
func (s *Store) ReleaseLease(ctx context.Context, convID, leaseID, deviceID string) (bool, error) {
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM commit_leases WHERE conv_id = ? AND lease_id = ? AND device_id = ?`, convID, leaseID, deviceID)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// Device inbox

// InboxItem is addressed to one device; it is deleted once acknowledged.
type InboxItem struct {
	ID           int64  `json:"id"`
	Type         string `json:"type"`
	SenderUser   string `json:"fromUser"`
	SenderDevice string `json:"fromDevice"`
	Payload      string `json:"-"`
	CreatedAt    int64  `json:"createdAt"`
}

func (tx *Tx) AddInboxItem(deviceID string, item InboxItem) (InboxItem, error) {
	item.CreatedAt = now()
	res, err := tx.q.ExecContext(tx.ctx,
		`INSERT INTO device_inbox (device_id, sender_user, sender_device, type, payload, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		deviceID, item.SenderUser, item.SenderDevice, item.Type, item.Payload, item.CreatedAt)
	if err != nil {
		return item, err
	}
	item.ID, err = res.LastInsertId()
	return item, err
}

func (s *Store) Inbox(ctx context.Context, deviceID string, limit int) ([]InboxItem, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, type, sender_user, sender_device, payload, created_at FROM device_inbox
		 WHERE device_id = ? ORDER BY id LIMIT ?`, deviceID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []InboxItem{}
	for rows.Next() {
		var i InboxItem
		if err := rows.Scan(&i.ID, &i.Type, &i.SenderUser, &i.SenderDevice, &i.Payload, &i.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, i)
	}
	return out, rows.Err()
}

func (s *Store) AckInbox(ctx context.Context, deviceID string, ids []int64) error {
	for _, id := range ids {
		if _, err := s.db.ExecContext(ctx, `DELETE FROM device_inbox WHERE device_id = ? AND id = ?`, deviceID, id); err != nil {
			return err
		}
	}
	return nil
}

// SessionOwner returns the user a device (session) belongs to.
func (s *Store) SessionOwner(ctx context.Context, deviceID string) (string, error) {
	return sessionOwner(ctx, s.db, deviceID)
}

func (tx *Tx) SessionOwner(deviceID string) (string, error) {
	return sessionOwner(tx.ctx, tx.q, deviceID)
}

func sessionOwner(ctx context.Context, q querier, deviceID string) (string, error) {
	var userID string
	err := q.QueryRowContext(ctx, `SELECT user_id FROM sessions WHERE id = ?`, deviceID).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return userID, err
}

// Key packages

func (s *Store) AddKeyPackages(ctx context.Context, deviceID string, packages []string, lastResort string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, p := range packages {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO key_packages (device_id, data, last_resort, created_at) VALUES (?, ?, FALSE, ?)`,
			deviceID, p, now()); err != nil {
			return err
		}
	}
	if lastResort != "" {
		if _, err := tx.ExecContext(ctx, `DELETE FROM key_packages WHERE device_id = ? AND last_resort`, deviceID); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO key_packages (device_id, data, last_resort, created_at) VALUES (?, ?, TRUE, ?)`,
			deviceID, lastResort, now()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// KeyPackageCount reports a device's unclaimed one-time key packages and
// whether it has a last-resort package.
func (s *Store) KeyPackageCount(ctx context.Context, deviceID string) (count int, lastResort bool, err error) {
	err = s.db.QueryRowContext(ctx,
		`SELECT COALESCE(SUM(NOT last_resort), 0), COALESCE(MAX(last_resort), FALSE) FROM key_packages WHERE device_id = ?`,
		deviceID).Scan(&count, &lastResort)
	return count, lastResort, err
}

// ClaimKeyPackage hands out (and deletes) a device's oldest one-time key
// package, falling back to its last-resort package, which is kept.
func (s *Store) ClaimKeyPackage(ctx context.Context, deviceID string) (string, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var id int64
	var data string
	var lastResort bool
	err = tx.QueryRowContext(ctx,
		`SELECT id, data, last_resort FROM key_packages WHERE device_id = ? ORDER BY last_resort, id LIMIT 1 FOR UPDATE`,
		deviceID).Scan(&id, &data, &lastResort)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	} else if err != nil {
		return "", err
	}
	if !lastResort {
		if _, err := tx.ExecContext(ctx, `DELETE FROM key_packages WHERE id = ?`, id); err != nil {
			return "", err
		}
	}
	return data, tx.Commit()
}
