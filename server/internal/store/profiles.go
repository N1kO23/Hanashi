package store

import (
	"context"
	"database/sql"
	"errors"
)

// Profile is a user's signed profile record, opaque to the server.
type Profile struct {
	Version       int64
	CT, Signature string
}

func (s *Store) Profile(ctx context.Context, userID string) (*Profile, error) {
	var p Profile
	err := s.db.QueryRowContext(ctx, `SELECT version, ct, signature FROM profiles WHERE user_id = ?`, userID).
		Scan(&p.Version, &p.CT, &p.Signature)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return &p, err
}

// PutProfile replaces a user's record with a newer one; whether it was newer.
func (tx *Tx) PutProfile(userID string, p Profile) (bool, error) {
	res, err := tx.q.ExecContext(tx.ctx, `
		UPDATE profiles SET version = ?, ct = ?, signature = ?, updated_at = ? WHERE user_id = ? AND version < ?`,
		p.Version, p.CT, p.Signature, now(), userID, p.Version)
	if err != nil {
		return false, err
	}
	if n, err := res.RowsAffected(); err != nil {
		return false, err
	} else if n > 0 {
		return true, nil
	}
	_, err = tx.q.ExecContext(tx.ctx,
		`INSERT INTO profiles (user_id, version, ct, signature, updated_at) VALUES (?, ?, ?, ?, ?)`,
		userID, p.Version, p.CT, p.Signature, now())
	if IsDuplicate(err) {
		return false, nil
	}
	return err == nil, err
}
