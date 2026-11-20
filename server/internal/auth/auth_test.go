package auth

import "testing"

func TestPasswordRoundTrip(t *testing.T) {
	hash := HashPassword("correct horse")
	if !VerifyPassword(hash, "correct horse") {
		t.Fatal("correct password rejected")
	}
	if VerifyPassword(hash, "wrong horse") {
		t.Fatal("wrong password accepted")
	}
	if HashPassword("correct horse") == hash {
		t.Fatal("hashes must be salted")
	}
	if VerifyPassword("garbage", "x") {
		t.Fatal("malformed hash accepted")
	}
}

func TestTokens(t *testing.T) {
	a, b := NewToken(), NewToken()
	if a == b || len(a) != 43 {
		t.Fatalf("unexpected tokens %q %q", a, b)
	}
	if HashToken(a) == HashToken(b) || len(HashToken(a)) != 64 {
		t.Fatal("bad token hash")
	}
}
