package api

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"time"

	"hanashi/server/internal/protocol"
)

// Typing and presence across servers (see "Federation" in docs/protocol.md):
// what matters only now goes at once to the servers of the people it is for,
// and is never stored or sent again (federation.Tell). A server repeats its
// users' statuses now and then; the others forget one it stops repeating.

const (
	// A user of another server's status lasts this many repeats.
	remoteStatusRepeats = 3
	maxStatusesTold     = 1000
)

func (a *API) presenceInterval() time.Duration {
	if a.cfg.PresenceInterval > 0 {
		return a.cfg.PresenceInterval
	}
	return 2 * time.Minute
}

// Run does what a server does by itself while it runs: look after its
// calls, repeat its users' statuses to other servers, and forget theirs that
// went stale.
func (a *API) Run(ctx context.Context) {
	go a.runCalls(ctx)
	if !a.fed.Enabled() {
		return
	}
	go a.runHandOvers(ctx)
	interval := a.presenceInterval()
	repeat := time.NewTicker(interval)
	defer repeat.Stop()
	sweep := time.NewTicker(interval / 4)
	defer sweep.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-repeat.C:
			a.repeatPresence(ctx)
		case now := <-sweep.C:
			a.expirePresence(ctx, now)
		}
	}
}

// remoteHosts lists the other servers of users.
func (a *API) remoteHosts(users []string) []string {
	var hosts []string
	for _, u := range users {
		if a.remote(u) && !slices.Contains(hosts, hostOf(u)) {
			hosts = append(hosts, hostOf(u))
		}
	}
	return hosts
}

// localPeersOf lists the users of this server who share a conversation with
// user.
func (a *API) localPeersOf(ctx context.Context, user string) ([]string, error) {
	peers, err := a.store.ConversationPeersOf(ctx, user)
	return slices.DeleteFunc(peers, func(p string) bool { return p == user || a.remote(p) }), err
}

// tellPresence tells the servers of user's peers of other servers user's
// status.
func (a *API) tellPresence(user, status string, peers []string) {
	for _, host := range a.remoteHosts(peers) {
		a.fed.Tell(host, map[string]any{"presence": map[string]string{user: status}})
	}
}

// tellTyping tells the servers of a conversation's members of other servers
// that user is typing.
func (a *API) tellTyping(conv, user string, members []string) {
	for _, host := range a.remoteHosts(members) {
		a.fed.Tell(host, map[string]any{"typing": map[string]string{"conv": conv, "user": user}})
	}
}

// repeatPresence says again the status of each user of this server who is
// not offline, to the servers of their peers.
func (a *API) repeatPresence(ctx context.Context) {
	byHost := map[string]map[string]string{}
	for user, status := range a.hub.Present() {
		peers, err := a.store.ConversationPeersOf(ctx, user)
		if err != nil {
			a.log.Debug("presence not repeated", "user", user, "err", err)
			continue
		}
		for _, host := range a.remoteHosts(peers) {
			if byHost[host] == nil {
				byHost[host] = map[string]string{}
			}
			if len(byHost[host]) < maxStatusesTold {
				byHost[host][user] = status
			}
		}
	}
	for host, statuses := range byHost {
		a.fed.Tell(host, map[string]any{"presence": statuses})
	}
}

// expirePresence turns offline the users of other servers whose status went
// stale, for their peers here.
func (a *API) expirePresence(ctx context.Context, now time.Time) {
	for _, user := range a.hub.ExpireRemote(now) {
		peers, err := a.localPeersOf(ctx, user)
		if err != nil {
			a.log.Debug("presence not told", "user", user, "err", err)
			continue
		}
		a.hub.PublishPresence(user, peers)
	}
}

func (a *API) federationEphemeral(w http.ResponseWriter, r *http.Request) {
	if err := a.takeEphemeral(w, r); err != nil {
		a.fail(w, r, err)
	}
}

// takeEphemeral passes on to this server's users what another server tells
// of its users now: who is typing in a conversation they share, and statuses.
func (a *API) takeEphemeral(w http.ResponseWriter, r *http.Request) error {
	origin, body, err := a.fed.Verify(r)
	if err != nil {
		return err
	}
	var req struct {
		Typing *struct {
			Conv string `json:"conv"`
			User string `json:"user"`
		} `json:"typing"`
		Presence map[string]string `json:"presence"`
	}
	if json.Unmarshal(body, &req) != nil || len(req.Presence) > maxStatusesTold {
		return badRequest("Not something to tell")
	}
	ctx := r.Context()
	of := func(user string) bool { return protocol.ValidUserID(user) && hostOf(user) == origin }
	if t := req.Typing; t != nil && of(t.User) {
		if members, err := a.store.MemberIDs(ctx, t.Conv); err == nil && slices.Contains(members, t.User) {
			a.hub.Typing(t.Conv, t.User, members)
		}
	}
	until := time.Now().Add(remoteStatusRepeats * a.presenceInterval())
	for user, status := range req.Presence {
		switch status {
		case protocol.StatusOnline, protocol.StatusIdle, protocol.StatusFocus, protocol.StatusOffline:
		default:
			continue
		}
		if !of(user) {
			continue
		}
		peers, err := a.localPeersOf(ctx, user)
		if err != nil {
			return err
		}
		if len(peers) == 0 {
			continue // Nobody here for whom it matters.
		}
		a.hub.SetRemoteStatus(user, status, until)
		a.hub.PublishPresence(user, peers)
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}
