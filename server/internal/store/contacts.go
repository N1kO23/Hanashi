package store

import (
	"context"
	"database/sql"
	"errors"
)

// A row says how owner stands towards peer. Accepting writes both directions;
// the other states are one person's alone.
const (
	ContactRequested = "requested" // owner asked peer, who has not answered.
	ContactDeclined  = "declined"  // peer said no; owner still sees it as asked.
	ContactWithdrawn = "withdrawn" // owner gave up on a declined request.
	ContactAccepted  = "accepted"
	ContactBlocked   = "blocked" // owner blocked peer.
)

// How a relationship looks to one of the two, in GET /contacts. A request that
// was declined, or sent to someone who blocked the sender, looks to the sender
// just like one not answered yet.
const (
	ViewNone     = "none"
	ViewAccepted = "accepted"
	ViewOutgoing = "outgoing"
	ViewIncoming = "incoming"
	ViewBlocked  = "blocked"
)

// ContactView is how the relationship looks to the owner of mine, where theirs
// is the row of the other way around ("" if there is none).
func ContactView(mine, theirs string) string {
	switch mine {
	case ContactBlocked:
		return ViewBlocked
	case ContactAccepted:
		return ViewAccepted
	case ContactRequested, ContactDeclined:
		return ViewOutgoing
	}
	if theirs == ContactRequested {
		return ViewIncoming
	}
	return ViewNone
}

// Contact is one relationship of a user, with whom and since when.
type Contact struct {
	User, View string
	UpdatedAt  int64
}

// ContactsOf lists a user's relationships, except what looks like nothing.
func (s *Store) ContactsOf(ctx context.Context, userID string) ([]Contact, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT owner, peer, state, updated_at FROM contacts WHERE owner = ? OR peer = ?`, userID, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	type pair struct {
		mine, theirs string
		updatedAt    int64
	}
	pairs := map[string]*pair{}
	for rows.Next() {
		var owner, peer, state string
		var updatedAt int64
		if err := rows.Scan(&owner, &peer, &state, &updatedAt); err != nil {
			return nil, err
		}
		other := peer
		if peer == userID {
			other = owner
		}
		p := pairs[other]
		if p == nil {
			p = &pair{}
			pairs[other] = p
		}
		if owner == userID {
			p.mine = state
		} else {
			p.theirs = state
		}
		p.updatedAt = max(p.updatedAt, updatedAt)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := []Contact{}
	for other, p := range pairs {
		if view := ContactView(p.mine, p.theirs); view != ViewNone {
			out = append(out, Contact{other, view, p.updatedAt})
		}
	}
	return out, nil
}

func contactState(ctx context.Context, q querier, owner, peer string) (string, error) {
	var state string
	err := q.QueryRowContext(ctx, `SELECT state FROM contacts WHERE owner = ? AND peer = ?`, owner, peer).Scan(&state)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return state, err
}

// ContactState is owner's row about peer, "" if there is none.
func (tx *Tx) ContactState(owner, peer string) (string, error) {
	return contactState(tx.ctx, tx.q, owner, peer)
}

// ContactView is how the relationship looks to owner.
func (tx *Tx) ContactView(owner, peer string) (string, error) {
	mine, err := tx.ContactState(owner, peer)
	if err != nil {
		return "", err
	}
	theirs, err := tx.ContactState(peer, owner)
	if err != nil {
		return "", err
	}
	return ContactView(mine, theirs), nil
}

func (tx *Tx) SetContactState(owner, peer, state string) error {
	_, err := tx.q.ExecContext(tx.ctx, `
		INSERT INTO contacts (owner, peer, state, updated_at) VALUES (?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE state = VALUES(state), updated_at = VALUES(updated_at)`, owner, peer, state, now())
	return err
}

func (tx *Tx) DeleteContactState(owner, peer string) error {
	_, err := tx.q.ExecContext(tx.ctx, `DELETE FROM contacts WHERE owner = ? AND peer = ?`, owner, peer)
	return err
}

// OutstandingRequests counts the requests owner sees as unanswered.
func (tx *Tx) OutstandingRequests(owner string) (int, error) {
	var n int
	err := tx.q.QueryRowContext(tx.ctx, `
		SELECT COUNT(*) FROM contacts WHERE owner = ? AND state IN (?, ?)`, owner, ContactRequested, ContactDeclined).Scan(&n)
	return n, err
}

// MayClaimPackagesOf reports whether claimer is about to add owner to a group:
// they are contacts, or owner asked to be one and claimer is answering.
func (s *Store) MayClaimPackagesOf(ctx context.Context, claimer, owner string) (bool, error) {
	mine, err := contactState(ctx, s.db, claimer, owner)
	if err != nil {
		return false, err
	}
	if mine == ContactAccepted {
		return true, nil
	}
	theirs, err := contactState(ctx, s.db, owner, claimer)
	return mine != ContactBlocked && theirs == ContactRequested, err
}
