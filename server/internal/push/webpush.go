// Package push wakes devices that are not connected, with Web Push messages
// (RFC 8030) encrypted for the device (RFC 8291) and signed with the
// server's VAPID key (RFC 8292). This works with every UnifiedPush
// distributor and with Google's FCM. Push services learn nothing about the
// conversation: the payload only tells the app to sync.
package push

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	recordSize = 4096
	saltSize   = 16
	authSize   = 16
	// salt ‖ record size ‖ key ID length ‖ key ID (the sender's public key).
	headerSize = saltSize + 4 + 1 + 65
)

// Encrypt encrypts plaintext for a subscription with the "aes128gcm"
// content coding (RFC 8291, RFC 8188), given the subscription's p256dh key
// (uncompressed P-256 point) and auth secret.
func Encrypt(plaintext, p256dh, auth []byte) ([]byte, error) {
	sender, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	salt := make([]byte, saltSize)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	return encrypt(plaintext, p256dh, auth, sender, salt)
}

func encrypt(plaintext, p256dh, auth []byte, sender *ecdh.PrivateKey, salt []byte) ([]byte, error) {
	receiver, err := ecdh.P256().NewPublicKey(p256dh)
	if err != nil {
		return nil, fmt.Errorf("p256dh: %w", err)
	}
	if len(auth) != authSize {
		return nil, errors.New("auth secret must be 16 bytes")
	}
	// One record: plaintext, the 0x02 delimiter and the AEAD tag.
	if len(plaintext)+1+16 > recordSize {
		return nil, errors.New("payload too large")
	}
	shared, err := sender.ECDH(receiver)
	if err != nil {
		return nil, err
	}
	senderPublic := sender.PublicKey().Bytes()
	gcm, nonce, err := contentKeys(shared, auth, salt, p256dh, senderPublic)
	if err != nil {
		return nil, err
	}
	out := make([]byte, headerSize, headerSize+len(plaintext)+1+16)
	copy(out, salt)
	binary.BigEndian.PutUint32(out[saltSize:], recordSize)
	out[saltSize+4] = byte(len(senderPublic))
	copy(out[saltSize+5:], senderPublic)
	return gcm.Seal(out, nonce, append(plaintext[:len(plaintext):len(plaintext)], 0x02), nil), nil
}

// Decrypt reverses [Encrypt] for the receiver holding the subscription's
// private key. The server never needs it; tests and tools do.
func Decrypt(body []byte, receiver *ecdh.PrivateKey, auth []byte) ([]byte, error) {
	if len(body) < headerSize+16 || body[saltSize+4] != 65 {
		return nil, errors.New("not an aes128gcm message")
	}
	salt, senderPublic := body[:saltSize], body[saltSize+5:headerSize]
	sender, err := ecdh.P256().NewPublicKey(senderPublic)
	if err != nil {
		return nil, err
	}
	shared, err := receiver.ECDH(sender)
	if err != nil {
		return nil, err
	}
	gcm, nonce, err := contentKeys(shared, auth, salt, receiver.PublicKey().Bytes(), senderPublic)
	if err != nil {
		return nil, err
	}
	padded, err := gcm.Open(nil, nonce, body[headerSize:], nil)
	if err != nil {
		return nil, err
	}
	// The last record ends with the 0x02 delimiter, then zero padding.
	i := len(padded) - 1
	for i >= 0 && padded[i] == 0 {
		i--
	}
	if i < 0 || padded[i] != 0x02 {
		return nil, errors.New("bad padding")
	}
	return padded[:i], nil
}

// contentKeys derives the AES-128-GCM key and nonce (RFC 8291 section 3.4).
func contentKeys(shared, auth, salt, receiverPublic, senderPublic []byte) (cipher.AEAD, []byte, error) {
	keyInfo := append(append([]byte("WebPush: info\x00"), receiverPublic...), senderPublic...)
	ikm, err := hkdf.Key(sha256.New, shared, auth, string(keyInfo), 32)
	if err != nil {
		return nil, nil, err
	}
	cek, err := hkdf.Key(sha256.New, ikm, salt, "Content-Encoding: aes128gcm\x00", 16)
	if err != nil {
		return nil, nil, err
	}
	nonce, err := hkdf.Key(sha256.New, ikm, salt, "Content-Encoding: nonce\x00", 12)
	if err != nil {
		return nil, nil, err
	}
	block, err := aes.NewCipher(cek)
	if err != nil {
		return nil, nil, err
	}
	gcm, err := cipher.NewGCM(block)
	return gcm, nonce, err
}
