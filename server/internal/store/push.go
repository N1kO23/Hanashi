package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

// PushSubscription is where a device wants to be woken (a Web Push
// endpoint), with the keys to encrypt for it. Keys are base64url; a
// subscription without them gets empty pushes.
type PushSubscription struct {
	DeviceID string
	UserID   string
	Endpoint string
	P256dh   string
	Auth     string
}

// PutPushSubscription replaces the device's subscription.
func (s *Store) PutPushSubscription(ctx context.Context, sub PushSubscription) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO push_subscriptions (device_id, user_id, endpoint, p256dh, auth, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE endpoint = VALUES(endpoint), p256dh = VALUES(p256dh), auth = VALUES(auth),
			updated_at = VALUES(updated_at)`,
		sub.DeviceID, sub.UserID, sub.Endpoint, nullable(sub.P256dh), nullable(sub.Auth), now())
	return err
}

// DeletePushSubscription removes the device's subscription. With a
// non-empty endpoint, only if it is still that one (a push service said it
// is gone, but the device may have registered a new one meanwhile).
func (s *Store) DeletePushSubscription(ctx context.Context, deviceID, endpoint string) error {
	query, args := `DELETE FROM push_subscriptions WHERE device_id = ?`, []any{deviceID}
	if endpoint != "" {
		query, args = query+` AND endpoint = ?`, append(args, endpoint)
	}
	_, err := s.db.ExecContext(ctx, query, args...)
	return err
}

// PushSubscriptions returns the subscriptions of all devices of userIDs.
func (s *Store) PushSubscriptions(ctx context.Context, userIDs []string) ([]PushSubscription, error) {
	if len(userIDs) == 0 {
		return nil, nil
	}
	args := make([]any, len(userIDs))
	for i, id := range userIDs {
		args[i] = id
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT device_id, user_id, endpoint, COALESCE(p256dh, ''), COALESCE(auth, '')
		FROM push_subscriptions WHERE user_id IN (?`+strings.Repeat(", ?", len(userIDs)-1)+`)`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PushSubscription
	for rows.Next() {
		var sub PushSubscription
		if err := rows.Scan(&sub.DeviceID, &sub.UserID, &sub.Endpoint, &sub.P256dh, &sub.Auth); err != nil {
			return nil, err
		}
		out = append(out, sub)
	}
	return out, rows.Err()
}

// ServerSecret returns the named secret, creating it with create the first
// time. Concurrent first calls agree on one value.
func (s *Store) ServerSecret(ctx context.Context, name string, create func() (string, error)) (string, error) {
	var value string
	err := s.db.QueryRowContext(ctx, `SELECT value FROM server_settings WHERE name = ?`, name).Scan(&value)
	if err == nil {
		return value, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	value, err = create()
	if err != nil {
		return "", err
	}
	if _, err := s.db.ExecContext(ctx, `INSERT IGNORE INTO server_settings (name, value) VALUES (?, ?)`, name, value); err != nil {
		return "", err
	}
	err = s.db.QueryRowContext(ctx, `SELECT value FROM server_settings WHERE name = ?`, name).Scan(&value)
	return value, err
}
