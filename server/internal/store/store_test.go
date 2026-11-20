package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"testing"
	"time"

	"hanashi/server/internal/testdb"
)

const testConv = "01JB2Y7Z0000000000000000AB"

// New servers make the schema in one step.
func TestFreshDatabase(t *testing.T) {
	ctx := context.Background()
	st, err := Open(ctx, testdb.NewDatabase(t), false, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.CreateUser(ctx, User{ID: "new@h", PasswordHash: "x"}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendEvents(ctx, func(tx *Tx) (func(), error) {
		if err := tx.CreateConversation(testConv, "new@h", []string{"new@h"}, nil); err != nil {
			return nil, err
		}
		return nil, tx.PutGroupInfo(testConv, 1, "d", "")
	}); err != nil {
		t.Fatal(err)
	}
	if group, err := st.GroupInfo(ctx, testConv); err != nil || group.Epoch != 1 {
		t.Fatalf("group %+v, %v", group, err)
	}
}

// databaseAt is a database as a server left it whose schema was at version,
// holding what statements put in it.
func databaseAt(t *testing.T, version int, statements ...string) (string, *sql.DB) {
	t.Helper()
	dsn := testdb.NewDatabase(t)
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	all := []string{
		`CREATE TABLE schema_version (version INT NOT NULL)`,
		fmt.Sprintf(`INSERT INTO schema_version (version) VALUES (%d)`, version),
	}
	if version >= firstSchema {
		all = append(all, schema...)
	} else {
		// As far as the refusal looks: an older version's tables are not
		// made, only the one it would see users in.
		all = append(all, `CREATE TABLE users (id VARCHAR(128) NOT NULL PRIMARY KEY)`)
	}
	for _, statement := range append(all, statements...) {
		if _, err := db.Exec(statement); err != nil {
			t.Fatalf("%s: %v", statement, err)
		}
	}
	return dsn, db
}

func schemaOf(t *testing.T, db *sql.DB) int {
	t.Helper()
	var version int
	if err := db.QueryRow(`SELECT version FROM schema_version`).Scan(&version); err != nil {
		t.Fatal(err)
	}
	return version
}

// A database from before 0.9.0, whatever its schema and whether in use or
// not, is left as it is: the server starts with an empty one.
func TestOldDatabaseIsRefused(t *testing.T) {
	for _, version := range []int{1, 5, firstSchema - 1} {
		for _, users := range []int{0, 1} {
			t.Run(fmt.Sprintf("%d with %d users", version, users), func(t *testing.T) {
				var statements []string
				if users > 0 {
					statements = append(statements, `INSERT INTO users (id) VALUES ('a@h')`)
				}
				dsn, db := databaseAt(t, version, statements...)
				if _, err := Open(context.Background(), dsn, false, time.Second); !errors.Is(err, ErrOldDatabase) {
					t.Fatalf("opening: %v", err)
				}
				if got := schemaOf(t, db); got != version {
					t.Fatalf("schema %d", got)
				}
			})
		}
	}
}

// One this version made opens as it is.
func TestCurrentDatabaseOpens(t *testing.T) {
	dsn, db := databaseAt(t, firstSchema)
	st, err := Open(context.Background(), dsn, false, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	st.Close()
	if got := schemaOf(t, db); got != latestSchema() {
		t.Fatalf("schema %d", got)
	}
}
