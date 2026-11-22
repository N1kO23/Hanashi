// Package store keeps all server state in MariaDB.
//
// Every syncable change is appended to `events`, whose AUTO_INCREMENT `seq`
// is the global sync cursor. An event with `target_user` set is visible only
// to that user; otherwise it is visible to the conversation's current members.
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"

	"hanashi/server/internal/protocol"
)

var ErrNotFound = errors.New("not found")

type Store struct {
	db *sql.DB

	// appendMu serializes every transaction that appends events. Seqs come
	// from AUTO_INCREMENT; without this, concurrent transactions could commit
	// seq 11 before seq 10, a device could sync past 10 and never see it.
	// This assumes one server process per database.
	appendMu sync.Mutex
}

// Open connects to MariaDB (retrying for up to wait, since the database
// container may still be starting), optionally creates the database, and
// applies migrations.
func Open(ctx context.Context, dsn string, create bool, wait time.Duration) (*Store, error) {
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		return nil, fmt.Errorf("invalid HANASHI_DB_DSN: %w", err)
	}
	if cfg.DBName == "" {
		return nil, errors.New("HANASHI_DB_DSN must name a database")
	}
	cfg.Collation = "utf8mb4_bin"
	cfg.Loc = time.UTC

	if create {
		admin := cfg.Clone()
		admin.DBName = ""
		if err := withRetry(ctx, wait, func() error {
			db, err := sql.Open("mysql", admin.FormatDSN())
			if err != nil {
				return err
			}
			defer db.Close()
			_, err = db.ExecContext(ctx, "CREATE DATABASE IF NOT EXISTS `"+strings.ReplaceAll(cfg.DBName, "`", "")+
				"` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
			return err
		}); err != nil {
			return nil, fmt.Errorf("creating database: %w", err)
		}
	}

	db, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(20)
	db.SetConnMaxLifetime(5 * time.Minute)
	if err := withRetry(ctx, wait, func() error { return db.PingContext(ctx) }); err != nil {
		db.Close()
		return nil, fmt.Errorf("connecting to the database: %w", err)
	}
	s := &Store{db: db}
	if err := s.refuseOldDatabase(ctx); err != nil {
		db.Close()
		return nil, err
	}
	if err := s.migrate(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrating the database: %w", err)
	}
	return s, nil
}

func withRetry(ctx context.Context, wait time.Duration, fn func() error) error {
	deadline := time.Now().Add(wait)
	for {
		err := fn()
		if err == nil || time.Now().After(deadline) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

func (s *Store) Close() error { return s.db.Close() }

// firstSchema is the schema of a database 0.9.0 made. Older ones are not
// upgraded: their apps signed and encrypted under labels of their own, so
// nobody could read what they hold.
const firstSchema = 13

// ErrOldDatabase: the database is older than this server takes.
var ErrOldDatabase = errors.New("this database is from before 0.9.0, whose encrypted data this version's apps " +
	"cannot read: start the server with an empty database")

// refuseOldDatabase keeps the server from a database whose schema is older
// than [firstSchema], and so beyond upgrading: it starts with an empty one.
func (s *Store) refuseOldDatabase(ctx context.Context) error {
	version, err := s.schemaVersion(ctx)
	if err != nil || version == 0 || version >= firstSchema {
		return err
	}
	return ErrOldDatabase
}

// schema makes a fresh database: schema firstSchema, the tables as 0.9.0
// left them (it started afresh). Later versions add migrations to it.
var schema = []string{
	`CREATE TABLE users (
		  id varchar(128) NOT NULL,
		  password_hash varchar(255) NOT NULL,
		  created_at bigint(20) NOT NULL,
		  presence_mode varchar(16) NOT NULL DEFAULT 'auto',
		  PRIMARY KEY (id)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE account_data (
		  user_id varchar(128) NOT NULL,
		  name varchar(64) NOT NULL,
		  data mediumtext NOT NULL,
		  updated_at bigint(20) NOT NULL,
		  version bigint(20) NOT NULL DEFAULT 1,
		  PRIMARY KEY (user_id,name),
		  CONSTRAINT account_data_ibfk_1 FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE conversations (
		  id char(26) NOT NULL,
		  direct_key varchar(300) DEFAULT NULL,
		  created_by varchar(128) NOT NULL,
		  created_at bigint(20) NOT NULL,
		  epoch bigint(20) NOT NULL DEFAULT 0,
		  hub varchar(255) DEFAULT NULL,
		  hub_seq bigint(20) NOT NULL DEFAULT 0,
		  PRIMARY KEY (id),
		  UNIQUE KEY direct_key (direct_key),
		  KEY created_by (created_by),
		  CONSTRAINT conversations_ibfk_1 FOREIGN KEY (created_by) REFERENCES users (id)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE calls (
		  id char(26) NOT NULL,
		  conv_id char(26) NOT NULL,
		  direct tinyint(1) NOT NULL,
		  started_by varchar(128) NOT NULL,
		  started_device char(26) NOT NULL,
		  started_at bigint(20) NOT NULL,
		  ring_until bigint(20) DEFAULT NULL,
		  answered_at bigint(20) DEFAULT NULL,
		  first_joined_at bigint(20) DEFAULT NULL,
		  ended_at bigint(20) DEFAULT NULL,
		  end_reason varchar(16) DEFAULT NULL,
		  version bigint(20) NOT NULL DEFAULT 1,
		  active_conv char(26) DEFAULT NULL,
		  video tinyint(1) NOT NULL DEFAULT 0,
		  PRIMARY KEY (id),
		  UNIQUE KEY calls_active (active_conv),
		  KEY calls_conv (conv_id,started_at),
		  KEY calls_ended (ended_at),
		  CONSTRAINT calls_ibfk_1 FOREIGN KEY (conv_id) REFERENCES conversations (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE call_participants (
		  call_id char(26) NOT NULL,
		  device_id char(26) NOT NULL,
		  user_id varchar(128) NOT NULL,
		  sid varchar(64) NOT NULL,
		  joined_at bigint(20) NOT NULL,
		  PRIMARY KEY (call_id,device_id),
		  KEY call_participants_user (user_id),
		  CONSTRAINT call_participants_ibfk_1 FOREIGN KEY (call_id) REFERENCES calls (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE commit_leases (
		  conv_id char(26) NOT NULL,
		  lease_id char(26) NOT NULL,
		  device_id char(26) NOT NULL,
		  expires_at bigint(20) NOT NULL,
		  PRIMARY KEY (conv_id),
		  CONSTRAINT commit_leases_ibfk_1 FOREIGN KEY (conv_id) REFERENCES conversations (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE contacts (
		  owner varchar(128) NOT NULL,
		  peer varchar(128) NOT NULL,
		  state varchar(16) NOT NULL,
		  updated_at bigint(20) NOT NULL,
		  PRIMARY KEY (owner,peer),
		  KEY contacts_peer (peer),
		  CONSTRAINT contacts_ibfk_1 FOREIGN KEY (owner) REFERENCES users (id) ON DELETE CASCADE,
		  CONSTRAINT contacts_ibfk_2 FOREIGN KEY (peer) REFERENCES users (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE sessions (
		  id char(26) NOT NULL,
		  user_id varchar(128) NOT NULL,
		  token_hash char(64) NOT NULL,
		  device_name varchar(64) NOT NULL,
		  platform varchar(32) NOT NULL,
		  created_at bigint(20) NOT NULL,
		  last_seen_at bigint(20) NOT NULL,
		  PRIMARY KEY (id),
		  UNIQUE KEY token_hash (token_hash),
		  KEY sessions_user (user_id),
		  CONSTRAINT sessions_ibfk_1 FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE device_inbox (
		  id bigint(20) NOT NULL AUTO_INCREMENT,
		  device_id char(26) NOT NULL,
		  sender_user varchar(128) NOT NULL,
		  sender_device char(26) NOT NULL,
		  type varchar(32) NOT NULL,
		  payload mediumtext NOT NULL,
		  created_at bigint(20) NOT NULL,
		  PRIMARY KEY (id),
		  KEY device_inbox_device (device_id,id),
		  CONSTRAINT device_inbox_ibfk_1 FOREIGN KEY (device_id) REFERENCES sessions (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE device_keys (
		  device_id char(26) NOT NULL,
		  user_id varchar(128) NOT NULL,
		  mls_sig_key varchar(64) NOT NULL,
		  signature varchar(128) DEFAULT NULL,
		  signed_version int(11) DEFAULT NULL,
		  created_at bigint(20) NOT NULL,
		  PRIMARY KEY (device_id),
		  KEY device_keys_user (user_id),
		  CONSTRAINT device_keys_ibfk_1 FOREIGN KEY (device_id) REFERENCES sessions (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE events (
		  seq bigint(20) NOT NULL AUTO_INCREMENT,
		  conv_id char(26) DEFAULT NULL,
		  type varchar(32) NOT NULL,
		  target_user varchar(128) DEFAULT NULL,
		  msg_id char(26) DEFAULT NULL,
		  sender varchar(128) DEFAULT NULL,
		  payload longtext NOT NULL,
		  ts bigint(20) NOT NULL,
		  hub_seq bigint(20) DEFAULT NULL,
		  PRIMARY KEY (seq),
		  UNIQUE KEY msg_id (msg_id),
		  KEY events_conv_type (conv_id,type,seq),
		  KEY events_target (target_user,seq),
		  KEY events_hub_seq (conv_id,hub_seq),
		  CONSTRAINT events_ibfk_1 FOREIGN KEY (conv_id) REFERENCES conversations (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE federation_inbound (
		  origin varchar(255) NOT NULL,
		  stream char(26) NOT NULL,
		  last_item bigint(20) NOT NULL,
		  updated_at bigint(20) NOT NULL,
		  PRIMARY KEY (origin)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE federation_queue (
		  id bigint(20) NOT NULL AUTO_INCREMENT,
		  destination varchar(255) NOT NULL,
		  item mediumtext NOT NULL,
		  created_at bigint(20) NOT NULL,
		  PRIMARY KEY (id),
		  KEY federation_queue_destination (destination,id)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE federation_servers (
		  host varchar(255) NOT NULL,
		  next_attempt bigint(20) NOT NULL,
		  failures int(11) NOT NULL,
		  last_error text DEFAULT NULL,
		  updated_at bigint(20) NOT NULL,
		  PRIMARY KEY (host)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE group_info (
		  conv_id char(26) NOT NULL,
		  epoch bigint(20) NOT NULL,
		  data mediumtext NOT NULL,
		  updated_at bigint(20) NOT NULL,
		  state mediumtext DEFAULT NULL,
		  PRIMARY KEY (conv_id),
		  CONSTRAINT group_info_ibfk_1 FOREIGN KEY (conv_id) REFERENCES conversations (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE key_backup (
		  user_id varchar(128) NOT NULL,
		  msg_id char(26) NOT NULL,
		  data text NOT NULL,
		  PRIMARY KEY (user_id,msg_id),
		  CONSTRAINT key_backup_ibfk_1 FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE key_packages (
		  id bigint(20) NOT NULL AUTO_INCREMENT,
		  device_id char(26) NOT NULL,
		  data mediumtext NOT NULL,
		  last_resort tinyint(1) NOT NULL,
		  created_at bigint(20) NOT NULL,
		  PRIMARY KEY (id),
		  KEY key_packages_device (device_id,last_resort),
		  CONSTRAINT key_packages_ibfk_1 FOREIGN KEY (device_id) REFERENCES sessions (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE media (
		  hash char(71) NOT NULL,
		  size bigint(20) NOT NULL,
		  mime varchar(255) NOT NULL,
		  uploader varchar(128) NOT NULL,
		  created_at bigint(20) NOT NULL,
		  PRIMARY KEY (hash),
		  KEY uploader (uploader),
		  CONSTRAINT media_ibfk_1 FOREIGN KEY (uploader) REFERENCES users (id)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE members (
		  conv_id char(26) NOT NULL,
		  user_id varchar(128) NOT NULL,
		  PRIMARY KEY (conv_id,user_id),
		  KEY members_user (user_id),
		  CONSTRAINT members_ibfk_1 FOREIGN KEY (conv_id) REFERENCES conversations (id) ON DELETE CASCADE,
		  CONSTRAINT members_ibfk_2 FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE profiles (
		  user_id varchar(128) NOT NULL,
		  version bigint(20) NOT NULL,
		  ct mediumtext NOT NULL,
		  signature varchar(128) NOT NULL,
		  updated_at bigint(20) NOT NULL,
		  PRIMARY KEY (user_id),
		  CONSTRAINT profiles_ibfk_1 FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE push_subscriptions (
		  device_id char(26) NOT NULL,
		  user_id varchar(128) NOT NULL,
		  endpoint varchar(2048) NOT NULL,
		  p256dh varchar(128) DEFAULT NULL,
		  auth varchar(64) DEFAULT NULL,
		  updated_at bigint(20) NOT NULL,
		  PRIMARY KEY (device_id),
		  KEY push_subscriptions_user (user_id),
		  CONSTRAINT push_subscriptions_ibfk_1 FOREIGN KEY (device_id) REFERENCES sessions (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE read_markers (
		  conv_id char(26) NOT NULL,
		  user_id varchar(128) NOT NULL,
		  up_to bigint(20) NOT NULL,
		  PRIMARY KEY (conv_id,user_id),
		  KEY user_id (user_id),
		  CONSTRAINT read_markers_ibfk_1 FOREIGN KEY (conv_id) REFERENCES conversations (id) ON DELETE CASCADE,
		  CONSTRAINT read_markers_ibfk_2 FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE remote_devices (
		  device_id char(26) NOT NULL,
		  user_id varchar(128) NOT NULL,
		  updated_at bigint(20) NOT NULL,
		  PRIMARY KEY (device_id),
		  KEY remote_devices_user (user_id),
		  CONSTRAINT remote_devices_ibfk_1 FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE secret_storage (
		  user_id varchar(128) NOT NULL,
		  data text NOT NULL,
		  identity_version int(11) NOT NULL,
		  updated_at bigint(20) NOT NULL,
		  PRIMARY KEY (user_id),
		  CONSTRAINT secret_storage_ibfk_1 FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE server_settings (
		  name varchar(64) NOT NULL,
		  value text NOT NULL,
		  PRIMARY KEY (name)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE trust_attestations (
		  signer_user varchar(128) NOT NULL,
		  target_user varchar(128) NOT NULL,
		  data text NOT NULL,
		  updated_at bigint(20) NOT NULL,
		  PRIMARY KEY (signer_user,target_user),
		  KEY target_user (target_user),
		  CONSTRAINT trust_attestations_ibfk_1 FOREIGN KEY (signer_user) REFERENCES users (id) ON DELETE CASCADE,
		  CONSTRAINT trust_attestations_ibfk_2 FOREIGN KEY (target_user) REFERENCES users (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
	`CREATE TABLE user_keys (
		  user_id varchar(128) NOT NULL,
		  identity_key varchar(64) NOT NULL,
		  identity_version int(11) NOT NULL,
		  updated_at bigint(20) NOT NULL,
		  PRIMARY KEY (user_id),
		  CONSTRAINT user_keys_ibfk_1 FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`,
}

// migrations[v] takes a database from schema v-1 to v, for those after
// firstSchema. Each statement can run again, should a step stop halfway.
var migrations = map[int][]string{
	// Conversations move from hub to hub: what there was is of term 0.
	14: {
		`ALTER TABLE conversations ADD COLUMN IF NOT EXISTS hub_term int(11) NOT NULL DEFAULT 0`,
		`ALTER TABLE events ADD COLUMN IF NOT EXISTS hub_term int(11) NOT NULL DEFAULT 0`,
		`ALTER TABLE events ADD KEY IF NOT EXISTS events_hub (conv_id,hub_term,hub_seq)`,
		`ALTER TABLE events DROP KEY IF EXISTS events_hub_seq`,
	},
}

// latestSchema is the schema of a database this version made or upgraded.
func latestSchema() int {
	latest := firstSchema
	for v := range migrations {
		latest = max(latest, v)
	}
	return latest
}

// schemaVersion is the database's version; 0 if it has none yet.
func (s *Store) schemaVersion(ctx context.Context) (int, error) {
	var version int
	err := s.db.QueryRowContext(ctx, `SELECT version FROM schema_version`).Scan(&version)
	var me *mysql.MySQLError
	if errors.Is(err, sql.ErrNoRows) || (errors.As(err, &me) && me.Number == 1146) { // No such table.
		return 0, nil
	}
	return version, err
}

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_version (version INT NOT NULL)`); err != nil {
		return err
	}
	var version int
	err := s.db.QueryRowContext(ctx, `SELECT version FROM schema_version`).Scan(&version)
	if errors.Is(err, sql.ErrNoRows) {
		if _, err := s.db.ExecContext(ctx, `INSERT INTO schema_version (version) VALUES (0)`); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	// MariaDB commits DDL implicitly, so each statement stands alone; the
	// version is set only after all of a step's statements succeed.
	step := func(v int, statements []string) error {
		for _, stmt := range statements {
			if _, err := s.db.ExecContext(ctx, stmt); err != nil {
				return fmt.Errorf("schema %d: %w", v, err)
			}
		}
		_, err := s.db.ExecContext(ctx, `UPDATE schema_version SET version = ?`, v)
		return err
	}
	if version == 0 {
		if err := step(firstSchema, schema); err != nil {
			return err
		}
		version = firstSchema
	}
	for v := version + 1; v <= latestSchema(); v++ {
		if err := step(v, migrations[v]); err != nil {
			return err
		}
	}
	return nil
}

func now() int64 { return time.Now().UnixMilli() }

// IsDuplicate reports a unique-key violation.
func IsDuplicate(err error) bool {
	var me *mysql.MySQLError
	return errors.As(err, &me) && me.Number == 1062
}

// querier is satisfied by *sql.DB and *sql.Tx.
type querier interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// Tx is a transaction inside the ordered event-append section.
type Tx struct {
	q   *sql.Tx
	ctx context.Context
}

// AppendEvents runs fn in a transaction while holding the append lock. If fn
// succeeds the transaction commits, then publish (if fn returned one) runs
// before the lock is released, so live events go out in seq order.
func (s *Store) AppendEvents(ctx context.Context, fn func(tx *Tx) (publish func(), err error)) error {
	s.appendMu.Lock()
	defer s.appendMu.Unlock()
	sqlTx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	publish, err := fn(&Tx{q: sqlTx, ctx: ctx})
	if err != nil {
		sqlTx.Rollback()
		return err
	}
	if err := sqlTx.Commit(); err != nil {
		return err
	}
	if publish != nil {
		publish()
	}
	return nil
}

// Users

type User struct {
	ID           string
	PasswordHash string
}

func (s *Store) CreateUser(ctx context.Context, u User) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO users (id, password_hash, created_at) VALUES (?, ?, ?)`,
		u.ID, u.PasswordHash, now())
	return err
}

func (s *Store) User(ctx context.Context, id string) (*User, error) {
	return user(ctx, s.db, id)
}

func user(ctx context.Context, q querier, id string) (*User, error) {
	var u User
	err := q.QueryRowContext(ctx, `SELECT id, password_hash FROM users WHERE id = ?`, id).
		Scan(&u.ID, &u.PasswordHash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return &u, err
}

// Sessions (one per signed-in device)

type Session struct {
	ID, UserID, DeviceName, Platform string
	CreatedAt, LastSeenAt            int64
}

func (s *Store) CreateSession(ctx context.Context, sess Session, tokenHash string) error {
	t := now()
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO sessions (id, user_id, token_hash, device_name, platform, created_at, last_seen_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		sess.ID, sess.UserID, tokenHash, sess.DeviceName, sess.Platform, t, t)
	return err
}

func (s *Store) SessionByTokenHash(ctx context.Context, tokenHash string) (*Session, error) {
	var sess Session
	err := s.db.QueryRowContext(ctx,
		`SELECT id, user_id, device_name, platform, created_at, last_seen_at FROM sessions WHERE token_hash = ?`,
		tokenHash).Scan(&sess.ID, &sess.UserID, &sess.DeviceName, &sess.Platform, &sess.CreatedAt, &sess.LastSeenAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return &sess, err
}

func (s *Store) SessionsOf(ctx context.Context, userID string) ([]Session, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, user_id, device_name, platform, created_at, last_seen_at FROM sessions
		 WHERE user_id = ? ORDER BY created_at, id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Session
	for rows.Next() {
		var sess Session
		if err := rows.Scan(&sess.ID, &sess.UserID, &sess.DeviceName, &sess.Platform, &sess.CreatedAt, &sess.LastSeenAt); err != nil {
			return nil, err
		}
		out = append(out, sess)
	}
	return out, rows.Err()
}

// DeleteSession returns ErrNotFound if userID has no session id.
func (s *Store) DeleteSession(ctx context.Context, id, userID string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE id = ? AND user_id = ?`, id, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) TouchSession(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE sessions SET last_seen_at = ? WHERE id = ?`, now(), id)
	return err
}

// Conversations

func (s *Store) Conversation(ctx context.Context, id string) (*protocol.ConversationInfo, error) {
	return conversation(ctx, s.db, id)
}

func (tx *Tx) Conversation(id string) (*protocol.ConversationInfo, error) {
	return conversation(tx.ctx, tx.q, id)
}

func conversation(ctx context.Context, q querier, id string) (*protocol.ConversationInfo, error) {
	var directKey sql.NullString
	err := q.QueryRowContext(ctx, `SELECT direct_key FROM conversations WHERE id = ?`, id).Scan(&directKey)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	info := &protocol.ConversationInfo{ID: id, IsDirect: directKey.Valid, Members: []protocol.MemberInfo{}}
	rows, err := q.QueryContext(ctx, `SELECT user_id FROM members WHERE conv_id = ? ORDER BY user_id`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var m protocol.MemberInfo
		if err := rows.Scan(&m.ID); err != nil {
			return nil, err
		}
		info.Members = append(info.Members, m)
	}
	return info, rows.Err()
}

// ConversationCreator is who created a conversation; ErrNotFound if there is
// none with that ID.
func (tx *Tx) ConversationCreator(id string) (string, error) {
	var by string
	err := tx.q.QueryRowContext(tx.ctx, `SELECT created_by FROM conversations WHERE id = ?`, id).Scan(&by)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return by, err
}

func (tx *Tx) ConversationByDirectKey(key string) (string, error) {
	var id string
	err := tx.q.QueryRowContext(tx.ctx, `SELECT id FROM conversations WHERE direct_key = ?`, key).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return id, err
}

// DirectPartner returns the other member of a direct chat, or "" for a group.
func (tx *Tx) DirectPartner(convID, userID string) (string, error) {
	var partner string
	err := tx.q.QueryRowContext(tx.ctx, `
		SELECT m.user_id FROM conversations c JOIN members m ON m.conv_id = c.id
		WHERE c.id = ? AND c.direct_key IS NOT NULL AND m.user_id <> ? LIMIT 1`, convID, userID).Scan(&partner)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return partner, err
}

func (tx *Tx) CreateConversation(id, createdBy string, members []string, directKey *string) error {
	if _, err := tx.q.ExecContext(tx.ctx,
		`INSERT INTO conversations (id, direct_key, created_by, created_at) VALUES (?, ?, ?, ?)`,
		id, directKey, createdBy, now()); err != nil {
		return err
	}
	for _, m := range members {
		if err := tx.AddMember(id, m); err != nil {
			return err
		}
	}
	return nil
}

func (tx *Tx) AddMember(convID, userID string) error {
	_, err := tx.q.ExecContext(tx.ctx, `INSERT IGNORE INTO members (conv_id, user_id) VALUES (?, ?)`, convID, userID)
	return err
}

func (tx *Tx) RemoveMember(convID, userID string) error {
	if _, err := tx.q.ExecContext(tx.ctx, `DELETE FROM members WHERE conv_id = ? AND user_id = ?`, convID, userID); err != nil {
		return err
	}
	_, err := tx.q.ExecContext(tx.ctx, `DELETE FROM read_markers WHERE conv_id = ? AND user_id = ?`, convID, userID)
	return err
}

func (s *Store) ConversationIDsOf(ctx context.Context, userID string) ([]string, error) {
	return strings0(s.db.QueryContext(ctx, `SELECT conv_id FROM members WHERE user_id = ? ORDER BY conv_id`, userID))
}

func (s *Store) MemberIDs(ctx context.Context, convID string) ([]string, error) {
	return memberIDs(ctx, s.db, convID)
}

func (tx *Tx) MemberIDs(convID string) ([]string, error) { return memberIDs(tx.ctx, tx.q, convID) }

func memberIDs(ctx context.Context, q querier, convID string) ([]string, error) {
	return strings0(q.QueryContext(ctx, `SELECT user_id FROM members WHERE conv_id = ?`, convID))
}

func (s *Store) IsMember(ctx context.Context, convID, userID string) (bool, error) {
	var one int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM members WHERE conv_id = ? AND user_id = ?`, convID, userID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (tx *Tx) User(id string) (*User, error) { return user(tx.ctx, tx.q, id) }

// strings0 collects a single-string-column result.
func strings0(rows *sql.Rows, err error) ([]string, error) {
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

// Events

// AppendOptions describe an event to append.
type AppendOptions struct {
	TargetUser string // Only this user sees the event.
	MsgID      string // Unique client message ID, for messages.
	Sender     string
	// For an event of a conversation another server orders: its seq there,
	// and when it happened there.
	HubSeq int64
	TS     int64
	// The term of its conversation it is of: the one its hub numbered it in.
	HubTerm int64
}

// AppendEvent appends an event; conv is empty for user-level events, which
// must then have a TargetUser.
func (tx *Tx) AppendEvent(conv, typ string, data json.RawMessage, opt AppendOptions) (protocol.SyncEvent, error) {
	ts := now()
	if opt.TS != 0 {
		ts = opt.TS
	}
	var hubSeq any
	if opt.HubSeq != 0 {
		hubSeq = opt.HubSeq
	}
	res, err := tx.q.ExecContext(tx.ctx,
		`INSERT INTO events (conv_id, type, target_user, msg_id, sender, payload, ts, hub_seq, hub_term)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		nullable(conv), typ, nullable(opt.TargetUser), nullable(opt.MsgID), nullable(opt.Sender), string(data), ts, hubSeq,
		opt.HubTerm)
	if err != nil {
		return protocol.SyncEvent{}, err
	}
	seq, err := res.LastInsertId()
	return protocol.SyncEvent{Seq: seq, Type: typ, Conv: conv, TS: ts, Data: data}, err
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// StoredMessage locates an existing message by its client ID.
type StoredMessage struct {
	Seq          int64
	Conv, Sender string
}

func (tx *Tx) MessageByID(msgID string) (*StoredMessage, error) {
	var m StoredMessage
	err := tx.q.QueryRowContext(tx.ctx, `SELECT seq, conv_id, sender FROM events WHERE msg_id = ?`, msgID).
		Scan(&m.Seq, &m.Conv, &m.Sender)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return &m, err
}

func (s *Store) MaxSeq(ctx context.Context) (int64, error) {
	var seq int64
	err := s.db.QueryRowContext(ctx, `SELECT COALESCE(MAX(seq), 0) FROM events`).Scan(&seq)
	return seq, err
}

// EventsSince returns events visible to userID after since, oldest first.
func (s *Store) EventsSince(ctx context.Context, userID string, since int64, limit int) ([]protocol.SyncEvent, error) {
	return events(s.db.QueryContext(ctx, `
		SELECT seq, type, conv_id, ts, payload FROM events
		WHERE seq > ? AND (
			(target_user IS NULL AND conv_id IN (SELECT conv_id FROM members WHERE user_id = ?))
			OR target_user = ?
		)
		ORDER BY seq LIMIT ?`, since, userID, userID, limit))
}

// MessagesBefore returns messages of convID older than before, oldest first.
func (s *Store) MessagesBefore(ctx context.Context, convID string, before int64, limit int) ([]protocol.SyncEvent, error) {
	evs, err := events(s.db.QueryContext(ctx, `
		SELECT seq, type, conv_id, ts, payload FROM events
		WHERE conv_id = ? AND type = 'message' AND seq < ?
		ORDER BY seq DESC LIMIT ?`, convID, before, limit))
	for i, j := 0, len(evs)-1; i < j; i, j = i+1, j-1 {
		evs[i], evs[j] = evs[j], evs[i]
	}
	return evs, err
}

func events(rows *sql.Rows, err error) ([]protocol.SyncEvent, error) {
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []protocol.SyncEvent{}
	for rows.Next() {
		var e protocol.SyncEvent
		var payload string
		var conv sql.NullString
		if err := rows.Scan(&e.Seq, &e.Type, &conv, &e.TS, &payload); err != nil {
			return nil, err
		}
		e.Conv = conv.String
		e.Data = json.RawMessage(payload)
		out = append(out, e)
	}
	return out, rows.Err()
}

// Read markers

func (s *Store) ReadUpTo(ctx context.Context, convID, userID string) (int64, error) {
	return readUpTo(ctx, s.db, convID, userID)
}

func readUpTo(ctx context.Context, q querier, convID, userID string) (int64, error) {
	var upTo int64
	err := q.QueryRowContext(ctx, `SELECT up_to FROM read_markers WHERE conv_id = ? AND user_id = ?`, convID, userID).Scan(&upTo)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return upTo, err
}

// AdvanceReadMarker moves the marker forward; it reports false if the marker
// was already at or past upTo.
func (tx *Tx) AdvanceReadMarker(convID, userID string, upTo int64) (bool, error) {
	current, err := readUpTo(tx.ctx, tx.q, convID, userID)
	if err != nil || current >= upTo {
		return false, err
	}
	_, err = tx.q.ExecContext(tx.ctx,
		`INSERT INTO read_markers (conv_id, user_id, up_to) VALUES (?, ?, ?)
		 ON DUPLICATE KEY UPDATE up_to = VALUES(up_to)`, convID, userID, upTo)
	return err == nil, err
}

// Media

type Media struct {
	Hash string
	Size int64
	Mime string
}

func (s *Store) Media(ctx context.Context, hash string) (*Media, error) {
	return media(ctx, s.db, hash)
}

func (tx *Tx) Media(hash string) (*Media, error) { return media(tx.ctx, tx.q, hash) }

func media(ctx context.Context, q querier, hash string) (*Media, error) {
	var m Media
	err := q.QueryRowContext(ctx, `SELECT hash, size, mime FROM media WHERE hash = ?`, hash).Scan(&m.Hash, &m.Size, &m.Mime)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return &m, err
}

func (s *Store) AddMedia(ctx context.Context, m Media, uploader string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT IGNORE INTO media (hash, size, mime, uploader, created_at) VALUES (?, ?, ?, ?, ?)`,
		m.Hash, m.Size, m.Mime, uploader, now())
	return err
}
