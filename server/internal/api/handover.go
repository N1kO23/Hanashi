package api

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	"hanashi/server/internal/config"
	"hanashi/server/internal/federation"
	"hanashi/server/internal/protocol"
	"hanashi/server/internal/store"
)

// Handing a conversation over (see "Handing a conversation over" in
// docs/protocol.md). Its hub moves it to the server of some of its other
// members, which orders it from the next term on: by itself, once none of its
// own users are in a group, and everything it orders when its operator asks
// (HANASHI_HAND_OVER=all), before shutting it down. Only the hub decides, in
// its order of events, so two servers never both order a conversation.

const (
	// featureHubMove: the server follows a conversation to its next hub, and
	// can be one.
	featureHubMove = "hub-move"
	// eventHubMoved is the last event of a hub's term, which only servers
	// see: the conversation is ordered by the server it names from then on.
	eventHubMoved = "hub_moved"
	// How long a hub waits for the server it chose to be ready to order a
	// conversation, asking again and again.
	handOverWait = time.Minute
	// How long a conversation that could not be handed over waits for the
	// next try, at most.
	lastHandOverRetry = 6 * time.Hour
)

// hubMove is what a hub_moved event says: which server orders the
// conversation from which term on, and what it needs to that its copy does
// not have.
type hubMove struct {
	Hub       string `json:"hub"`
	Term      int64  `json:"term"`
	Epoch     int64  `json:"epoch"`
	GroupInfo string `json:"groupInfo"`
	State     string `json:"state,omitempty"`
}

// errNothingToHandOver: the conversation is not this server's to hand over,
// or not any more.
var errNothingToHandOver = errors.New("nothing to hand over")

// requireHubTx refuses, in a transaction, what only conv's hub does, once
// this server handed it over.
func requireHubTx(tx *store.Tx, conv string) error {
	hub, err := tx.ConversationHub(conv)
	if err == nil && hub.Host != "" {
		return errConvMoved
	}
	return err
}

// What servers say of themselves

// aboutServer is what a server answers to query/server.
type aboutServer struct {
	Version  string   `json:"version"`
	Features []string `json:"features"`
	// It hands over all it orders, being about to shut down: no place to
	// hand anything to.
	HandingOver bool `json:"handingOver,omitempty"`
}

func (a *API) aboutThisServer() (aboutServer, error) {
	if a.cfg.NoHubMove {
		return aboutServer{}, &Error{http.StatusNotFound, "user_not_found", ""} // As servers before 1.1.0.
	}
	return aboutServer{Version: Version, Features: []string{featureHubMove}, HandingOver: a.cfg.HandOver == config.HandOverAll}, nil
}

// askServer asks host's server what it is.
func (a *API) askServer(ctx context.Context, host string) (aboutServer, error) {
	var out aboutServer
	err := a.fed.Query(ctx, host, "server", map[string]any{}, &out)
	return out, err
}

// The hub's side

// handOver hands conv, which this server orders, to the server of its other
// members that has the most of them and is ready to order it, if every one
// of their servers can follow it there. Otherwise it says why not.
func (a *API) handOver(ctx context.Context, conv string) error {
	hub, err := a.store.ConversationHub(ctx, conv)
	if errors.Is(err, store.ErrNotFound) || err == nil && hub.Host != "" {
		return errNothingToHandOver
	} else if err != nil {
		return err
	}
	members, err := a.store.MemberIDs(ctx, conv)
	if err != nil {
		return err
	}
	theirs := map[string]int{}
	ours := 0
	for _, m := range members {
		if a.remote(m) {
			theirs[hostOf(m)]++
		} else {
			ours++
		}
	}
	if len(theirs) == 0 || ours > 0 && a.cfg.HandOver != config.HandOverAll {
		return errNothingToHandOver
	}
	var candidates []string
	for host := range theirs {
		about, err := a.askServer(ctx, host)
		var fedErr *federation.Error
		switch {
		case errors.As(err, &fedErr) && fedErr.Status < http.StatusInternalServerError &&
			fedErr.Status != http.StatusTooManyRequests,
			err == nil && !slices.Contains(about.Features, featureHubMove):
			return fmt.Errorf("%s cannot follow it to another server", host)
		case err != nil:
			return fmt.Errorf("%s cannot be reached: %w", host, err)
		case !about.HandingOver:
			candidates = append(candidates, host)
		}
	}
	if len(candidates) == 0 {
		return errors.New("the other servers hand over all they order")
	}
	slices.SortFunc(candidates, func(x, y string) int { return cmp.Or(cmp.Compare(theirs[y], theirs[x]), strings.Compare(x, y)) })
	var why []string
	for _, next := range candidates {
		if err := a.prepareHub(ctx, next, conv, hub.Term); err != nil {
			why = append(why, next+": "+err.Error())
			continue
		}
		return a.moveHub(ctx, conv, hub.Term, next)
	}
	return errors.New(strings.Join(why, "; "))
}

// prepareHub asks next whether it is ready to order conv from the term after
// term on, until it is.
func (a *API) prepareHub(ctx context.Context, next, conv string, term int64) error {
	ctx, cancel := context.WithTimeout(ctx, handOverWait)
	defer cancel()
	pause := 50 * time.Millisecond
	for {
		var out struct {
			Ready bool `json:"ready"`
		}
		if err := a.fed.Query(ctx, next, "conv.handover", map[string]any{"conv": conv, "term": term}, &out); err != nil {
			return err
		}
		if out.Ready {
			return nil
		}
		select {
		case <-ctx.Done():
			return errors.New("not ready yet")
		case <-time.After(pause):
		}
		pause = min(2*pause, 2*time.Second)
	}
}

// moveHub hands conv over to next, from the term after term on: its last
// event of the term says so, to every member's server, with what next needs
// to order it. This server keeps its copy, ordered there from then on.
func (a *API) moveHub(ctx context.Context, conv string, term int64, next string) error {
	return a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		hub, err := tx.ConversationHub(conv)
		if err != nil {
			return nil, err
		}
		if hub.Host != "" || hub.Term != term {
			return nil, errNothingToHandOver
		}
		members, err := tx.MemberIDs(conv)
		if err != nil {
			return nil, err
		}
		if a.cfg.HandOver != config.HandOverAll && slices.ContainsFunc(members, func(m string) bool { return !a.remote(m) }) {
			return nil, errNothingToHandOver // One of this server's users is back.
		}
		hosts, err := tx.RemoteMemberHosts(conv, a.cfg.Host)
		if err != nil {
			return nil, err
		}
		if !slices.Contains(hosts, next) {
			return nil, fmt.Errorf("none of the users of %s are in it any more", next)
		}
		epoch, err := tx.ConversationEpoch(conv)
		if err != nil {
			return nil, err
		}
		group, err := tx.GroupInfo(conv)
		if err != nil {
			return nil, err
		}
		data := eventData(hubMove{Hub: next, Term: term + 1, Epoch: epoch, GroupInfo: group.Data, State: group.State})
		ev, err := tx.AppendEvent(conv, eventHubMoved, data, store.AppendOptions{TargetUser: store.HubOnly, HubTerm: term})
		if err != nil {
			return nil, err
		}
		send, err := a.passOn(tx, conv, term, ev.Seq, convEventJSON{Type: eventHubMoved, TS: ev.TS, Data: data}, hosts)
		if err != nil {
			return nil, err
		}
		if err := tx.SetHub(conv, next, term+1); err != nil {
			return nil, err
		}
		if err := tx.DeleteLease(conv); err != nil {
			return nil, err
		}
		return func() {
			send()
			a.log.Info("federation: conversation handed over", "conv", conv, "hub", next, "term", term+1)
		}, nil
	})
}

// The next hub's side

// backfill is how far this server is with taking, from a conversation's hub,
// what its copy lacks to order it next.
type backfill struct {
	term           int64
	running, ready bool
}

// answerHandOver answers origin, which orders conv in term, whether this
// server is ready to order it from the next term on: it is, once its copy
// holds the conversation's whole order. Until then it takes what it lacks
// from origin, and answers no.
func (a *API) answerHandOver(ctx context.Context, origin, conv string, term int64) (any, error) {
	if a.cfg.NoHubMove {
		return nil, errNotFound
	}
	hub, err := a.store.ConversationHub(ctx, conv)
	if errors.Is(err, store.ErrNotFound) {
		return nil, errNotFound
	} else if err != nil {
		return nil, err
	}
	if hub.Host != origin || hub.Term != term {
		if hub.Term < term {
			go a.catchUp(conv, origin) // It missed a move.
		}
		return nil, &Error{http.StatusConflict, "not_ready", "This server's copy is not of that hub's term"}
	}
	members, err := a.store.MemberIDs(ctx, conv)
	if err != nil {
		return nil, err
	}
	if !slices.ContainsFunc(members, func(m string) bool { return !a.remote(m) }) {
		return nil, &Error{http.StatusConflict, "no_members", "None of this server's users are in it"}
	}
	a.backfillMu.Lock()
	defer a.backfillMu.Unlock()
	b := a.backfills[conv]
	if b == nil || b.term != term {
		b = &backfill{term: term}
		a.backfills[conv] = b
	}
	if !b.ready && !b.running {
		b.running = true
		go a.backfill(origin, conv, b)
	}
	return map[string]bool{"ready": b.ready}, nil
}

// forgetBackfill: this server's copy of conv went without one of its events.
func (a *API) forgetBackfill(conv string) {
	a.backfillMu.Lock()
	delete(a.backfills, conv)
	a.backfillMu.Unlock()
}

// backfill takes from hub what this server's copy of conv lacks, then notes
// it is ready, unless the copy went without something again meanwhile.
func (a *API) backfill(hub, conv string, b *backfill) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	err := a.takeMissing(ctx, hub, conv, b.term)
	if err != nil {
		a.log.Info("federation: could not take what the copy lacks", "conv", conv, "hub", hub, "err", err)
	}
	a.backfillMu.Lock()
	defer a.backfillMu.Unlock()
	b.running = false
	b.ready = err == nil && a.backfills[conv] == b
}

// takeMissing takes from hub, which orders conv in term, the events this
// server's copy lacks, from its start up to where the copy is: what came
// before its users were in it, but for messages, which a copy always keeps.
// What comes after, the copy takes as it comes. A server that orders a
// conversation has all of its order, so that it can give it to a server
// joining later.
func (a *API) takeMissing(ctx context.Context, hub, conv string, term int64) error {
	from := position{}
	added := 0
	for {
		var page caughtUp
		req := map[string]any{"conv": conv, "term": from.Term, "since": from.Seq, "except": []string{protocol.EventMessage}}
		if err := a.fed.Query(ctx, hub, "conv.events", req, &page); err != nil {
			return err
		}
		done := !page.More
		err := a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
			at, err := tx.ConversationHub(conv)
			if err != nil {
				return nil, err
			}
			if at.Host != hub || at.Term != term {
				return nil, errors.New("the copy moved on meanwhile")
			}
			for _, e := range page.Events {
				if e.Term > at.Term || e.Term == at.Term && e.Seq > at.Seq {
					done = true
					break
				}
				from = position{e.Term, e.Seq}
				if has, err := tx.HasConvEvent(conv, e.Term, e.Seq); err != nil {
					return nil, err
				} else if has {
					continue
				}
				opts := store.AppendOptions{TargetUser: store.HistoryOnly, Sender: e.Sender, HubSeq: e.Seq, HubTerm: e.Term,
					TS: e.TS}
				if e.Type == eventHubMoved {
					opts.TargetUser = store.HubOnly
				}
				if e.MsgID != "" {
					if _, err := tx.MessageByID(e.MsgID); err == nil {
						continue // Its ID is taken here, as when the copy took it.
					} else if !errors.Is(err, store.ErrNotFound) {
						return nil, err
					}
					opts.MsgID = e.MsgID
				}
				if _, err := tx.AppendEvent(conv, e.Type, e.Data, opts); err != nil {
					return nil, err
				}
				added++
			}
			return nil, nil
		})
		if err != nil {
			return err
		}
		if done {
			a.log.Info("federation: ready to order the conversation", "conv", conv, "hub", hub, "taken", added)
			return nil
		}
	}
}

// When conversations are handed over

// handOvers are the conversations this server is to hand over, each with
// when it tries next.
type handOvers struct {
	mu   sync.Mutex
	due  map[string]*handOverTry
	wake chan struct{}
}

type handOverTry struct {
	at    time.Time
	delay time.Duration
}

// add has conv handed over as soon as can be, unless it waits already.
func (h *handOvers) add(conv string) {
	h.mu.Lock()
	if _, ok := h.due[conv]; !ok {
		h.due[conv] = &handOverTry{at: time.Now()}
	}
	h.mu.Unlock()
	select {
	case h.wake <- struct{}{}:
	default:
	}
}

// next is a conversation due now; or else how long until one is.
func (h *handOvers) next() (string, time.Duration) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := time.Now()
	wait := time.Hour
	first := ""
	for conv, try := range h.due {
		if until := try.at.Sub(now); until <= 0 && (first == "" || conv < first) {
			first = conv
		} else if until > 0 {
			wait = min(wait, until)
		}
	}
	return first, wait
}

// done: conv is handed over, or not to be.
func (h *handOvers) done(conv string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.due, conv)
	return len(h.due)
}

// later has conv tried again after a while, longer each time; how long.
func (h *handOvers) later(conv string, first time.Duration) time.Duration {
	h.mu.Lock()
	defer h.mu.Unlock()
	try := h.due[conv]
	if try == nil {
		try = &handOverTry{}
		h.due[conv] = try
	}
	try.delay = min(max(2*try.delay, first), lastHandOverRetry)
	try.at = time.Now().Add(try.delay)
	return try.delay
}

// leftByOurs has conv, a group this server orders, handed over if none of
// its users are left in it but others are.
func (a *API) leftByOurs(conv string, members []string) {
	if a.fed.Enabled() && slices.ContainsFunc(members, a.remote) &&
		!slices.ContainsFunc(members, func(m string) bool { return !a.remote(m) }) {
		a.handOvers.add(conv)
	}
}

// runHandOvers hands over what this server is to, one conversation at a
// time: what it finds when it starts, and what comes up. With
// HANASHI_HAND_OVER=all, it looks again from time to time.
func (a *API) runHandOvers(ctx context.Context) {
	retry := a.cfg.HandOverRetry
	if retry <= 0 {
		retry = 10 * time.Minute
	}
	var look <-chan time.Time
	if a.cfg.HandOver == config.HandOverAll {
		ticker := time.NewTicker(retry)
		defer ticker.Stop()
		look = ticker.C
	}
	a.findHandOvers(ctx)
	for {
		if conv, wait := a.handOvers.next(); conv != "" {
			a.tryHandOver(ctx, conv, retry)
		} else {
			timer := time.NewTimer(wait)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-a.handOvers.wake:
			case <-look:
				a.findHandOvers(ctx)
			case <-timer.C:
			}
			timer.Stop()
		}
		if ctx.Err() != nil {
			return
		}
	}
}

// findHandOvers has what this server is to hand over handed over.
func (a *API) findHandOvers(ctx context.Context) {
	all := a.cfg.HandOver == config.HandOverAll
	convs, stay, err := a.store.ConversationsToHandOver(ctx, a.cfg.Host, all)
	if err != nil {
		a.log.Warn("federation: finding conversations to hand over", "err", err)
		return
	}
	for _, conv := range convs {
		a.handOvers.add(conv)
	}
	if all {
		a.log.Info("federation: handing over all conversations with members on other servers", "conversations",
			len(convs), "staying", stay)
	}
}

// tryHandOver tries to hand conv over once, or has it tried again later.
func (a *API) tryHandOver(ctx context.Context, conv string, retry time.Duration) {
	err := a.handOver(ctx, conv)
	switch {
	case ctx.Err() != nil:
		return
	case err == nil, errors.Is(err, errNothingToHandOver):
		left := a.handOvers.done(conv)
		if err == nil && left == 0 && a.cfg.HandOver == config.HandOverAll {
			waiting, _ := a.store.FederationDestinations(ctx)
			a.log.Info("federation: every conversation with members on other servers is handed over",
				"servers_still_to_tell", len(waiting))
		}
	default:
		delay := a.handOvers.later(conv, retry)
		a.log.Info("federation: conversation not handed over yet", "conv", conv, "why", err, "again_in", delay)
	}
}
