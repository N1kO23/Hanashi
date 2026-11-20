package media

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"strings"
	"testing"
)

func TestSaveAs(t *testing.T) {
	st, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("the blob"))
	hash := "sha256:" + hex.EncodeToString(sum[:])
	if _, err := st.SaveAs(strings.NewReader("another blob"), 100, hash); !errors.Is(err, ErrNotThatBlob) {
		t.Fatalf("another blob: %v", err)
	}
	if _, err := os.Stat(st.Path(hash)); !os.IsNotExist(err) {
		t.Fatal("kept what was not asked for")
	}
	if _, err := st.SaveAs(strings.NewReader("the blob"), 4, hash); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("too large: %v", err)
	}
	if size, err := st.SaveAs(strings.NewReader("the blob"), 100, hash); err != nil || size != 8 {
		t.Fatalf("the blob: %d, %v", size, err)
	}
	if data, err := os.ReadFile(st.Path(hash)); err != nil || string(data) != "the blob" {
		t.Fatalf("kept %q, %v", data, err)
	}
	entries, _ := os.ReadDir(st.root + "/tmp")
	if len(entries) != 0 {
		t.Fatalf("left behind %d", len(entries))
	}
}
