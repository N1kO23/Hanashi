package push

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"time"
)

var b64 = base64.RawURLEncoding

// VAPID identifies this server to push services (RFC 8292). FCM rejects
// pushes without it; other services use it to tell senders apart.
type VAPID struct {
	key     *ecdsa.PrivateKey
	subject string
	public  string
}

// NewVAPIDKey creates a P-256 key, PKCS #8 encoded.
func NewVAPIDKey() ([]byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	return x509.MarshalPKCS8PrivateKey(key)
}

// NewVAPID loads a PKCS #8 P-256 key. subject is a mailto: or https: URL
// where the push service can reach the server's operator.
func NewVAPID(pkcs8 []byte, subject string) (*VAPID, error) {
	parsed, err := x509.ParsePKCS8PrivateKey(pkcs8)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("VAPID key must be P-256")
	}
	public, err := key.PublicKey.ECDH()
	if err != nil {
		return nil, err
	}
	return &VAPID{key: key, subject: subject, public: b64.EncodeToString(public.Bytes())}, nil
}

// PublicKey is the application server key clients register with:
// base64url of the uncompressed point.
func (v *VAPID) PublicKey() string { return v.public }

// Authorization returns the Authorization header for a push to endpoint.
func (v *VAPID) Authorization(endpoint string, now time.Time) (string, error) {
	u, err := url.Parse(endpoint)
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{
		"aud": u.Scheme + "://" + u.Host,
		"exp": now.Add(12 * time.Hour).Unix(),
		"sub": v.subject,
	})
	if err != nil {
		return "", err
	}
	signed := b64.EncodeToString([]byte(`{"typ":"JWT","alg":"ES256"}`)) + "." + b64.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signed))
	r, s, err := ecdsa.Sign(rand.Reader, v.key, digest[:])
	if err != nil {
		return "", err
	}
	// JWS wants r ‖ s, 32 bytes each, not ASN.1.
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	return "vapid t=" + signed + "." + b64.EncodeToString(signature) + ", k=" + v.public, nil
}
