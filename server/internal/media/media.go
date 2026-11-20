// Package media stores uploaded blobs by the SHA-256 of their content.
package media

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
)

// ErrTooLarge is returned when an upload exceeds the size limit.
var ErrTooLarge = errors.New("upload too large")

type Store struct{ root string }

func NewStore(root string) (*Store, error) {
	if err := os.MkdirAll(filepath.Join(root, "tmp"), 0o755); err != nil {
		return nil, err
	}
	return &Store{root: root}, nil
}

// Path is where a blob lives: media/ab/abcdef....
func (s *Store) Path(hash string) string {
	hexPart := hash[len("sha256:"):]
	return filepath.Join(s.root, hexPart[:2], hexPart)
}

// ErrNotThatBlob is returned when what was saved is not the blob asked for.
var ErrNotThatBlob = errors.New("not the blob asked for")

// Save streams r to disk while hashing it and returns its content hash.
// Storing the same bytes twice keeps a single copy.
func (s *Store) Save(r io.Reader, maxBytes int64) (hash string, size int64, err error) {
	return s.save(r, maxBytes, "")
}

// SaveAs saves r as Save does, but keeps it only if it is the blob of hash:
// one fetched from elsewhere has to be what was asked for.
func (s *Store) SaveAs(r io.Reader, maxBytes int64, hash string) (size int64, err error) {
	_, size, err = s.save(r, maxBytes, hash)
	return size, err
}

func (s *Store) save(r io.Reader, maxBytes int64, want string) (hash string, size int64, err error) {
	tmp, err := os.CreateTemp(filepath.Join(s.root, "tmp"), "upload-*")
	if err != nil {
		return "", 0, err
	}
	defer os.Remove(tmp.Name()) // No-op once renamed.

	hasher := sha256.New()
	size, err = io.Copy(io.MultiWriter(tmp, hasher), io.LimitReader(r, maxBytes+1))
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return "", 0, err
	}
	if size > maxBytes {
		return "", 0, ErrTooLarge
	}
	hash = "sha256:" + hex.EncodeToString(hasher.Sum(nil))
	if want != "" && hash != want {
		return "", 0, ErrNotThatBlob
	}
	target := s.Path(hash)
	if _, statErr := os.Stat(target); statErr == nil {
		return hash, size, nil
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return "", 0, err
	}
	return hash, size, os.Rename(tmp.Name(), target)
}
