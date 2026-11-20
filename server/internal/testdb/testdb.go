// Package testdb provides throwaway MariaDB databases for tests.
//
// It uses $HANASHI_TEST_DSN (a DSN without a database, e.g.
// "root:pw@tcp(127.0.0.1:3306)/") if set. Otherwise it starts a MariaDB
// container named hanashi-test-mariadb with its data on tmpfs, and leaves it
// running so later test runs start fast. The Dart tests use the same one.
package testdb

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

const (
	containerName = "hanashi-test-mariadb"
	image         = "mariadb:11.8"
	hostPort      = "33306"
	rootPassword  = "hanashi-test"
)

var (
	once     sync.Once
	adminDSN string
	startErr error
)

// AdminDSN returns a DSN with no database selected.
func AdminDSN(t testing.TB) string {
	t.Helper()
	once.Do(func() { adminDSN, startErr = start() })
	if startErr != nil {
		t.Fatalf("no test database: %v", startErr)
	}
	return adminDSN
}

func start() (string, error) {
	if dsn := os.Getenv("HANASHI_TEST_DSN"); dsn != "" {
		return dsn, waitReady(dsn, 30*time.Second)
	}
	if _, err := exec.LookPath("docker"); err != nil {
		return "", errors.New("set HANASHI_TEST_DSN or install Docker")
	}
	out, err := exec.Command("docker", "run", "-d", "--rm", "--name", containerName,
		"-e", "MARIADB_ROOT_PASSWORD="+rootPassword,
		"-p", "127.0.0.1:"+hostPort+":3306",
		"--tmpfs", "/var/lib/mysql",
		image).CombinedOutput()
	if err != nil && !strings.Contains(string(out), "is already in use") {
		return "", fmt.Errorf("starting MariaDB: %s", strings.TrimSpace(string(out)))
	}
	dsn := "root:" + rootPassword + "@tcp(127.0.0.1:" + hostPort + ")/"
	return dsn, waitReady(dsn, 2*time.Minute)
}

func waitReady(dsn string, timeout time.Duration) error {
	// The driver logs every refused connection while MariaDB starts up.
	_ = mysql.SetLogger(log.New(io.Discard, "", 0))
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	deadline := time.Now().Add(timeout)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := db.PingContext(ctx)
		cancel()
		if err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("MariaDB did not become ready: %w", err)
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// NewDatabase creates an empty database, drops it when the test ends, and
// returns a DSN for it.
func NewDatabase(t testing.TB) string {
	t.Helper()
	admin := AdminDSN(t)
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	name := "hanashi_test_" + hex.EncodeToString(b)
	db, err := sql.Open("mysql", admin)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("CREATE DATABASE " + name + " CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.Exec("DROP DATABASE IF EXISTS " + name)
		db.Close()
	})
	cfg, err := mysql.ParseDSN(admin)
	if err != nil {
		t.Fatal(err)
	}
	cfg.DBName = name
	return cfg.FormatDSN()
}
