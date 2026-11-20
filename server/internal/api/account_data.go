package api

import (
	"errors"
	"net/http"
	"regexp"

	"hanashi/server/internal/protocol"
	"hanashi/server/internal/store"
)

const maxAccountDataBytes = 256 * 1024

var accountDataName = regexp.MustCompile(`^[a-z0-9._-]{1,64}$`)

func accountDataNameOf(r *http.Request) (string, error) {
	name := r.PathValue("name")
	if !accountDataName.MatchString(name) {
		return "", badRequest("Names are 1-64 characters: a-z, 0-9, \".\", \"_\" or \"-\"")
	}
	return name, nil
}

func (a *API) getAccountData(w http.ResponseWriter, r *http.Request, c *Caller) error {
	name, err := accountDataNameOf(r)
	if err != nil {
		return err
	}
	data, version, err := a.store.AccountData(r.Context(), c.UserID, name)
	if errors.Is(err, store.ErrNotFound) {
		return &Error{http.StatusNotFound, "not_found", "No such account data"}
	} else if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"data": data, "version": version})
	return nil
}

// putAccountData stores one of the caller's blobs, if it is still at the
// version the device read, and tells their other devices, which then fetch it.
func (a *API) putAccountData(w http.ResponseWriter, r *http.Request, c *Caller) error {
	name, err := accountDataNameOf(r)
	if err != nil {
		return err
	}
	var req struct {
		Data    string `json:"data"`
		Version int64  `json:"version"`
	}
	if err := readJSONLimit(w, r, &req, 2*maxAccountDataBytes); err != nil {
		return err
	}
	if req.Data == "" || len(req.Data) > maxAccountDataBytes {
		return badRequest("data must be a non-empty string of at most 256 KiB")
	}
	version, err := a.store.PutAccountData(r.Context(), c.UserID, name, req.Data, req.Version)
	if errors.Is(err, store.ErrVersionConflict) {
		return &Error{http.StatusConflict, "version_conflict", "It changed on another device; read it again"}
	} else if err != nil {
		return err
	}
	a.hub.SendToOtherDevices(c.UserID, c.SessionID, map[string]any{"type": protocol.FrameAccountData, "name": name})
	writeJSON(w, http.StatusOK, map[string]int64{"version": version})
	return nil
}
