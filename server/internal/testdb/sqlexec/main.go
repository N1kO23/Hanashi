// Command sqlexec runs SQL statements against a test database. The app's
// integration tests use it to play a server that misbehaves (one that
// vouches for a device its user never verified), which the real server's
// API cannot be made to do.
//
//	sqlexec DSN STATEMENT...
package main

import (
	"database/sql"
	"fmt"
	"os"

	_ "github.com/go-sql-driver/mysql"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: sqlexec DSN STATEMENT...")
		os.Exit(2)
	}
	db, err := sql.Open("mysql", os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer db.Close()
	for _, statement := range os.Args[2:] {
		if _, err := db.Exec(statement); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
}
