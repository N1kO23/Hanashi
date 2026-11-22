package store

import (
	"context"
	"database/sql"
	"encoding/json"
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

// What a database holds before conversations could move is of their first
// term, as it was.
func TestTermsComeToAnExistingDatabase(t *testing.T) {
	dsn, db := databaseAt(t, firstSchema,
		`INSERT INTO users (id, password_hash, created_at) VALUES ('a@h', 'x', 1)`,
		`INSERT INTO conversations (id, created_by, created_at, hub, hub_seq) VALUES ('`+testConv+`', 'a@h', 1, 'b.test', 2)`,
		`INSERT INTO events (conv_id, type, payload, ts, hub_seq) VALUES ('`+testConv+`', 'message', '{}', 1, 1),
			('`+testConv+`', 'message', '{}', 2, 2)`,
	)
	ctx := context.Background()
	st, err := Open(ctx, dsn, false, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if got := schemaOf(t, db); got != latestSchema() {
		t.Fatalf("schema %d", got)
	}
	if hub, err := st.ConversationHub(ctx, testConv); err != nil || hub != (Hub{Host: "b.test", Seq: 2}) {
		t.Fatalf("hub %+v, %v", hub, err)
	}
	events, err := st.ConvEventsSince(ctx, testConv, ConvEventsQuery{Limit: 10})
	if err != nil || len(events) != 2 || events[0].Term != 0 || events[0].Seq != 1 || events[1].Seq != 2 {
		t.Fatalf("events %+v, %v", events, err)
	}
}

// A conversation's order goes term by term: in each, as its hub numbered
// the events, its own here by their seq, another's by theirs.
func TestOrderAcrossTerms(t *testing.T) {
	ctx := context.Background()
	st, err := Open(ctx, testdb.NewDatabase(t), false, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.CreateUser(ctx, User{ID: "a@h", PasswordHash: "x"}); err != nil {
		t.Fatal(err)
	}
	var own, forOne, marker, later, backfilled int64
	if err := st.AppendEvents(ctx, func(tx *Tx) (func(), error) {
		if err := tx.CreateConversation(testConv, "a@h", []string{"a@h"}, nil); err != nil {
			return nil, err
		}
		add := func(typ, target string, hubSeq, term int64) int64 {
			ev, err := tx.AppendEvent(testConv, typ, json.RawMessage(`{}`),
				AppendOptions{TargetUser: target, HubSeq: hubSeq, HubTerm: term})
			if err != nil {
				t.Fatal(err)
			}
			return ev.Seq
		}
		// Term 0, ordered here.
		own = add("message", "", 0, 0)
		forOne = add("read_marker", "a@h", 0, 0)
		add("mls_commit", "", 0, 0)
		marker = add("hub_moved", HubOnly, 0, 0)
		// Term 1, ordered by b.test: taken as it came, and before that, what
		// its copy lacked.
		if err := tx.SetHub(testConv, "b.test", 1); err != nil {
			return nil, err
		}
		later = add("message", "", 7, 1)
		backfilled = add("member_added", HistoryOnly, 3, 1)
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
	type at struct {
		term, seq int64
		typ       string
	}
	list := func(q ConvEventsQuery) []at {
		t.Helper()
		q.Limit = 10
		events, err := st.ConvEventsSince(ctx, testConv, q)
		if err != nil {
			t.Fatal(err)
		}
		var out []at
		for _, e := range events {
			out = append(out, at{e.Term, e.Seq, e.Type})
		}
		return out
	}
	all := fmt.Sprint([]at{{0, own, "message"}, {0, own + 2, "mls_commit"}, {0, marker, "hub_moved"},
		{1, 3, "member_added"}, {1, 7, "message"}})
	if got := fmt.Sprint(list(ConvEventsQuery{UpToTerm: 1})); got != all {
		t.Fatalf("all of it: %s, not %s", got, all)
	}
	if got := fmt.Sprint(list(ConvEventsQuery{Since: own + 2, UpToTerm: 1})); got != fmt.Sprint([]at{{0, marker, "hub_moved"},
		{1, 3, "member_added"}, {1, 7, "message"}}) {
		t.Fatalf("from the commit on: %s", got)
	}
	if got := fmt.Sprint(list(ConvEventsQuery{Term: 1, Since: 3, UpToTerm: 1})); got != fmt.Sprint([]at{{1, 7, "message"}}) {
		t.Fatalf("from term 1's third on: %s", got)
	}
	if got := fmt.Sprint(list(ConvEventsQuery{UpToTerm: 0, Except: []string{"message"}})); got != fmt.Sprint([]at{
		{0, own + 2, "mls_commit"}, {0, marker, "hub_moved"}}) {
		t.Fatalf("the terms it ordered, but messages: %s", got)
	}
	if term, err := st.LastTermOrdered(ctx, testConv); err != nil || term != 0 {
		t.Fatalf("last term ordered: %d, %v", term, err)
	}
	if seq, err := st.SeqOfHubEvent(ctx, testConv, 1, 7); err != nil || seq != later {
		t.Fatalf("term 1's 7th: %d, %v", seq, err)
	}
	if seq, err := st.SeqOfHubEvent(ctx, testConv, 0, own); err != nil || seq != own {
		t.Fatalf("its own of term 0: %d, %v", seq, err)
	}
	if _, err := st.SeqOfHubEvent(ctx, testConv, 0, forOne); !errors.Is(err, ErrNotFound) {
		t.Fatalf("one user's own: %v", err)
	}
	if term, seq, err := st.HubPosition(ctx, backfilled); err != nil || term != 1 || seq != 3 {
		t.Fatalf("position of what was taken later: %d %d, %v", term, seq, err)
	}
	if err := st.AppendEvents(ctx, func(tx *Tx) (func(), error) {
		for _, c := range []struct {
			term, seq int64
			has       bool
		}{{0, own, true}, {0, forOne, false}, {1, 3, true}, {1, 4, false}, {1, own, false}} {
			if has, err := tx.HasConvEvent(testConv, c.term, c.seq); err != nil || has != c.has {
				t.Errorf("has %d of term %d: %v, %v", c.seq, c.term, has, err)
			}
		}
		if prev, err := tx.PreviousConvEvent(testConv, 0, marker); err != nil || prev != own+2 {
			t.Errorf("before the move: %d, %v", prev, err)
		}
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
}
