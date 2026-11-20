package api

import (
	"crypto/ecdh"
	"encoding/base64"
	"net/http"
	"net/url"

	"hanashi/server/internal/store"
)

// putPushSubscription stores where to wake the calling device: a Web Push
// endpoint from its UnifiedPush distributor (or FCM), with the keys to
// encrypt for it.
func (a *API) putPushSubscription(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Endpoint string `json:"endpoint"`
		Keys     *struct {
			P256dh string `json:"p256dh"`
			Auth   string `json:"auth"`
		} `json:"keys"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	u, err := url.Parse(req.Endpoint)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || len(req.Endpoint) > 2048 {
		return badRequest("endpoint must be an http(s) URL of at most 2048 characters")
	}
	sub := store.PushSubscription{DeviceID: c.SessionID, UserID: c.UserID, Endpoint: req.Endpoint}
	if req.Keys != nil {
		key, err1 := base64.RawURLEncoding.DecodeString(req.Keys.P256dh)
		auth, err2 := base64.RawURLEncoding.DecodeString(req.Keys.Auth)
		if err1 != nil || err2 != nil || len(auth) != 16 {
			return badRequest("keys must be base64url: a P-256 point and a 16-byte auth secret")
		}
		if _, err := ecdh.P256().NewPublicKey(key); err != nil {
			return badRequest("keys.p256dh is not a P-256 point")
		}
		sub.P256dh, sub.Auth = req.Keys.P256dh, req.Keys.Auth
	}
	if err := a.store.PutPushSubscription(r.Context(), sub); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

func (a *API) deletePushSubscription(w http.ResponseWriter, r *http.Request, c *Caller) error {
	if err := a.store.DeletePushSubscription(r.Context(), c.SessionID, ""); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}
