package api

import (
	"errors"
	"net/http"
	"slices"
	"strings"

	"hanashi/server/internal/protocol"
	"hanashi/server/internal/push"
	"hanashi/server/internal/store"
)

// Contacts: nobody can reach a user, or spend their key packages, without
// asking first. These gates are for honest servers; clients also check who
// adds them themselves. A request says nothing but who asks.

const maxOutstandingRequests = 50

// requireContact refuses unless the two have accepted each other.
func requireContact(tx *store.Tx, user, other string) error {
	state, err := tx.ContactState(user, other)
	if err != nil {
		return err
	}
	if state != store.ContactAccepted {
		return errNotAContact
	}
	return nil
}

// tellContact appends the event that tells to's devices how they stand with
// about now, and returns what publishes it. With a reason, it wakes them too.
// A user of another server hears of it from their own (tellContactItem).
func (a *API) tellContact(tx *store.Tx, to, about string, reason push.Reason) (func(), error) {
	if a.remote(to) {
		return func() {}, nil
	}
	view, err := tx.ContactView(to, about)
	if err != nil {
		return nil, err
	}
	ev, err := tx.AppendEvent("", protocol.EventContactChanged,
		eventData(map[string]string{"user": about, "state": view}), store.AppendOptions{TargetUser: to})
	if err != nil {
		return nil, err
	}
	return func() {
		a.hub.Publish(ev, []string{to})
		if reason != 0 {
			a.push.Notify([]string{to}, "", reason)
		}
	}, nil
}

// tellContacts appends one such event per entry of tell: {to, about} pairs.
func (a *API) tellContacts(tx *store.Tx, tell ...[2]string) (func(), error) {
	var publish []func()
	for _, t := range tell {
		p, err := a.tellContact(tx, t[0], t[1], 0)
		if err != nil {
			return nil, err
		}
		publish = append(publish, p)
	}
	return func() {
		for _, p := range publish {
			p()
		}
	}, nil
}

// tellContactsAndServer tells both how they stand now: user, of this server,
// and other, or if other is of another server, their server what user did.
func (a *API) tellContactsAndServer(tx *store.Tx, typ, user, other string) (func(), error) {
	tell, err := a.tellContacts(tx, [2]string{user, other}, [2]string{other, user})
	if err != nil || !a.remote(other) {
		return tell, err
	}
	send, err := a.tellContactItem(tx, typ, user, other)
	return func() {
		tell()
		send()
	}, err
}

func (a *API) listContacts(w http.ResponseWriter, r *http.Request, c *Caller) error {
	contacts, err := a.store.ContactsOf(r.Context(), c.UserID)
	if err != nil {
		return err
	}
	type contactJSON struct {
		User  string `json:"user"`
		State string `json:"state"`
		Since int64  `json:"since"`
	}
	out := make([]contactJSON, 0, len(contacts))
	for _, contact := range contacts {
		out = append(out, contactJSON{contact.User, contact.View, contact.UpdatedAt})
	}
	slices.SortFunc(out, func(a, b contactJSON) int { return strings.Compare(a.User, b.User) })
	writeJSON(w, http.StatusOK, map[string]any{"contacts": out})
	return nil
}

// contactOf is the other user of a request naming them in its path, whom
// this server knows: one of its own, or of another server it has dealt with.
func (a *API) contactOf(r *http.Request, c *Caller) (string, error) {
	other := r.PathValue("user")
	return other, a.requireOtherUser(r, c, other, false)
}

// requireOtherUser checks that other is someone else, who exists. Asking a
// user of another server first asks their server whether they do. Anything
// else can be done with one known here, also once federation is off: what
// their server is to hear waits until it is on again.
func (a *API) requireOtherUser(r *http.Request, c *Caller, other string, asking bool) error {
	if other == c.UserID {
		return badRequest("That is you")
	}
	if asking && a.remote(other) {
		if !a.fed.Allowed(hostOf(other)) {
			return errOtherServer
		}
		return a.remoteUser(r.Context(), other)
	}
	if _, err := a.store.User(r.Context(), other); errors.Is(err, store.ErrNotFound) {
		if a.remote(other) && !a.fed.Allowed(hostOf(other)) {
			return errOtherServer
		}
		return &Error{http.StatusNotFound, "user_not_found", "No user " + other}
	} else if err != nil {
		return err
	}
	return nil
}

// requestContact asks someone to become a contact. It answers how the two
// stand now: "incoming" if they asked first, which the caller then accepts.
func (a *API) requestContact(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		User string `json:"user"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	if err := a.requireOtherUser(r, c, req.User, true); err != nil {
		return err
	}
	var view string
	err := a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		if err := requireVerified(tx, c); err != nil {
			return nil, err
		}
		mine, err := tx.ContactState(c.UserID, req.User)
		if err != nil {
			return nil, err
		}
		theirs, err := tx.ContactState(req.User, c.UserID)
		if err != nil {
			return nil, err
		}
		view = store.ContactView(mine, theirs)
		switch {
		case view == store.ViewBlocked:
			return nil, &Error{http.StatusConflict, "blocked", "You blocked them; unblock them first"}
		case view == store.ViewAccepted || view == store.ViewOutgoing || view == store.ViewIncoming:
			return nil, nil // Nothing changes.
		}
		view = store.ViewOutgoing
		// Asking again after having been told no reaches nobody, and neither
		// does asking someone who blocked the caller; to the caller, both look
		// like a request not answered yet.
		silent := mine == store.ContactWithdrawn || theirs == store.ContactBlocked
		state := store.ContactRequested
		if silent {
			state = store.ContactDeclined
		}
		outstanding, err := tx.OutstandingRequests(c.UserID)
		if err != nil {
			return nil, err
		}
		if outstanding >= maxOutstandingRequests {
			return nil, &Error{http.StatusTooManyRequests, "too_many_requests", "Too many requests are unanswered"}
		}
		if err := tx.SetContactState(c.UserID, req.User, state); err != nil {
			return nil, err
		}
		c.Log.Debug("contact requested", "user", req.User, "silent", silent)
		tellOwn, err := a.tellContact(tx, c.UserID, req.User, 0)
		if err != nil {
			return nil, err
		}
		if silent {
			return tellOwn, nil
		}
		tellThem, err := a.tellContact(tx, req.User, c.UserID, push.NewMessage)
		if a.remote(req.User) && err == nil {
			// Their server decides what comes of it.
			tellThem, err = a.tellContactItem(tx, itemContactRequest, c.UserID, req.User)
		}
		if err != nil {
			return nil, err
		}
		return func() {
			tellOwn()
			tellThem()
		}, nil
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"state": view})
	return nil
}

// acceptContact answers a request: the two become contacts. Their direct chat
// is a step of its own (createConversation, "direct"), which either of them
// takes once they are: being contacts and having a chat are not the same, and
// two servers could not do both at once.
func (a *API) acceptContact(w http.ResponseWriter, r *http.Request, c *Caller) error {
	other, err := a.contactOf(r, c)
	if err != nil {
		return err
	}
	err = a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		if err := requireVerified(tx, c); err != nil {
			return nil, err
		}
		mine, err := tx.ContactState(c.UserID, other)
		if err != nil {
			return nil, err
		}
		theirs, err := tx.ContactState(other, c.UserID)
		if err != nil {
			return nil, err
		}
		accepting := false
		switch {
		case mine == store.ContactAccepted && theirs == store.ContactAccepted:
			// Accepting again (the answer got lost) changes nothing.
			c.Log.Debug("contact accepted again", "user", other)
		case theirs != store.ContactRequested:
			return nil, &Error{http.StatusNotFound, "no_request", "They have not asked"}
		default:
			if err := tx.SetContactState(c.UserID, other, store.ContactAccepted); err != nil {
				return nil, err
			}
			if err := tx.SetContactState(other, c.UserID, store.ContactAccepted); err != nil {
				return nil, err
			}
			accepting = true
		}
		var publish []func()
		if accepting {
			tellOwn, err := a.tellContact(tx, c.UserID, other, 0)
			if err != nil {
				return nil, err
			}
			tellThem, err := a.tellContact(tx, other, c.UserID, push.NewMessage)
			if a.remote(other) && err == nil {
				tellThem, err = a.tellContactItem(tx, itemContactAccept, c.UserID, other)
			}
			if err != nil {
				return nil, err
			}
			publish = append(publish, tellOwn, tellThem)
			c.Log.Debug("contact accepted", "user", other)
		}
		return func() {
			for _, p := range publish {
				p()
			}
		}, nil
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"state": store.ViewAccepted})
	return nil
}

// directChat is the direct chat of the caller and other: the one the two have,
// made by either of them, or kept from when they were contacts before; or else
// a new one, from id and group. Given one it has, the client drops the group it
// made.
func (a *API) directChat(tx *store.Tx, c *Caller, other, id string, group *groupInput) (*protocol.ConversationInfo, func(), error) {
	pair := []string{c.UserID, other}
	slices.Sort(pair)
	key := strings.Join(pair, "|")
	if existing, err := tx.ConversationByDirectKey(key); err == nil {
		c.Log.Debug("direct chat exists", "conv", existing, "with", other)
		info, err := tx.Conversation(existing)
		return info, nil, err
	} else if !errors.Is(err, store.ErrNotFound) {
		return nil, nil, err
	}
	return a.insertConversation(tx, c, id, []string{c.UserID, other}, &key, group)
}

// declineContact says no; the one who asked is not told.
func (a *API) declineContact(w http.ResponseWriter, r *http.Request, c *Caller) error {
	other, err := a.contactOf(r, c)
	if err != nil {
		return err
	}
	err = a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		theirs, err := tx.ContactState(other, c.UserID)
		if err != nil || theirs != store.ContactRequested {
			return nil, err
		}
		if err := tx.SetContactState(other, c.UserID, store.ContactDeclined); err != nil {
			return nil, err
		}
		return a.tellContact(tx, c.UserID, other, 0)
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

// cancelContactRequest takes the caller's request back. One already declined
// stays on record, so that asking again does not reach them.
func (a *API) cancelContactRequest(w http.ResponseWriter, r *http.Request, c *Caller) error {
	other, err := a.contactOf(r, c)
	if err != nil {
		return err
	}
	err = a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		mine, err := tx.ContactState(c.UserID, other)
		if err != nil {
			return nil, err
		}
		switch mine {
		case store.ContactRequested:
			if err := tx.DeleteContactState(c.UserID, other); err != nil {
				return nil, err
			}
			return a.tellContactsAndServer(tx, itemContactCancel, c.UserID, other)
		case store.ContactDeclined:
			if err := tx.SetContactState(c.UserID, other, store.ContactWithdrawn); err != nil {
				return nil, err
			}
			return a.tellContact(tx, c.UserID, other, 0)
		}
		return nil, nil
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

// removeContact ends the relationship for both. Their direct chat stays, for
// what was said in it, but nothing more can be sent there.
func (a *API) removeContact(w http.ResponseWriter, r *http.Request, c *Caller) error {
	other, err := a.contactOf(r, c)
	if err != nil {
		return err
	}
	err = a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		if err := requireContact(tx, c.UserID, other); errors.Is(err, errNotAContact) {
			return nil, nil
		} else if err != nil {
			return nil, err
		}
		if err := tx.DeleteContactState(c.UserID, other); err != nil {
			return nil, err
		}
		if err := tx.DeleteContactState(other, c.UserID); err != nil {
			return nil, err
		}
		return a.tellContactsAndServer(tx, itemContactRemove, c.UserID, other)
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

// blockContact ends any relationship and keeps the other from asking. They see
// a contact end, or a request stay unanswered; never that they were blocked.
func (a *API) blockContact(w http.ResponseWriter, r *http.Request, c *Caller) error {
	other, err := a.contactOf(r, c)
	if err != nil {
		return err
	}
	err = a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		mine, err := tx.ContactState(c.UserID, other)
		if err != nil {
			return nil, err
		}
		theirs, err := tx.ContactState(other, c.UserID)
		if err != nil {
			return nil, err
		}
		if err := tx.SetContactState(c.UserID, other, store.ContactBlocked); err != nil {
			return nil, err
		}
		tell := [][2]string{{c.UserID, other}}
		// To their server, if they are of another, a contact ends or a
		// request is taken back.
		var item string
		switch {
		case mine == store.ContactAccepted:
			if err := tx.DeleteContactState(other, c.UserID); err != nil {
				return nil, err
			}
			tell = append(tell, [2]string{other, c.UserID})
			item = itemContactRemove
		case theirs == store.ContactRequested:
			// Unblocking them later does not bring it back.
			if err := tx.SetContactState(other, c.UserID, store.ContactDeclined); err != nil {
				return nil, err
			}
		case mine == store.ContactRequested:
			item = itemContactCancel
		}
		c.Log.Debug("contact blocked", "user", other)
		publish, err := a.tellContacts(tx, tell...)
		if err != nil || item == "" || !a.remote(other) {
			return publish, err
		}
		send, err := a.tellContactItem(tx, item, c.UserID, other)
		return func() {
			publish()
			send()
		}, err
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

func (a *API) unblockContact(w http.ResponseWriter, r *http.Request, c *Caller) error {
	other, err := a.contactOf(r, c)
	if err != nil {
		return err
	}
	err = a.store.AppendEvents(r.Context(), func(tx *store.Tx) (func(), error) {
		mine, err := tx.ContactState(c.UserID, other)
		if err != nil || mine != store.ContactBlocked {
			return nil, err
		}
		if err := tx.DeleteContactState(c.UserID, other); err != nil {
			return nil, err
		}
		return a.tellContact(tx, c.UserID, other, 0)
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}
