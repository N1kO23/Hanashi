package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"

	"hanashi/server/internal/federation"
	"hanashi/server/internal/protocol"
	"hanashi/server/internal/push"
	"hanashi/server/internal/store"
)

// Federation: what other servers ask of this one, and what this one tells
// them (see "Federation" in docs/protocol.md). Every request between servers
// is signed by the server it comes from.

// At most this many unanswered contact requests from the users of one other
// server.
const maxRequestsFromServer = 1000

// Item types.
const (
	itemContactRequest = "contact.request"
	itemContactAccept  = "contact.accept"
	itemContactCancel  = "contact.cancel"
	itemContactRemove  = "contact.remove"
	itemKeysChanged    = "user.keys_changed"
	itemDeviceMessage  = "inbox.message"
)

func hostOf(userID string) string { return userID[strings.LastIndex(userID, "@")+1:] }

// remote reports whether userID is a user of another server.
func (a *API) remote(userID string) bool {
	return protocol.ValidUserID(userID) && hostOf(userID) != a.cfg.Host
}

// tellServer queues item for the server of user, a user of another server,
// and returns what sends it once the transaction is committed.
func (a *API) tellServer(tx *store.Tx, user string, item map[string]any) (func(), error) {
	host := hostOf(user)
	if err := federation.Enqueue(tx, host, item); err != nil {
		return nil, err
	}
	return func() { a.fed.Wake(host) }, nil
}

// tellContactItem tells to's server what from, a user of this server, did.
func (a *API) tellContactItem(tx *store.Tx, typ, from, to string) (func(), error) {
	return a.tellServer(tx, to, map[string]any{"type": typ, "from": from, "to": to})
}

// remoteError is what another server's answer, or its silence, means to an
// app.
func remoteError(err error) error {
	var fedErr *federation.Error
	switch {
	case errors.Is(err, federation.ErrNotAllowed):
		return errOtherServer
	case errors.As(err, &fedErr) && fedErr.Status == http.StatusTooManyRequests:
		return fedErr // The app tries again later.
	case errors.As(err, &fedErr) && fedErr.Code == "federation_off", errors.As(err, &fedErr) && fedErr.Status == http.StatusForbidden:
		return errOtherServer
	case errors.As(err, &fedErr) && fedErr.Status == http.StatusNotFound:
		return &Error{http.StatusNotFound, fedErr.Code, fedErr.Message}
	default:
		return errServerUnreachable
	}
}

// Asking other servers

// remoteUser checks with their server that a user of another server exists.
func (a *API) remoteUser(ctx context.Context, userID string) error {
	var out struct {
		User string `json:"user"`
	}
	if err := a.fed.Query(ctx, hostOf(userID), "user", map[string]any{"user": userID}, &out); err != nil {
		return remoteError(err)
	}
	if out.User != userID {
		return errServerUnreachable
	}
	return a.store.EnsureRemoteUser(ctx, userID)
}

// remoteUserKeys asks their server for the keys of a user of another server,
// and notes their devices.
func (a *API) remoteUserKeys(ctx context.Context, userID string) (*userKeysJSON, error) {
	var out userKeysJSON
	if err := a.fed.Query(ctx, hostOf(userID), "keys", map[string]any{"user": userID}, &out); err != nil {
		return nil, remoteError(err)
	}
	if out.UserID != userID {
		return nil, errServerUnreachable
	}
	if out.Devices == nil {
		out.Devices = []deviceKeyJSON{}
	}
	ids := make([]string, 0, len(out.Devices))
	for _, d := range out.Devices {
		if !protocol.IsULID(d.DeviceID) {
			return nil, errServerUnreachable
		}
		ids = append(ids, d.DeviceID)
	}
	if err := a.store.EnsureRemoteUser(ctx, userID); err != nil {
		return nil, err
	}
	return &out, a.store.SetRemoteDevices(ctx, userID, ids)
}

// remoteProfile asks their server for the profile record of a user of
// another server, which it gives only to whom it would give it itself.
func (a *API) remoteProfile(ctx context.Context, asker, userID string) (*profileJSON, error) {
	var out profileJSON
	if err := a.fed.Query(ctx, hostOf(userID), "profile", map[string]any{"user": userID, "asker": asker}, &out); err != nil {
		return nil, remoteError(err)
	}
	if out.User != userID {
		return nil, errServerUnreachable
	}
	return &out, nil
}

// Answering other servers

// admitted lets a request from another server in, unless too many from all
// of them are under way already.
func (a *API) admitted(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		release, err := a.fed.Admit()
		if err != nil {
			a.fail(w, r, err)
			return
		}
		defer release()
		h(w, r)
	}
}

func (a *API) federationKey(w http.ResponseWriter, r *http.Request) {
	if !a.fed.Enabled() {
		a.fail(w, r, &Error{http.StatusNotFound, "federation_off", "This server does not federate"})
		return
	}
	writeJSON(w, http.StatusOK, a.fed.KeyDocument())
}

func (a *API) federationQuery(w http.ResponseWriter, r *http.Request) {
	if err := a.answerQuery(w, r); err != nil {
		a.fail(w, r, err)
	}
}

// answerQuery answers what another server asks about a user of this one.
func (a *API) answerQuery(w http.ResponseWriter, r *http.Request) error {
	origin, body, err := a.fed.Verify(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	if r.PathValue("kind") == "server" {
		about, err := a.aboutThisServer()
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, about)
		return nil
	}
	if kind := r.PathValue("kind"); strings.HasPrefix(kind, "conv.") || kind == "claim" {
		var out any
		if kind == "claim" {
			out, err = a.answerClaim(ctx, origin, body)
		} else {
			out, err = a.answerConvQuery(ctx, origin, kind, body)
		}
		if err != nil {
			return err
		}
		a.log.Debug("federation: query answered", "origin", origin, "kind", kind)
		writeJSON(w, http.StatusOK, out)
		return nil
	}
	var req struct {
		User  string `json:"user"`
		Asker string `json:"asker"`
	}
	if err := json.Unmarshal(body, &req); err != nil || !protocol.ValidUserID(req.User) || a.remote(req.User) {
		return &Error{http.StatusNotFound, "user_not_found", ""}
	}
	switch kind := r.PathValue("kind"); kind {
	case "user":
		if _, err := a.store.User(ctx, req.User); errors.Is(err, store.ErrNotFound) {
			return &Error{http.StatusNotFound, "user_not_found", ""}
		} else if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, map[string]string{"user": req.User})
	case "keys":
		out, err := a.localUserKeys(ctx, req.User)
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, out)
	case "profile":
		if !protocol.ValidUserID(req.Asker) || hostOf(req.Asker) != origin {
			return badRequest("asker must be a user of the server asking")
		}
		out, err := a.localProfile(ctx, req.Asker, req.User)
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, out)
	default:
		return errNotFound
	}
	a.log.Debug("federation: query answered", "origin", origin, "kind", r.PathValue("kind"), "user", req.User)
	return nil
}

func (a *API) federationSend(w http.ResponseWriter, r *http.Request) {
	if err := a.receiveTransaction(w, r); err != nil {
		a.fail(w, r, err)
	}
}

// receiveTransaction applies what another server tells, in order and each
// item once: a transaction sent again after its answer was lost changes
// nothing. An item refused is answered as such, and not sent again.
func (a *API) receiveTransaction(w http.ResponseWriter, r *http.Request) error {
	origin, body, err := a.fed.Verify(r)
	if err != nil {
		return err
	}
	stream, items, raws, err := federation.ParseTransaction(body)
	if err != nil {
		return err
	}
	refused := []federation.Refusal{}
	err = a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		refused = refused[:0]
		known, last, err := tx.FederationCursor(origin)
		if err != nil {
			return nil, err
		}
		if known != stream {
			last = 0 // Its server's database started again.
		}
		var publish []func()
		for i, item := range items {
			if item.ID <= last {
				continue
			}
			done, err := a.applyItem(tx, origin, item, raws[i])
			var apiErr *Error
			if errors.As(err, &apiErr) {
				a.log.Info("federation: item refused", "origin", origin, "item", item.ID, "type", item.Type,
					"error", apiErr.Code)
				refused = append(refused, federation.Refusal{ID: item.ID, Error: apiErr.Code})
			} else if err != nil {
				return nil, err
			}
			publish = append(publish, done...)
			last = item.ID
		}
		a.log.Debug("federation: transaction applied", "origin", origin, "items", len(items), "last", last)
		return func() {
			for _, p := range publish {
				p()
			}
		}, tx.SetFederationCursor(origin, stream, last)
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"refused": refused})
	return nil
}

// applyItem carries out what a user of origin did to a user of this server,
// as this server would had both been its own. What it cannot take it refuses
// with an *Error, before changing anything.
func (a *API) applyItem(tx *store.Tx, origin string, item federation.Item, raw json.RawMessage) ([]func(), error) {
	switch item.Type {
	case itemConvEvent:
		var it convEventItem
		if err := json.Unmarshal(raw, &it); err != nil || !protocol.IsULID(it.Conv) || it.Seq <= 0 || it.Event.Type == "" {
			return nil, badRequest("Not an event of a conversation")
		}
		return a.takeConvEvent(tx, origin, it)
	case itemDeviceMessage:
		var m deviceMessageItem
		if err := json.Unmarshal(raw, &m); err != nil {
			return nil, badRequest("Not a device message")
		}
		return a.takeDeviceMessage(tx, origin, m)
	case itemWelcome:
		var w welcomeItem
		if err := json.Unmarshal(raw, &w); err != nil || !protocol.IsULID(w.Conv) || w.Data == "" {
			return nil, badRequest("Not a Welcome")
		}
		return a.takeWelcome(tx, origin, w)
	case itemMessagesDeleted:
		var d struct {
			User string   `json:"user"`
			IDs  []string `json:"ids"`
		}
		if err := json.Unmarshal(raw, &d); err != nil || !protocol.ValidUserID(d.User) || hostOf(d.User) != origin ||
			len(d.IDs) > 100 {
			return nil, badRequest("user must be a user of the server that sends it")
		}
		_, _, err := tx.DeleteMessages(d.User, d.IDs)
		return nil, err
	case itemContactRequest, itemContactAccept, itemContactCancel, itemContactRemove:
		if !protocol.ValidUserID(item.From) || hostOf(item.From) != origin {
			return nil, badRequest("from must be a user of the server that sends it")
		}
		if !protocol.ValidUserID(item.To) || a.remote(item.To) {
			return nil, &Error{http.StatusNotFound, "user_not_found", ""}
		}
		if _, err := tx.User(item.To); errors.Is(err, store.ErrNotFound) {
			return nil, &Error{http.StatusNotFound, "user_not_found", ""}
		} else if err != nil {
			return nil, err
		}
		if err := tx.EnsureRemoteUser(item.From); err != nil {
			return nil, err
		}
	case itemKeysChanged:
		if !protocol.ValidUserID(item.User) || hostOf(item.User) != origin {
			return nil, badRequest("user must be a user of the server that sends it")
		}
	default:
		return nil, &Error{http.StatusBadRequest, "unknown_item", "Items of type " + item.Type + " are not known here"}
	}
	switch item.Type {
	case itemContactRequest:
		return a.remoteAsked(tx, origin, item.From, item.To)
	case itemContactAccept:
		return a.remoteAccepted(tx, item.From, item.To)
	case itemContactCancel:
		return a.remoteWithdrew(tx, item.From, item.To)
	case itemContactRemove:
		return a.remoteEnded(tx, item.From, item.To)
	default:
		return a.remoteKeysChanged(tx, item.User)
	}
}

// remoteAsked: asker, of origin, asks asked, of this server. This server
// decides what comes of it, as asked's server, with the same rules as when
// both are its own (requestContact).
func (a *API) remoteAsked(tx *store.Tx, origin, asker, asked string) ([]func(), error) {
	mine, err := tx.ContactState(asked, asker)
	if err != nil {
		return nil, err
	}
	theirs, err := tx.ContactState(asker, asked)
	if err != nil {
		return nil, err
	}
	switch {
	case mine == store.ContactBlocked, theirs == store.ContactWithdrawn:
		// Asking someone who blocked you, or again after having been told no,
		// reaches nobody.
		return nil, tx.SetContactState(asker, asked, store.ContactDeclined)
	case theirs == store.ContactRequested || theirs == store.ContactDeclined:
		return nil, nil // Asked before.
	case mine == store.ContactAccepted || mine == store.ContactRequested:
		// Contacts already, which their server has to hear again; or both
		// asked at once, which is a yes from both.
		return a.becomeContacts(tx, asked, asker)
	}
	n, err := tx.RequestsFrom(origin)
	if err != nil {
		return nil, err
	}
	if n >= maxRequestsFromServer {
		return nil, &Error{http.StatusTooManyRequests, "too_many_requests", "Too many requests from that server are unanswered"}
	}
	if err := tx.SetContactState(asker, asked, store.ContactRequested); err != nil {
		return nil, err
	}
	tell, err := a.tellContact(tx, asked, asker, push.NewMessage)
	return []func(){tell}, err
}

// becomeContacts makes user, of this server, and other, of another, contacts,
// and tells other's server so.
func (a *API) becomeContacts(tx *store.Tx, user, other string) ([]func(), error) {
	mine, err := tx.ContactState(user, other)
	if err != nil {
		return nil, err
	}
	if err := tx.SetContactState(user, other, store.ContactAccepted); err != nil {
		return nil, err
	}
	if err := tx.SetContactState(other, user, store.ContactAccepted); err != nil {
		return nil, err
	}
	var publish []func()
	if mine != store.ContactAccepted {
		tell, err := a.tellContact(tx, user, other, push.NewMessage)
		if err != nil {
			return nil, err
		}
		publish = append(publish, tell)
	}
	send, err := a.tellContactItem(tx, itemContactAccept, user, other)
	return append(publish, send), err
}

// remoteAccepted: accepter, of another server, said yes to asker, of this one.
func (a *API) remoteAccepted(tx *store.Tx, accepter, asker string) ([]func(), error) {
	mine, err := tx.ContactState(asker, accepter)
	if err != nil {
		return nil, err
	}
	switch mine {
	case store.ContactAccepted:
		return nil, tx.SetContactState(accepter, asker, store.ContactAccepted)
	case store.ContactRequested:
		if err := tx.SetContactState(asker, accepter, store.ContactAccepted); err != nil {
			return nil, err
		}
		if err := tx.SetContactState(accepter, asker, store.ContactAccepted); err != nil {
			return nil, err
		}
		tell, err := a.tellContact(tx, asker, accepter, push.NewMessage)
		return []func(){tell}, err
	}
	// The asker no longer asks (took it back, or blocked them since): to the
	// one who said yes, it ended.
	send, err := a.tellContactItem(tx, itemContactRemove, asker, accepter)
	return []func(){send}, err
}

// remoteWithdrew: asker, of another server, took back their request to
// asked, of this one (cancelContactRequest).
func (a *API) remoteWithdrew(tx *store.Tx, asker, asked string) ([]func(), error) {
	theirs, err := tx.ContactState(asker, asked)
	if err != nil {
		return nil, err
	}
	switch theirs {
	case store.ContactRequested:
		if err := tx.DeleteContactState(asker, asked); err != nil {
			return nil, err
		}
		tell, err := a.tellContact(tx, asked, asker, 0)
		return []func(){tell}, err
	case store.ContactDeclined:
		return nil, tx.SetContactState(asker, asked, store.ContactWithdrawn)
	}
	return nil, nil
}

// remoteEnded: other, of another server, is no longer user's contact.
func (a *API) remoteEnded(tx *store.Tx, other, user string) ([]func(), error) {
	mine, err := tx.ContactState(user, other)
	if err != nil {
		return nil, err
	}
	theirs, err := tx.ContactState(other, user)
	if err != nil {
		return nil, err
	}
	if mine != store.ContactAccepted && theirs != store.ContactAccepted {
		return nil, nil
	}
	if mine == store.ContactAccepted {
		if err := tx.DeleteContactState(user, other); err != nil {
			return nil, err
		}
	}
	if err := tx.DeleteContactState(other, user); err != nil {
		return nil, err
	}
	tell, err := a.tellContact(tx, user, other, 0)
	return []func(){tell}, err
}

// remoteKeysChanged tells user's contacts and conversation peers here that
// user's keys changed.
func (a *API) remoteKeysChanged(tx *store.Tx, user string) ([]func(), error) {
	contacts, err := tx.ContactsOfRemoteUser(user)
	if err != nil {
		return nil, err
	}
	peers, err := tx.ConversationPeers(user)
	if err != nil {
		return nil, err
	}
	for _, p := range peers {
		if p != user && !a.remote(p) && !slices.Contains(contacts, p) {
			contacts = append(contacts, p)
		}
	}
	data := eventData(map[string]string{"user": user})
	var publish []func()
	for _, c := range contacts {
		ev, err := tx.AppendEvent("", protocol.EventDeviceKeysChanged, data, store.AppendOptions{TargetUser: c})
		if err != nil {
			return nil, err
		}
		publish = append(publish, func() { a.hub.Publish(ev, []string{c}) })
	}
	return publish, nil
}

// answerClaim gives a user of another server key packages of devices of this
// one's users, by the same rule as for its own (claimKeyPackages).
func (a *API) answerClaim(ctx context.Context, origin string, body []byte) (any, error) {
	var req struct {
		Asker   string   `json:"asker"`
		Devices []string `json:"devices"`
	}
	if err := json.Unmarshal(body, &req); err != nil || !protocol.ValidUserID(req.Asker) || hostOf(req.Asker) != origin {
		return nil, badRequest("asker must be a user of the server asking")
	}
	if len(req.Devices) > maxWelcomes {
		return nil, badRequest("too many devices")
	}
	out := map[string]string{}
	allowed := map[string]bool{}
	for _, d := range req.Devices {
		owner, err := a.store.SessionOwner(ctx, d)
		if errors.Is(err, store.ErrNotFound) {
			continue
		} else if err != nil {
			return nil, err
		}
		ok, seen := allowed[owner]
		if !seen {
			if ok, err = a.store.MayClaimPackagesOf(ctx, req.Asker, owner); err != nil {
				return nil, err
			}
			allowed[owner] = ok
		}
		if !ok {
			return nil, errNotAContact
		}
		data, err := a.store.ClaimKeyPackage(ctx, d)
		if errors.Is(err, store.ErrNotFound) {
			continue
		} else if err != nil {
			return nil, err
		}
		out[d] = data
	}
	return map[string]any{"packages": out}, nil
}

// claimRemote claims, from their server, key packages of devices of users of
// host for asker.
func (a *API) claimRemote(ctx context.Context, asker, host string, devices []string) (map[string]string, error) {
	var out struct {
		Packages map[string]string `json:"packages"`
	}
	if err := a.fed.Query(ctx, host, "claim", map[string]any{"asker": asker, "devices": devices}, &out); err != nil {
		var fedErr *federation.Error
		if errors.As(err, &fedErr) && fedErr.Code == "not_a_contact" {
			return nil, errNotAContact
		}
		return nil, remoteError(err)
	}
	return out.Packages, nil
}
