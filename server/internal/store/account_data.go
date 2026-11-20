package store

import (
	"context"
	"database/sql"
	"errors"
)

// Account data: small blobs that a user's devices share, such as the user's
// own profile picture. Encrypted by the clients; the server cannot read them.

// ErrVersionConflict: the blob changed since the caller read it.
var ErrVersionConflict = errors.New("version conflict")

// AccountData returns a blob and its version, which only ever goes up.
func (s *Store) AccountData(ctx context.Context, userID, name string) (string, int64, error) {
	var data string
	var version int64
	err := s.db.QueryRowContext(ctx, `SELECT data, version FROM account_data WHERE user_id = ? AND name = ?`, userID, name).
		Scan(&data, &version)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, ErrNotFound
	}
	return data, version, err
}

// PutAccountData replaces a blob if it is still at version (0: there is none
// yet), so that two devices changing it at once cannot lose either's change.
// It returns the new version.
func (s *Store) PutAccountData(ctx context.Context, userID, name, data string, version int64) (int64, error) {
	if version == 0 {
		_, err := s.db.ExecContext(ctx,
			`INSERT INTO account_data (user_id, name, data, version, updated_at) VALUES (?, ?, ?, 1, ?)`,
			userID, name, data, now())
		if IsDuplicate(err) {
			return 0, ErrVersionConflict
		}
		return 1, err
	}
	res, err := s.db.ExecContext(ctx, `
		UPDATE account_data SET data = ?, version = version + 1, updated_at = ?
		WHERE user_id = ? AND name = ? AND version = ?`, data, now(), userID, name, version)
	if err != nil {
		return 0, err
	}
	if n, err := res.RowsAffected(); err != nil {
		return 0, err
	} else if n == 0 {
		return 0, ErrVersionConflict
	}
	return version + 1, nil
}
