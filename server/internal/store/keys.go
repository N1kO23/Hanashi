package store

import (
	"context"
	"database/sql"
	"errors"
)

// UserKeys is a user's public identity key (base64 Ed25519). The version
// increases whenever the user resets their encryption identity.
type UserKeys struct {
	IdentityKey     string
	IdentityVersion int
}

func (s *Store) UserKeys(ctx context.Context, userID string) (*UserKeys, error) {
	return userKeys(ctx, s.db, userID)
}

func (tx *Tx) UserKeys(userID string) (*UserKeys, error) { return userKeys(tx.ctx, tx.q, userID) }

func userKeys(ctx context.Context, q querier, userID string) (*UserKeys, error) {
	var k UserKeys
	err := q.QueryRowContext(ctx, `SELECT identity_key, identity_version FROM user_keys WHERE user_id = ?`, userID).
		Scan(&k.IdentityKey, &k.IdentityVersion)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return &k, err
}

func (tx *Tx) SetIdentity(userID, identityKey string, version int) error {
	_, err := tx.q.ExecContext(tx.ctx,
		`INSERT INTO user_keys (user_id, identity_key, identity_version, updated_at) VALUES (?, ?, ?, ?)
		 ON DUPLICATE KEY UPDATE identity_key = VALUES(identity_key), identity_version = VALUES(identity_version),
		 updated_at = VALUES(updated_at)`, userID, identityKey, version, now())
	return err
}

// ResetIdentityState forgets everything signed by or encrypted for a user's
// previous identity: device signatures and secret storage.
func (tx *Tx) ResetIdentityState(userID string) error {
	if _, err := tx.q.ExecContext(tx.ctx,
		`UPDATE device_keys SET signature = NULL, signed_version = NULL WHERE user_id = ?`, userID); err != nil {
		return err
	}
	if _, err := tx.q.ExecContext(tx.ctx, `DELETE FROM secret_storage WHERE user_id = ?`, userID); err != nil {
		return err
	}
	// Encrypted with the old backup secret: nobody can read them any more.
	if _, err := tx.q.ExecContext(tx.ctx, `DELETE FROM key_backup WHERE user_id = ?`, userID); err != nil {
		return err
	}
	if _, err := tx.q.ExecContext(tx.ctx, `DELETE FROM account_data WHERE user_id = ?`, userID); err != nil {
		return err
	}
	// Signed with the old identity key: they no longer check out.
	_, err := tx.q.ExecContext(tx.ctx, `DELETE FROM trust_attestations WHERE signer_user = ?`, userID)
	return err
}

// DeviceKey is a device's MLS signature key (base64 Ed25519) and, once the
// device is verified, its record's signature by the user's identity key.
type DeviceKey struct {
	DeviceID      string
	UserID        string
	MLSSigKey     string
	Signature     *string
	SignedVersion *int
}

func scanDeviceKey(scan func(...any) error) (*DeviceKey, error) {
	var d DeviceKey
	var sig sql.NullString
	var version sql.NullInt64
	if err := scan(&d.DeviceID, &d.UserID, &d.MLSSigKey, &sig, &version); err != nil {
		return nil, err
	}
	if sig.Valid {
		d.Signature = &sig.String
	}
	if version.Valid {
		v := int(version.Int64)
		d.SignedVersion = &v
	}
	return &d, nil
}

const deviceKeyColumns = `device_id, user_id, mls_sig_key, signature, signed_version`

func (s *Store) DeviceKeysOf(ctx context.Context, userID string) ([]DeviceKey, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT `+deviceKeyColumns+` FROM device_keys WHERE user_id = ? ORDER BY created_at, device_id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DeviceKey{}
	for rows.Next() {
		d, err := scanDeviceKey(rows.Scan)
		if err != nil {
			return nil, err
		}
		out = append(out, *d)
	}
	return out, rows.Err()
}

func (tx *Tx) DeviceKey(deviceID string) (*DeviceKey, error) {
	d, err := scanDeviceKey(tx.q.QueryRowContext(tx.ctx,
		`SELECT `+deviceKeyColumns+` FROM device_keys WHERE device_id = ?`, deviceID).Scan)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return d, err
}

func (tx *Tx) InsertDeviceKey(deviceID, userID, mlsSigKey string) error {
	_, err := tx.q.ExecContext(tx.ctx,
		`INSERT INTO device_keys (device_id, user_id, mls_sig_key, created_at) VALUES (?, ?, ?, ?)`,
		deviceID, userID, mlsSigKey, now())
	return err
}

func (tx *Tx) SetDeviceSignature(deviceID, signature string, version int) error {
	_, err := tx.q.ExecContext(tx.ctx,
		`UPDATE device_keys SET signature = ?, signed_version = ? WHERE device_id = ?`, signature, version, deviceID)
	return err
}

// SecretStorage returns the user's encrypted secret storage blob.
func (s *Store) SecretStorage(ctx context.Context, userID string) (data string, identityVersion int, err error) {
	err = s.db.QueryRowContext(ctx, `SELECT data, identity_version FROM secret_storage WHERE user_id = ?`, userID).
		Scan(&data, &identityVersion)
	if errors.Is(err, sql.ErrNoRows) {
		err = ErrNotFound
	}
	return data, identityVersion, err
}

func (tx *Tx) PutSecretStorage(userID, data string, identityVersion int) error {
	_, err := tx.q.ExecContext(tx.ctx,
		`INSERT INTO secret_storage (user_id, data, identity_version, updated_at) VALUES (?, ?, ?, ?)
		 ON DUPLICATE KEY UPDATE data = VALUES(data), identity_version = VALUES(identity_version),
		 updated_at = VALUES(updated_at)`, userID, data, identityVersion, now())
	return err
}

// ConversationPeers returns the user and everyone sharing a conversation with them:
// the people who must hear about the user's key changes.
func (tx *Tx) ConversationPeers(userID string) ([]string, error) {
	return strings0(tx.q.QueryContext(tx.ctx, conversationPeersQuery, userID, userID))
}

// ConversationPeersOf is [Tx.ConversationPeers] outside the event-append section.
func (s *Store) ConversationPeersOf(ctx context.Context, userID string) ([]string, error) {
	return strings0(s.db.QueryContext(ctx, conversationPeersQuery, userID, userID))
}

const conversationPeersQuery = `
	SELECT DISTINCT m2.user_id FROM members m1 JOIN members m2 ON m2.conv_id = m1.conv_id
	WHERE m1.user_id = ?
	UNION SELECT ?`
