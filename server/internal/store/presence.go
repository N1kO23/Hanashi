package store

import (
	"context"
	"database/sql"
	"errors"

	"hanashi/server/internal/protocol"
)

// PresenceMode returns how the user chose to appear (see protocol.ModeAuto).
func (s *Store) PresenceMode(ctx context.Context, userID string) (string, error) {
	var mode string
	err := s.db.QueryRowContext(ctx, `SELECT presence_mode FROM users WHERE id = ?`, userID).Scan(&mode)
	if errors.Is(err, sql.ErrNoRows) {
		return protocol.ModeAuto, nil
	}
	return mode, err
}

func (s *Store) SetPresenceMode(ctx context.Context, userID, mode string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE users SET presence_mode = ? WHERE id = ?`, mode, userID)
	return err
}
