// Package api serves the REST and WebSocket API described in docs/protocol.md.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/oklog/ulid/v2"

	"hanashi/server/internal/auth"
	"hanashi/server/internal/config"
	"hanashi/server/internal/federation"
	"hanashi/server/internal/hub"
	"hanashi/server/internal/livekit"
	"hanashi/server/internal/media"
	"hanashi/server/internal/protocol"
	"hanashi/server/internal/push"
	"hanashi/server/internal/store"
)

const Version = "1.0.3"

const (
	snapshotMessages = 30
	maxJSONBody      = 256 * 1024
)

type API struct {
	cfg     config.Config
	store   *store.Store
	hub     *hub.Hub
	media   *media.Store
	push    *push.Pusher
	fed     *federation.Federation
	log     *slog.Logger
	mux     *http.ServeMux
	touched sync.Map // session ID -> time.Time of the last last_seen update
	// Relayed requests waiting for a conversation's copy here to move on, and
	// the conversations whose copy is catching up.
	mirrors    mirrorWaiters
	catchingUp sync.Map
	// Files being fetched from other servers: hash -> what closes when done.
	mediaFetches sync.Map
	// calls is LiveKit's room API, when the server carries calls; liveKitOps
	// are the calls to it under way.
	calls      *livekit.Client
	liveKitOps sync.WaitGroup
}

func New(cfg config.Config, st *store.Store, h *hub.Hub, m *media.Store, p *push.Pusher, fed *federation.Federation,
	log *slog.Logger) *API {
	a := &API{cfg: cfg, store: st, hub: h, media: m, push: p, fed: fed, log: log, mux: http.NewServeMux()}
	if cfg.Calls() {
		a.calls = &livekit.Client{URL: cfg.LiveKitAPIURL, Keys: a.liveKitKeys(), HTTP: &http.Client{Timeout: 10 * time.Second}}
	}
	a.routes()
	return a
}

// clientTooOld reports an app below the minimum client level. GET /server stays
// open to all, a WebSocket says its level in its auth frame, and other servers
// are no apps.
func (a *API) clientTooOld(r *http.Request) bool {
	if r.URL.Path == "/server" || r.URL.Path == "/ws" || r.URL.Path == liveKitWebhookPath ||
		strings.HasPrefix(r.URL.Path, federation.Prefix) {
		return false
	}
	level, _ := strconv.Atoi(r.Header.Get(protocol.ClientHeader))
	return level < a.cfg.MinClient
}

// ServeHTTP handles a request and logs it: who sent it (once known) and,
// if it failed, the error code (and at debug level the message).
func (a *API) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	entry := &requestLog{}
	rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
	r = r.WithContext(context.WithValue(r.Context(), requestLogKey{}, entry))
	if a.clientTooOld(r) {
		a.fail(rec, r, errClientTooOld)
	} else {
		a.mux.ServeHTTP(rec, r)
	}
	attrs := []any{"method", r.Method, "path", r.URL.Path, "status", rec.status,
		"duration", time.Since(start).Round(time.Microsecond)}
	if c := entry.caller; c != nil {
		attrs = append(attrs, "user", c.UserID, "device", c.SessionID)
	}
	if e := entry.err; e != nil {
		attrs = append(attrs, "error", e.Code)
		if e.Message != "" && a.log.Enabled(r.Context(), slog.LevelDebug) {
			attrs = append(attrs, "message", e.Message)
		}
	}
	a.log.Info("request", attrs...)
}

// requestLog collects what a request's log line says besides its method and
// path; handlers fill it in through the request context.
type requestLog struct {
	caller *Caller
	err    *Error
}

type requestLogKey struct{}

func requestLogOf(ctx context.Context) *requestLog {
	entry, _ := ctx.Value(requestLogKey{}).(*requestLog)
	if entry == nil {
		return &requestLog{}
	}
	return entry
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// Unwrap lets http.ResponseController reach the underlying writer (the
// WebSocket handshake needs to hijack it).
func (r *statusRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

func (a *API) routes() {
	a.mux.HandleFunc("GET /server", a.serverInfo)
	a.mux.HandleFunc("GET /integrations", a.authed(a.integrations))
	a.mux.HandleFunc("POST /auth/register", a.register)
	a.mux.HandleFunc("POST /auth/login", a.login)
	a.mux.HandleFunc("POST /auth/logout", a.authed(a.logout))
	a.mux.HandleFunc("GET /devices", a.authed(a.devices))
	a.mux.HandleFunc("DELETE /devices/{id}", a.authed(a.revokeDevice))
	a.mux.HandleFunc("GET /users/{id}", a.authed(a.user))
	a.mux.HandleFunc("GET /users/{id}/profile", a.authed(a.getProfile))
	a.mux.HandleFunc("PUT /profile", a.authed(a.putProfile))
	a.mux.HandleFunc("GET /contacts", a.authed(a.listContacts))
	a.mux.HandleFunc("POST /contacts/requests", a.authed(a.requestContact))
	a.mux.HandleFunc("POST /contacts/requests/{user}/accept", a.authed(a.acceptContact))
	a.mux.HandleFunc("POST /contacts/requests/{user}/decline", a.authed(a.declineContact))
	a.mux.HandleFunc("DELETE /contacts/requests/{user}", a.authed(a.cancelContactRequest))
	a.mux.HandleFunc("DELETE /contacts/{user}", a.authed(a.removeContact))
	a.mux.HandleFunc("PUT /blocked/{user}", a.authed(a.blockContact))
	a.mux.HandleFunc("DELETE /blocked/{user}", a.authed(a.unblockContact))
	a.mux.HandleFunc("GET /presence", a.authed(a.getPresence))
	a.mux.HandleFunc("PUT /presence", a.authed(a.putPresence))
	a.mux.HandleFunc("GET /account-data/{name}", a.authed(a.getAccountData))
	a.mux.HandleFunc("PUT /account-data/{name}", a.authed(a.putAccountData))
	a.mux.HandleFunc("GET /sync", a.authed(a.sync))
	a.mux.HandleFunc("POST /conversations", a.authed(a.createConversation))
	a.mux.HandleFunc("GET /conversations/{id}/messages", a.authed(a.history))
	a.mux.HandleFunc("POST /conversations/{id}/members", a.authed(a.addMember))
	a.mux.HandleFunc("POST /conversations/{id}/leave", a.authed(a.leave))
	a.mux.HandleFunc("POST /conversations/{id}/read", a.authed(a.markReadHTTP))
	a.mux.HandleFunc("POST /messages", a.authed(a.postMessageHTTP))
	a.mux.HandleFunc("POST /messages/delete", a.authed(a.deleteMessages))
	a.mux.HandleFunc("POST /media", a.authed(a.upload))
	a.mux.HandleFunc("GET /media/{hash}", a.authed(a.download))
	a.mux.HandleFunc("PUT /keys/identity", a.authed(a.putIdentity))
	a.mux.HandleFunc("PUT /keys/device", a.authed(a.putDeviceKey))
	a.mux.HandleFunc("PUT /keys/devices/{id}/signature", a.authed(a.putDeviceSignature))
	a.mux.HandleFunc("GET /keys/users/{id}", a.authed(a.getUserKeys))
	a.mux.HandleFunc("GET /keys/secret-storage", a.authed(a.getSecretStorage))
	a.mux.HandleFunc("PUT /keys/secret-storage", a.authed(a.putSecretStorage))
	a.mux.HandleFunc("POST /keys/backup", a.authed(a.putKeyBackup))
	a.mux.HandleFunc("POST /keys/backup/query", a.authed(a.queryKeyBackup))
	a.mux.HandleFunc("GET /keys/backup", a.authed(a.conversationKeyBackup))
	a.mux.HandleFunc("POST /conversations/{id}/lease", a.authed(a.acquireLease))
	a.mux.HandleFunc("DELETE /conversations/{id}/lease/{lease}", a.authed(a.releaseLease))
	a.mux.HandleFunc("POST /conversations/{id}/commits", a.authed(a.commitHTTP))
	a.mux.HandleFunc("GET /conversations/{id}/group-info", a.authed(a.groupInfo))
	a.mux.HandleFunc("PUT /conversations/{id}/state", a.authed(a.putGroupState))
	a.mux.HandleFunc("POST /keys/packages", a.authed(a.uploadKeyPackages))
	a.mux.HandleFunc("GET /keys/packages/count", a.authed(a.keyPackageCount))
	a.mux.HandleFunc("POST /keys/packages/claim", a.authed(a.claimKeyPackages))
	a.mux.HandleFunc("GET /inbox", a.authed(a.inbox))
	a.mux.HandleFunc("POST /inbox/ack", a.authed(a.ackInbox))
	a.mux.HandleFunc("POST /inbox/send", a.authed(a.sendToDevices))
	a.mux.HandleFunc("GET /keys/attestations", a.authed(a.getAttestations))
	a.mux.HandleFunc("PUT /keys/attestations/{user}", a.authed(a.putAttestation))
	a.mux.HandleFunc("PUT /push/subscription", a.authed(a.putPushSubscription))
	a.mux.HandleFunc("DELETE /push/subscription", a.authed(a.deletePushSubscription))
	a.mux.HandleFunc("POST /calls", a.authed(a.postCall))
	a.mux.HandleFunc("GET /calls", a.authed(a.getCalls))
	a.mux.HandleFunc("POST /calls/{id}/decline", a.authed(a.declineCall))
	a.mux.HandleFunc("POST /calls/{id}/leave", a.authed(a.leaveCall))
	a.mux.HandleFunc("POST "+liveKitWebhookPath, a.liveKitWebhook)
	a.mux.HandleFunc("GET /ws", a.webSocket)
	a.mux.HandleFunc("GET "+federation.Prefix+"key", a.federationKey)
	a.mux.HandleFunc("POST "+federation.Prefix+"send", a.admitted(a.federationSend))
	a.mux.HandleFunc("POST "+federation.Prefix+"query/{kind}", a.admitted(a.federationQuery))
	a.mux.HandleFunc("POST "+federation.Prefix+"media", a.admitted(a.federationMedia))
	a.mux.HandleFunc("POST "+federation.Prefix+"ephemeral", a.admitted(a.federationEphemeral))
}

// Errors

// Error is an API error with a stable machine-readable code.
type Error struct {
	Status  int
	Code    string
	Message string
}

func (e *Error) Error() string { return fmt.Sprintf("%d %s: %s", e.Status, e.Code, e.Message) }

func badRequest(msg string) *Error { return &Error{http.StatusBadRequest, "bad_request", msg} }

var (
	errUnauthorized      = &Error{http.StatusUnauthorized, "unauthorized", ""}
	errClientTooOld      = &Error{http.StatusUpgradeRequired, "client_too_old", "This version of the app is too old for this server. Update it to go on"}
	errNotFound          = &Error{http.StatusNotFound, "not_found", ""}
	errTooLarge          = &Error{http.StatusRequestEntityTooLarge, "too_large", "The upload is too large"}
	errNotAContact       = &Error{http.StatusForbidden, "not_a_contact", "Only your contacts can do that"}
	errOtherServer       = &Error{http.StatusNotFound, "other_server", "Users on that server can't be reached from this one"}
	errServerUnreachable = &Error{http.StatusBadGateway, "server_unreachable", "Their server can't be reached right now"}
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// fail converts any error into a JSON error response; unexpected errors are
// logged and reported as 500 without details.
func (a *API) fail(w http.ResponseWriter, r *http.Request, err error) {
	apiErr := a.toAPIError(err)
	if apiErr.Status == http.StatusInternalServerError {
		a.log.Error("request failed", "method", r.Method, "path", r.URL.Path, "err", err)
	}
	requestLogOf(r.Context()).err = apiErr
	if fedErr := (*federation.Error)(nil); errors.As(err, &fedErr) && fedErr.RetryAfter > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(fedErr.RetryAfter.Seconds()))))
	}
	body := map[string]string{"error": apiErr.Code}
	if apiErr.Message != "" {
		body["message"] = apiErr.Message
	}
	writeJSON(w, apiErr.Status, body)
}

func (a *API) toAPIError(err error) *Error {
	var apiErr *Error
	var fedErr *federation.Error
	var formatErr *protocol.FormatError
	var maxBytes *http.MaxBytesError
	switch {
	case errors.As(err, &apiErr):
		return apiErr
	case errors.As(err, &fedErr):
		return &Error{fedErr.Status, fedErr.Code, fedErr.Message}
	case errors.As(err, &formatErr):
		return badRequest(formatErr.Msg)
	case errors.As(err, &maxBytes):
		return errTooLarge
	case errors.Is(err, store.ErrNotFound):
		return errNotFound
	default:
		return &Error{http.StatusInternalServerError, "internal", ""}
	}
}

func readJSON(w http.ResponseWriter, r *http.Request, v any) error {
	return readJSONLimit(w, r, v, maxJSONBody)
}

func readJSONLimit(w http.ResponseWriter, r *http.Request, v any, limit int64) error {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(v); err != nil {
		var maxBytes *http.MaxBytesError
		if errors.As(err, &maxBytes) {
			return errTooLarge
		}
		return badRequest("The body must be a JSON object with the documented fields")
	}
	return nil
}

// Authentication

// Caller is one user on one device.
type Caller struct {
	UserID    string
	SessionID string
	// Log names the user and device on every line.
	Log *slog.Logger
}

func (a *API) authenticate(ctx context.Context, token string) (*Caller, error) {
	if token == "" {
		return nil, errUnauthorized
	}
	sess, err := a.store.SessionByTokenHash(ctx, auth.HashToken(token))
	if errors.Is(err, store.ErrNotFound) {
		return nil, errUnauthorized
	}
	if err != nil {
		return nil, err
	}
	if last, ok := a.touched.Load(sess.ID); !ok || time.Since(last.(time.Time)) > time.Minute {
		a.touched.Store(sess.ID, time.Now())
		if err := a.store.TouchSession(ctx, sess.ID); err != nil {
			a.log.Warn("updating last_seen failed", "err", err)
		}
	}
	caller := &Caller{UserID: sess.UserID, SessionID: sess.ID, Log: a.log.With("user", sess.UserID, "device", sess.ID)}
	requestLogOf(ctx).caller = caller
	return caller, nil
}

type authedHandler func(w http.ResponseWriter, r *http.Request, c *Caller) error

func (a *API) authed(h authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		caller, err := a.authenticate(r.Context(), token)
		if err == nil {
			err = h(w, r, caller)
		}
		if err != nil {
			a.fail(w, r, err)
		}
	}
}

func (a *API) serverInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, protocol.ServerInfo{
		Host:           a.cfg.Host,
		Version:        Version,
		Registration:   string(a.cfg.Registration),
		MaxUploadBytes: a.cfg.MaxUploadBytes,
		MinClient:      a.cfg.MinClient,
		VAPIDKey:       a.push.VAPID().PublicKey(),
		Source:         a.cfg.SourceURL,
	})
}

// integrations tells signed-in apps about services such as GIF search. Not
// part of /server: the KLIPY key is for this server's users only.
func (a *API) integrations(w http.ResponseWriter, r *http.Request, c *Caller) error {
	writeJSON(w, http.StatusOK, protocol.Integrations{KlipyAPIKey: a.cfg.KlipyAPIKey, Calls: a.cfg.Calls(), Video: a.cfg.Calls()})
	return nil
}

type authRequest struct {
	Name       string `json:"name"`
	Password   string `json:"password"`
	InviteCode string `json:"inviteCode"`
	DeviceName string `json:"deviceName"`
	Platform   string `json:"platform"`
}

func (a *API) register(w http.ResponseWriter, r *http.Request) {
	if err := a.doRegister(w, r); err != nil {
		a.fail(w, r, err)
	}
}

func (a *API) doRegister(w http.ResponseWriter, r *http.Request) error {
	var req authRequest
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	switch a.cfg.Registration {
	case config.RegistrationClosed:
		return &Error{http.StatusForbidden, "registration_closed", "Registration is closed on this server"}
	case config.RegistrationInvite:
		if !a.cfg.InviteCodes[req.InviteCode] {
			return &Error{http.StatusForbidden, "invalid_invite", "A valid invite code is required"}
		}
	}
	name := strings.ToLower(strings.TrimSpace(req.Name))
	if !protocol.ValidName(name) {
		return badRequest(`Names use 1-32 characters: a-z, 0-9, ".", "_" or "-"`)
	}
	if n := utf8.RuneCountInString(req.Password); n < 8 || n > 1024 {
		return badRequest("Passwords need at least 8 characters")
	}
	userID := name + "@" + a.cfg.Host
	errTaken := &Error{http.StatusConflict, "name_taken", "That name is taken"}
	if _, err := a.store.User(r.Context(), userID); err == nil {
		return errTaken
	} else if !errors.Is(err, store.ErrNotFound) {
		return err
	}
	err := a.store.CreateUser(r.Context(), store.User{ID: userID, PasswordHash: auth.HashPassword(req.Password)})
	if store.IsDuplicate(err) {
		return errTaken // Lost a race.
	} else if err != nil {
		return err
	}
	return a.newSession(w, r, userID, req)
}

func (a *API) login(w http.ResponseWriter, r *http.Request) {
	var req authRequest
	err := readJSON(w, r, &req)
	if err == nil {
		name := strings.ToLower(strings.TrimSpace(req.Name))
		var u *store.User
		if protocol.ValidName(name) {
			u, err = a.store.User(r.Context(), name+"@"+a.cfg.Host)
		}
		switch {
		case err != nil && !errors.Is(err, store.ErrNotFound):
		case u == nil || !auth.VerifyPassword(u.PasswordHash, req.Password):
			a.log.Debug("sign-in refused", "name", name)
			err = &Error{http.StatusUnauthorized, "invalid_credentials", "Wrong name or password"}
		default:
			err = a.newSession(w, r, u.ID, req)
		}
	}
	if err != nil {
		a.fail(w, r, err)
	}
}

func (a *API) newSession(w http.ResponseWriter, r *http.Request, userID string, req authRequest) error {
	token := auth.NewToken()
	sess := store.Session{
		ID:         ulid.Make().String(),
		UserID:     userID,
		DeviceName: truncate(strings.TrimSpace(req.DeviceName), 64, "Unknown device"),
		Platform:   truncate(strings.TrimSpace(req.Platform), 32, "unknown"),
	}
	if err := a.store.CreateSession(r.Context(), sess, auth.HashToken(token)); err != nil {
		return err
	}
	requestLogOf(r.Context()).caller = &Caller{UserID: userID, SessionID: sess.ID}
	a.log.Info("signed in", "user", userID, "device", sess.ID, "platform", sess.Platform)
	writeJSON(w, http.StatusOK, protocol.AuthResult{UserID: userID, Token: token, DeviceID: sess.ID})
	return nil
}

func truncate(s string, max int, fallback string) string {
	if s == "" {
		return fallback
	}
	if utf8.RuneCountInString(s) <= max {
		return s
	}
	return string([]rune(s)[:max])
}

func (a *API) logout(w http.ResponseWriter, r *http.Request, c *Caller) error {
	if err := a.store.DeleteSession(r.Context(), c.SessionID, c.UserID); err != nil && !errors.Is(err, store.ErrNotFound) {
		return err
	}
	a.hub.CloseSession(c.UserID, c.SessionID)
	a.dropFromCalls(r.Context(), c.UserID, "", c.SessionID)
	c.Log.Info("signed out")
	if err := a.keysChanged(r.Context(), c.UserID); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

func (a *API) devices(w http.ResponseWriter, r *http.Request, c *Caller) error {
	sessions, err := a.store.SessionsOf(r.Context(), c.UserID)
	if err != nil {
		return err
	}
	out := []protocol.DeviceInfo{}
	for _, s := range sessions {
		out = append(out, protocol.DeviceInfo{
			ID: s.ID, Name: s.DeviceName, Platform: s.Platform,
			CreatedAt: s.CreatedAt, LastSeenAt: s.LastSeenAt, Current: s.ID == c.SessionID,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
	return nil
}

func (a *API) revokeDevice(w http.ResponseWriter, r *http.Request, c *Caller) error {
	id := r.PathValue("id")
	if err := a.store.DeleteSession(r.Context(), id, c.UserID); err != nil {
		return err
	}
	a.touched.Delete(id)
	a.hub.CloseSession(c.UserID, id)
	a.dropFromCalls(r.Context(), c.UserID, "", id)
	c.Log.Info("device revoked", "revoked", id)
	if err := a.keysChanged(r.Context(), c.UserID); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

func (a *API) user(w http.ResponseWriter, r *http.Request, c *Caller) error {
	if id := r.PathValue("id"); a.remote(id) {
		if !a.fed.Allowed(hostOf(id)) {
			return errOtherServer
		}
		if err := a.remoteUser(r.Context(), id); err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": id})
		return nil
	}
	u, err := a.store.User(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		return &Error{http.StatusNotFound, "user_not_found", ""}
	} else if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": u.ID})
	return nil
}

// deleteMessages drops the stored ciphertext of messages the caller deleted
// for everyone, so that devices which come later never get them. The
// deletion itself is an encrypted message the members' devices apply.
func (a *API) deleteMessages(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		IDs []string `json:"ids"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	if len(req.IDs) == 0 || len(req.IDs) > 100 {
		return badRequest("ids must list 1 to 100 messages")
	}
	for _, id := range req.IDs {
		if !protocol.IsULID(id) {
			return badRequest("ids must be message IDs")
		}
	}
	var deleted int
	err := a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		n, convs, err := tx.DeleteMessages(c.UserID, req.IDs)
		if err != nil {
			return nil, err
		}
		deleted = n
		// The servers of members of other servers have copies too.
		return a.tellDeleted(tx, c.UserID, req.IDs, convs)
	})
	if err != nil {
		return err
	}
	c.Log.Debug("messages deleted", "asked", len(req.IDs), "deleted", deleted)
	writeJSON(w, http.StatusOK, map[string]int{"deleted": deleted})
	return nil
}

// Sync

func (a *API) sync(w http.ResponseWriter, r *http.Request, c *Caller) error {
	ctx := r.Context()
	q := r.URL.Query()
	sinceText := q.Get("since")
	if sinceText == "" {
		snapshot, err := a.snapshot(ctx, c.UserID)
		if err != nil {
			return err
		}
		c.Log.Debug("snapshot", "conversations", len(snapshot.Conversations), "cursor", snapshot.Cursor)
		writeJSON(w, http.StatusOK, snapshot)
		return nil
	}
	since, err := strconv.ParseInt(sinceText, 10, 64)
	if err != nil || since < 0 {
		return badRequest("since must be a non-negative integer")
	}
	limit := clampInt(q.Get("limit"), 500, 1, 1000)
	// Read the newest seq *before* querying events. Commits happen in seq
	// order (see store.AppendEvents), so every event up to maxSeq is visible
	// to the query below; reading it afterwards could skip an event that
	// committed in between.
	maxSeq, err := a.store.MaxSeq(ctx)
	if err != nil {
		return err
	}
	events, err := a.store.EventsSince(ctx, c.UserID, since, limit+1)
	if err != nil {
		return err
	}
	more := len(events) > limit
	var cursor int64
	if more {
		events = events[:limit]
		cursor = events[len(events)-1].Seq
	} else {
		// Without more events, jump to maxSeq: events the user cannot see now
		// never become visible later (joining a conversation sends its own
		// member_added event, and older history is fetched separately).
		cursor = maxSeq
		if n := len(events); n > 0 {
			cursor = max(cursor, events[n-1].Seq)
		}
	}
	if a.log.Enabled(ctx, slog.LevelDebug) {
		types := map[string]int{}
		for _, ev := range events {
			types[ev.Type]++
		}
		c.Log.Debug("sync", "since", since, "events", len(events), "types", types, "cursor", max(cursor, since), "more", more)
	}
	writeJSON(w, http.StatusOK, protocol.SyncPage{Events: events, Cursor: max(cursor, since), More: more})
	return nil
}

func (a *API) snapshot(ctx context.Context, userID string) (*protocol.SyncSnapshot, error) {
	cursor, err := a.store.MaxSeq(ctx)
	if err != nil {
		return nil, err
	}
	ids, err := a.store.ConversationIDsOf(ctx, userID)
	if err != nil {
		return nil, err
	}
	snap := &protocol.SyncSnapshot{Cursor: cursor, Conversations: []protocol.ConversationSnapshot{}}
	for _, id := range ids {
		info, err := a.store.Conversation(ctx, id)
		if err != nil {
			return nil, err
		}
		messages, err := a.store.MessagesBefore(ctx, id, cursor+1, snapshotMessages+1)
		if err != nil {
			return nil, err
		}
		more := len(messages) > snapshotMessages
		if more {
			messages = messages[1:]
		}
		readUpTo, err := a.store.ReadUpTo(ctx, id, userID)
		if err != nil {
			return nil, err
		}
		snap.Conversations = append(snap.Conversations, protocol.ConversationSnapshot{
			Conversation: *info, ReadUpTo: readUpTo, Messages: messages, MoreHistory: more,
		})
	}
	return snap, nil
}

func clampInt(text string, fallback, lo, hi int) int {
	v, err := strconv.Atoi(text)
	if err != nil {
		return fallback
	}
	return min(max(v, lo), hi)
}

// Conversations

func (a *API) requireMember(ctx context.Context, convID string, c *Caller) error {
	ok, err := a.store.IsMember(ctx, convID, c.UserID)
	if err != nil {
		return err
	}
	if !ok {
		return errNotFound
	}
	return nil
}

func eventData(v any) json.RawMessage {
	data, _ := json.Marshal(v)
	return data
}

// groupInput is a freshly created MLS group: its epoch, GroupInfo, sealed
// state and the Welcomes for the other devices.
type groupInput struct {
	Epoch     int64          `json:"epoch"`
	GroupInfo string         `json:"groupInfo"`
	State     string         `json:"state"`
	Welcomes  []welcomeInput `json:"welcomes"`
}

func (g *groupInput) validate() error {
	if g == nil {
		return badRequest("mls is required: conversations are end-to-end encrypted")
	}
	if err := decodeBase64(g.GroupInfo, maxMLSBytes, "mls.groupInfo"); err != nil {
		return err
	}
	return validateState(g.State)
}

// insertConversation stores a new conversation with its group. It returns
// what is left to do once the transaction is committed.
func (a *API) insertConversation(tx *store.Tx, c *Caller, id string, members []string, directKey *string, group *groupInput) (*protocol.ConversationInfo, func(), error) {
	if err := tx.CreateConversation(id, c.UserID, members, directKey); store.IsDuplicate(err) {
		return nil, nil, &Error{http.StatusConflict, "id_taken", "That conversation ID is taken"}
	} else if err != nil {
		return nil, nil, err
	}
	if err := tx.SetConversationEpoch(id, group.Epoch); err != nil {
		return nil, nil, err
	}
	if err := tx.PutGroupInfo(id, group.Epoch, group.GroupInfo, group.State); err != nil {
		return nil, nil, err
	}
	info, err := tx.Conversation(id)
	if err != nil {
		return nil, nil, err
	}
	// Welcomes first: to devices of other servers, they go before the event.
	sendWelcomes, err := a.queueWelcomes(tx, c, id, group.Epoch, group.State, group.Welcomes)
	if err != nil {
		return nil, nil, err
	}
	ev, send, err := a.appendConvEvent(tx, id, protocol.EventConversationCreated,
		eventData(map[string]any{"conversation": info, "by": c.UserID}), store.AppendOptions{})
	if err != nil {
		return nil, nil, err
	}
	c.Log.Debug("conversation created", "conv", id, "members", len(members), "epoch", group.Epoch,
		"welcomes", len(group.Welcomes))
	return info, func() {
		sendWelcomes() // Before the event; see acceptedCommit.
		send()
		a.hub.Publish(ev, members)
	}, nil
}

// conversationRequest is what POST /conversations asks for.
type conversationRequest struct {
	// Chosen by the client: it is also the MLS group ID.
	ID      string      `json:"id"`
	Members []string    `json:"members"`
	Direct  bool        `json:"direct"`
	MLS     *groupInput `json:"mls"`
}

func (a *API) createConversation(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req conversationRequest
	if err := readJSONLimit(w, r, &req, 4*maxMLSBytes); err != nil {
		return err
	}
	info, err := a.newConversation(r.Context(), c, req)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, info)
	return nil
}

// newConversation creates a group of the caller and their contacts; or, with
// "direct", the direct chat of the caller and a contact, unless the two have
// one already, which it answers instead (see directChat). A direct chat with a
// user of another server is made at its hub (directHub): here, or there.
func (a *API) newConversation(ctx context.Context, c *Caller, req conversationRequest) (*protocol.ConversationInfo, error) {
	if !protocol.IsULID(req.ID) {
		return nil, badRequest("id must be a ULID chosen by the client")
	}
	if err := req.MLS.validate(); err != nil {
		return nil, err
	}
	var others []string
	for _, m := range req.Members {
		if m != c.UserID && !slices.Contains(others, m) {
			others = append(others, m)
		}
	}
	if len(others) == 0 {
		return nil, badRequest("Add at least one other member")
	}
	if req.Direct && len(others) != 1 {
		return nil, badRequest("A direct chat is of two people")
	}
	across := a.remote(c.UserID) || slices.ContainsFunc(others, a.remote)
	if across && !req.Direct && a.remote(c.UserID) {
		return nil, &Error{http.StatusForbidden, "not_the_hub", "A group is made at its creator's server"}
	}
	for _, id := range others {
		if _, err := a.store.User(ctx, id); errors.Is(err, store.ErrNotFound) {
			return nil, &Error{http.StatusNotFound, "user_not_found", "No user " + id}
		} else if err != nil {
			return nil, err
		}
	}
	if hub := directHub(c.UserID, others[0]); req.Direct && across && hub != a.cfg.Host {
		if a.remote(c.UserID) {
			return nil, &Error{http.StatusForbidden, "not_the_hub", "This server does not order that chat"}
		}
		return a.relayNewChat(ctx, c, hub, req)
	}
	members := append([]string{c.UserID}, others...)

	var info *protocol.ConversationInfo
	err := a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		if err := requireVerified(tx, c); err != nil {
			return nil, err
		}
		// Asking again (the answer got lost) gets what the first time made.
		if by, err := tx.ConversationCreator(req.ID); err == nil {
			if by != c.UserID {
				return nil, &Error{http.StatusConflict, "id_taken", "That conversation ID is taken"}
			}
			c.Log.Debug("conversation asked for again", "conv", req.ID)
			info, err = tx.Conversation(req.ID)
			return nil, err
		} else if !errors.Is(err, store.ErrNotFound) {
			return nil, err
		}
		for _, id := range others {
			if err := requireContact(tx, c.UserID, id); err != nil {
				return nil, err
			}
		}
		var publish func()
		var err error
		if req.Direct {
			info, publish, err = a.directChat(tx, c, others[0], req.ID, req.MLS)
		} else {
			info, publish, err = a.insertConversation(tx, c, req.ID, members, nil, req.MLS)
		}
		return publish, err
	})
	return info, err
}

// relayNewChat makes c's direct chat at hub, the other's server, and answers
// it once this server has its copy.
func (a *API) relayNewChat(ctx context.Context, c *Caller, hub string, req conversationRequest) (*protocol.ConversationInfo, error) {
	a.markWelcomes(ctx, req.MLS.Welcomes)
	var made protocol.ConversationInfo
	if err := a.relay(ctx, c, hub, "conv.create", map[string]any{"request": req}, &made); err != nil {
		return nil, err
	}
	if err := a.waitMirrorOf(ctx, made.ID); err != nil {
		return nil, err
	}
	return a.store.Conversation(ctx, made.ID)
}

func (a *API) history(w http.ResponseWriter, r *http.Request, c *Caller) error {
	ctx := r.Context()
	convID := r.PathValue("id")
	if err := a.requireMember(ctx, convID, c); err != nil {
		return err
	}
	q := r.URL.Query()
	before, err := strconv.ParseInt(q.Get("before"), 10, 64)
	if err != nil {
		maxSeq, err := a.store.MaxSeq(ctx)
		if err != nil {
			return err
		}
		before = maxSeq + 1
	}
	limit := clampInt(q.Get("limit"), 50, 1, 200)
	messages, err := a.store.MessagesBefore(ctx, convID, before, limit+1)
	if err != nil {
		return err
	}
	more := len(messages) > limit
	if more {
		messages = messages[1:]
	}
	c.Log.Debug("history", "conv", convID, "before", before, "messages", len(messages), "more", more)
	writeJSON(w, http.StatusOK, protocol.HistoryPage{Messages: messages, More: more})
	return nil
}

func (a *API) addMember(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		User string `json:"user"`
		// The commit adding the user's devices, with their Welcomes.
		Commit *commitInput `json:"commit"`
	}
	if err := readJSONLimit(w, r, &req, 4*maxMLSBytes); err != nil {
		return err
	}
	if req.Commit == nil {
		return badRequest("commit is required: members are added to the encrypted group")
	}
	info, _, err := a.addMemberTo(r.Context(), c, r.PathValue("id"), req.User, *req.Commit)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, info)
	return nil
}

// addMemberTo adds user to convID with the commit adding their devices, at
// its hub if another server orders it, and answers the commit's seq.
func (a *API) addMemberTo(ctx context.Context, c *Caller, convID, user string, in commitInput) (*protocol.ConversationInfo, int64, error) {
	if err := a.requireMember(ctx, convID, c); err != nil {
		return nil, 0, err
	}
	if hub, err := a.mirrorHub(ctx, convID); err != nil {
		return nil, 0, err
	} else if hub != "" {
		return a.relayAdd(ctx, c, hub, convID, user, in)
	}
	if !protocol.ValidUserID(user) {
		return nil, 0, &Error{http.StatusNotFound, "user_not_found", "No user " + user}
	}
	var info *protocol.ConversationInfo
	var seq int64
	err := a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		current, err := tx.Conversation(convID)
		if err != nil {
			return nil, err
		}
		if current.IsDirect {
			return nil, badRequest("Direct chats cannot gain members")
		}
		if a.remote(user) {
			if err := tx.EnsureRemoteUser(user); err != nil {
				return nil, err
			}
		} else if _, err := tx.User(user); errors.Is(err, store.ErrNotFound) {
			return nil, &Error{http.StatusNotFound, "user_not_found", "No user " + user}
		} else if err != nil {
			return nil, err
		}
		// Whoever is added must be a contact of whoever adds. Of two users of
		// other servers, it is their servers that can tell (relayAdd, and
		// the new member's when it hears).
		if !a.remote(c.UserID) || !a.remote(user) {
			if err := requireContact(tx, c.UserID, user); err != nil {
				return nil, err
			}
		}
		for _, m := range current.Members {
			if m.ID == user {
				return nil, &Error{http.StatusConflict, "already_member", "Already a member"}
			}
		}
		if err := tx.AddMember(convID, user); err != nil {
			return nil, err
		}
		if info, err = tx.Conversation(convID); err != nil {
			return nil, err
		}
		// Their devices' Welcomes first: to another server, they go in that
		// order, and its devices should have them before they hear.
		sendWelcomes, err := a.queueWelcomes(tx, c, convID, in.Epoch+1, in.State, in.Welcomes)
		if err != nil {
			return nil, err
		}
		in.Welcomes = nil
		ev, send, err := a.appendConvEvent(tx, convID, protocol.EventMemberAdded,
			eventData(map[string]any{"conversation": info, "user": user, "by": c.UserID}), store.AppendOptions{})
		if err != nil {
			return nil, err
		}
		members, err := tx.MemberIDs(convID)
		if err != nil {
			return nil, err
		}
		commit, err := a.applyCommit(tx, c, convID, in)
		if err != nil {
			return nil, err
		}
		seq = commit.seq
		c.Log.Debug("member added", "conv", convID, "member", user)
		return func() {
			sendWelcomes()
			send()
			a.hub.Publish(ev, members)
			commit.welcomes()
			commit.event()
		}, nil
	})
	return info, seq, err
}

func (a *API) leave(w http.ResponseWriter, r *http.Request, c *Caller) error {
	if _, err := a.leaveConv(r.Context(), c, r.PathValue("id")); err != nil {
		return err
	}
	a.dropFromCalls(r.Context(), c.UserID, r.PathValue("id"), "")
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

// leaveConv takes c out of convID, at its hub if another server orders it,
// and answers the seq of the event that says so.
func (a *API) leaveConv(ctx context.Context, c *Caller, convID string) (int64, error) {
	if err := a.requireMember(ctx, convID, c); err != nil {
		return 0, err
	}
	if hub, err := a.mirrorHub(ctx, convID); err != nil {
		return 0, err
	} else if hub != "" {
		return a.relayLeave(ctx, c, hub, convID)
	}
	var seq int64
	err := a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		current, err := tx.Conversation(convID)
		if err != nil {
			return nil, err
		}
		if current.IsDirect {
			return nil, badRequest("Direct chats cannot be left")
		}
		// The leaver's server hears of it too, also if nobody of it is left.
		before, err := tx.RemoteMemberHosts(convID, a.cfg.Host)
		if err != nil {
			return nil, err
		}
		if err := tx.RemoveMember(convID, c.UserID); err != nil {
			return nil, err
		}
		c.Log.Debug("left conversation", "conv", convID)
		info, err := tx.Conversation(convID)
		if err != nil {
			return nil, err
		}
		data := eventData(map[string]any{"conversation": info, "user": c.UserID})
		forMembers, send, err := a.appendConvEventTo(tx, convID, protocol.EventMemberRemoved, data, store.AppendOptions{}, before)
		if err != nil {
			return nil, err
		}
		seq = forMembers.Seq
		members, err := tx.MemberIDs(convID)
		if err != nil {
			return nil, err
		}
		if a.remote(c.UserID) {
			// Their own server gives them their copy.
			return func() {
				send()
				a.hub.Publish(forMembers, members)
			}, nil
		}
		// The leaver is no longer a member, so they get their own copy.
		forLeaver, err := tx.AppendEvent(convID, protocol.EventMemberRemoved, data, store.AppendOptions{TargetUser: c.UserID})
		return func() {
			send()
			a.hub.Publish(forMembers, members)
			a.hub.Publish(forLeaver, []string{c.UserID})
		}, err
	})
	return seq, err
}

// markRead moves the caller's read marker forward and tells their devices.
func (a *API) markRead(ctx context.Context, c *Caller, convID string, upTo int64) (int64, error) {
	if err := a.requireMember(ctx, convID, c); err != nil {
		return 0, err
	}
	maxSeq, err := a.store.MaxSeq(ctx)
	if err != nil {
		return 0, err
	}
	if upTo < 0 || upTo > maxSeq {
		return 0, badRequest("upTo is out of range")
	}
	err = a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		advanced, err := tx.AdvanceReadMarker(convID, c.UserID, upTo)
		if err != nil || !advanced {
			return nil, err
		}
		ev, err := tx.AppendEvent(convID, protocol.EventReadMarker,
			eventData(map[string]any{"user": c.UserID, "upTo": upTo}), store.AppendOptions{TargetUser: c.UserID})
		return func() {
			a.hub.Publish(ev, []string{c.UserID})
			a.push.Notify([]string{c.UserID}, c.SessionID, push.ReadElsewhere)
		}, err
	})
	if err != nil {
		return 0, err
	}
	return a.store.ReadUpTo(ctx, convID, c.UserID)
}

func (a *API) markReadHTTP(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		UpTo *int64 `json:"upTo"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	if req.UpTo == nil {
		return badRequest(`"upTo" is required`)
	}
	readUpTo, err := a.markRead(r.Context(), c, r.PathValue("id"), *req.UpTo)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]int64{"readUpTo": readUpTo})
	return nil
}

// Messages

// postMessage stores and fans out a message; retries with the same ID return
// the original seq. Apps send over the WebSocket; POST /messages exists for
// scripts and bots.
func (a *API) postMessage(ctx context.Context, c *Caller, raw []byte) (int64, error) {
	env, err := protocol.ParseEnvelope(raw)
	if err != nil {
		return 0, err
	}
	if env.From != c.UserID || env.Device != c.SessionID {
		return 0, &Error{http.StatusForbidden, "forbidden", `"from" and "device" must be the sender`}
	}
	if hub, err := a.mirrorHub(ctx, env.Conv); err != nil {
		return 0, err
	} else if hub != "" {
		return a.relayMessage(ctx, c, hub, env.Conv, raw)
	}
	var seq int64
	err = a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		if existing, err := tx.MessageByID(env.ID); err == nil {
			if existing.Sender != c.UserID || existing.Conv != env.Conv {
				return nil, &Error{http.StatusConflict, "id_conflict", "Another message has this ID"}
			}
			c.Log.Debug("message stored already", "conv", env.Conv, "id", env.ID, "seq", existing.Seq)
			seq = existing.Seq
			return nil, nil
		} else if !errors.Is(err, store.ErrNotFound) {
			return nil, err
		}
		members, err := tx.MemberIDs(env.Conv)
		if err != nil {
			return nil, err
		}
		if !slices.Contains(members, c.UserID) {
			return nil, errNotFound
		}
		if err := requireVerified(tx, c); err != nil {
			return nil, err
		}
		// A direct chat stays for what was said, but goes quiet with the contact.
		if partner, err := tx.DirectPartner(env.Conv, c.UserID); err != nil {
			return nil, err
		} else if partner != "" {
			if err := requireContact(tx, c.UserID, partner); err != nil {
				return nil, err
			}
		}
		epoch, err := tx.ConversationEpoch(env.Conv)
		if err != nil {
			return nil, err
		}
		if env.Epoch != epoch {
			// Encrypted for an earlier state of the group: a member added since
			// could never read it, one removed since still could. The sender
			// catches up and encrypts it again.
			c.Log.Debug("message refused: other epoch", "conv", env.Conv, "id", env.ID,
				"device_epoch", env.Epoch, "epoch", epoch)
			return nil, &Error{http.StatusConflict, "epoch_mismatch", "The group changed; catch up and send again"}
		}
		eventType, reason := protocol.EventMessage, push.NewMessage
		if env.Type == protocol.TypeMLSControl {
			eventType, reason = protocol.EventControl, push.StateNeeded
		}
		ev, send, err := a.appendConvEvent(tx, env.Conv, eventType, env.Raw, store.AppendOptions{MsgID: env.ID, Sender: c.UserID})
		if err != nil {
			return nil, err
		}
		seq = ev.Seq
		c.Log.Debug("message stored", "conv", env.Conv, "id", env.ID, "type", env.Type, "epoch", epoch, "seq", seq)
		return func() {
			send()
			a.hub.Publish(ev, members)
			others := slices.DeleteFunc(slices.Clone(members), func(m string) bool { return m == c.UserID })
			a.push.Notify(others, "", reason)
		}, nil
	})
	return seq, err
}

func (a *API) postMessageHTTP(w http.ResponseWriter, r *http.Request, c *Caller) error {
	r.Body = http.MaxBytesReader(w, r.Body, protocol.MaxBodyBytes+16*1024)
	var raw json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&raw); err != nil {
		var maxBytes *http.MaxBytesError
		if errors.As(err, &maxBytes) {
			return errTooLarge
		}
		return badRequest("The body must be an envelope")
	}
	seq, err := a.postMessage(r.Context(), c, raw)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]int64{"seq": seq})
	return nil
}

// Media

var mimePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$`)

func (a *API) upload(w http.ResponseWriter, r *http.Request, c *Caller) error {
	if r.ContentLength > a.cfg.MaxUploadBytes {
		return errTooLarge
	}
	hash, size, err := a.media.Save(r.Body, a.cfg.MaxUploadBytes)
	if errors.Is(err, media.ErrTooLarge) {
		return errTooLarge
	} else if err != nil {
		return err
	}
	mime := strings.ToLower(strings.TrimSpace(strings.Split(r.Header.Get("Content-Type"), ";")[0]))
	if !mimePattern.MatchString(mime) {
		mime = "application/octet-stream"
	}
	if err := a.store.AddMedia(r.Context(), store.Media{Hash: hash, Size: size, Mime: mime}, c.UserID); err != nil {
		return err
	}
	c.Log.Debug("media uploaded", "hash", hash, "size", size)
	stored, err := a.store.Media(r.Context(), hash)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"hash": hash, "size": size, "mime": stored.Mime})
	return nil
}

// download serves a blob to any signed-in user who knows its hash (hashes are
// only shared inside messages). Range requests are supported for seeking. One
// a user of another server uploaded comes from their server, the host the
// reference names (see fetchMedia).
func (a *API) download(w http.ResponseWriter, r *http.Request, c *Caller) error {
	hash := r.PathValue("hash")
	if !protocol.IsContentHash(hash) {
		return errNotFound
	}
	if _, err := a.store.Media(r.Context(), hash); errors.Is(err, store.ErrNotFound) {
		if host := r.URL.Query().Get("host"); host != "" && host != a.cfg.Host {
			return a.fetchMedia(w, r, c, hash, host)
		}
	}
	return a.serveMedia(w, r, hash)
}

func (a *API) serveMedia(w http.ResponseWriter, r *http.Request, hash string) error {
	row, err := a.store.Media(r.Context(), hash)
	if err != nil {
		return err
	}
	f, err := os.Open(a.media.Path(hash))
	if errors.Is(err, os.ErrNotExist) {
		return errNotFound
	} else if err != nil {
		return err
	}
	defer f.Close()
	setMediaHeaders(w, row.Mime)
	http.ServeContent(w, r, "", time.Time{}, f)
	return nil
}

func setMediaHeaders(w http.ResponseWriter, mime string) {
	w.Header().Set("Content-Type", mime)
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	// Never let a browser render or run downloaded content inline.
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "sandbox")
}
