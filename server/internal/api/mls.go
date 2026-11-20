package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/oklog/ulid/v2"

	"hanashi/server/internal/protocol"
	"hanashi/server/internal/push"
	"hanashi/server/internal/store"
)

// MLS delivery service: the server orders commits (one per epoch, under a
// lease), keeps the latest GroupInfo for external joins, hands out key
// packages and delivers Welcomes to device inboxes. It never sees keys.

const (
	maxMLSBytes    = 1 << 20
	maxWelcomes    = 1000
	maxKeyPackages = 100
	inboxPageLimit = 500
	// maxStateBytes bounds a group's sealed state (opaque; see docs/protocol.md).
	maxStateBytes = 128 * 1024
)

func decodeBase64(s string, max int, field string) error {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(b) == 0 || len(b) > max {
		return badRequest(field + " must be non-empty base64")
	}
	return nil
}

// requireVerified refuses a device that is not verified with its user's
// current identity key, e.g. one left over from before a reset: it would
// rejoin every group, the other devices would remove it again, and so on
// for as long as it runs. Users who never set up encryption (tests and
// scripts; the app always does) are not checked.
func requireVerified(tx *store.Tx, c *Caller) error {
	if _, err := tx.UserKeys(c.UserID); errors.Is(err, store.ErrNotFound) {
		return nil
	} else if err != nil {
		return err
	}
	device, err := tx.DeviceKey(c.SessionID)
	if errors.Is(err, store.ErrNotFound) || (err == nil && device.Signature == nil) {
		c.Log.Debug("refused: device not verified")
		return errNotVerified
	}
	return err
}

var errNotVerified = &Error{http.StatusForbidden, "not_verified",
	"This device is not verified with the account's current key; verify it again"}

// Leases

func (a *API) acquireLease(w http.ResponseWriter, r *http.Request, c *Caller) error {
	// The epoch the device's group is at, if it has one: a device that is
	// behind gets no lease, so it never keeps others waiting while it catches up.
	var req struct {
		Epoch *int64 `json:"epoch"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	out, err := a.lease(r.Context(), c, r.PathValue("id"), req.Epoch)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, out)
	return nil
}

// lease gives c the commit lease of convID, from its hub if another server
// orders it.
func (a *API) lease(ctx context.Context, c *Caller, convID string, deviceEpoch *int64) (map[string]any, error) {
	if err := a.requireMember(ctx, convID, c); err != nil {
		return nil, err
	}
	if hub, err := a.mirrorHub(ctx, convID); err != nil || hub != "" {
		var out map[string]any
		if err == nil {
			err = a.relay(ctx, c, hub, "conv.lease", map[string]any{"conv": convID, "epoch": deviceEpoch}, &out)
		}
		return out, err
	}
	var out map[string]any
	err := a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		if err := requireVerified(tx, c); err != nil {
			return nil, err
		}
		epoch, err := tx.ConversationEpoch(convID)
		if err != nil {
			return nil, err
		}
		if deviceEpoch != nil && *deviceEpoch != epoch {
			c.Log.Debug("lease refused: other epoch", "conv", convID, "device_epoch", *deviceEpoch, "epoch", epoch)
			return nil, &Error{http.StatusConflict, "epoch_mismatch", "The conversation moved on; catch up and retry"}
		}
		nowMs := time.Now().UnixMilli()
		if current, err := tx.Lease(convID); err == nil && current.ExpiresAt > nowMs && current.DeviceID != c.SessionID {
			c.Log.Debug("lease refused: held", "conv", convID, "epoch", epoch, "holder", current.DeviceID,
				"expires_in", time.Duration(current.ExpiresAt-nowMs)*time.Millisecond)
			return nil, &Error{http.StatusConflict, "lease_held", "Another device is changing this conversation; try again shortly"}
		} else if err != nil && !errors.Is(err, store.ErrNotFound) {
			return nil, err
		}
		duration := a.cfg.LeaseDuration
		if duration <= 0 {
			duration = 30 * time.Second
		}
		lease := store.Lease{ID: ulid.Make().String(), DeviceID: c.SessionID, ExpiresAt: nowMs + duration.Milliseconds()}
		out = map[string]any{"leaseId": lease.ID, "epoch": epoch, "expiresAt": lease.ExpiresAt}
		c.Log.Debug("lease granted", "conv", convID, "epoch", epoch, "lease", lease.ID)
		return nil, tx.PutLease(convID, lease)
	})
	return out, err
}

// releaseLease gives up the caller's lease before it expires, e.g. when its
// commit could not be made, so other devices need not wait for it.
func (a *API) releaseLease(w http.ResponseWriter, r *http.Request, c *Caller) error {
	if err := a.release(r.Context(), c, r.PathValue("id"), r.PathValue("lease")); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

func (a *API) release(ctx context.Context, c *Caller, convID, leaseID string) error {
	if hub, err := a.mirrorHub(ctx, convID); err != nil {
		return err
	} else if hub != "" {
		if err := a.requireMember(ctx, convID, c); err != nil {
			return err
		}
		return a.relay(ctx, c, hub, "conv.release", map[string]any{"conv": convID, "lease": leaseID}, nil)
	}
	released, err := a.store.ReleaseLease(ctx, convID, leaseID, c.SessionID)
	if err != nil {
		return err
	}
	c.Log.Debug("lease given back", "conv", convID, "lease", leaseID, "released", released)
	return nil
}

// Commits

type welcomeInput struct {
	Device string `json:"device"`
	Data   string `json:"data"`
	// Whose the device is, as a member's server relaying a commit says for
	// its own users' devices, which this one may not know.
	User string `json:"user,omitempty"`
}

type commitInput struct {
	LeaseID   string `json:"leaseId"`
	Epoch     int64  `json:"epoch"`
	MLS       string `json:"mls"`
	GroupInfo string `json:"groupInfo"`
	// State is the group's state sealed for the epoch this commit starts. A
	// device that does not hold it yet (one joining by itself) leaves it out,
	// and another member seals it afterwards.
	State    string         `json:"state"`
	Welcomes []welcomeInput `json:"welcomes"`
}

func validateState(state string) error {
	if state == "" {
		return nil
	}
	return decodeBase64(state, maxStateBytes, "state")
}

// queueWelcomes puts Welcome messages into the inboxes of devices that
// belong to members of the conversation.
func (a *API) queueWelcomes(tx *store.Tx, c *Caller, convID string, epoch int64, state string, welcomes []welcomeInput) (func(), error) {
	if len(welcomes) > maxWelcomes {
		return nil, badRequest("too many welcomes")
	}
	members, err := tx.MemberIDs(convID)
	if err != nil {
		return nil, err
	}
	type delivery struct {
		user, device string
		item         store.InboxItem
	}
	var deliveries []delivery
	var wakes []func()
	for _, wlc := range welcomes {
		if err := decodeBase64(wlc.Data, maxMLSBytes, "welcome"); err != nil {
			return nil, err
		}
		owner, err := a.deviceOwner(tx, c, wlc)
		if errors.Is(err, store.ErrNotFound) || (err == nil && !contains(members, owner)) {
			return nil, badRequest("welcomes can only go to devices of members")
		} else if err != nil {
			return nil, err
		}
		c.Log.Debug("welcome queued", "conv", convID, "epoch", epoch, "to_user", owner, "to_device", wlc.Device)
		if a.remote(owner) {
			// Its server puts it in the device's inbox, before the event that
			// follows: items go in order.
			send, err := a.tellServer(tx, owner, map[string]any{"type": itemWelcome, "user": owner, "device": wlc.Device,
				"conv": convID, "epoch": epoch, "data": wlc.Data, "state": state,
				"senderUser": c.UserID, "senderDevice": c.SessionID})
			if err != nil {
				return nil, err
			}
			wakes = append(wakes, send)
			continue
		}
		fields := map[string]any{"conv": convID, "epoch": epoch, "data": wlc.Data}
		if state != "" {
			fields["state"] = state
		}
		payload, _ := json.Marshal(fields)
		item, err := tx.AddInboxItem(wlc.Device, store.InboxItem{
			Type: protocol.InboxWelcome, SenderUser: c.UserID, SenderDevice: c.SessionID, Payload: string(payload),
		})
		if err != nil {
			return nil, err
		}
		deliveries = append(deliveries, delivery{owner, wlc.Device, item})
	}
	return func() {
		for _, d := range deliveries {
			a.pushInbox(d.user, d.device, d.item)
		}
		for _, wake := range wakes {
			wake()
		}
	}, nil
}

// deviceOwner is whose a device is: a user of this server's, or of another
// whose devices this server has looked up; or as the server relaying the
// request says, for a device of a user of another server.
func (a *API) deviceOwner(tx *store.Tx, c *Caller, wlc welcomeInput) (string, error) {
	owner, err := tx.SessionOwner(wlc.Device)
	if !errors.Is(err, store.ErrNotFound) {
		return owner, err
	}
	if owner, err := tx.RemoteDeviceOwner(wlc.Device); !errors.Is(err, store.ErrNotFound) {
		return owner, err
	}
	// Said for a user of another server, who must be a member (checked by
	// the caller): their own server checks the device is theirs.
	if a.remote(wlc.User) {
		return wlc.User, nil
	}
	return "", store.ErrNotFound
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// acceptedCommit is what is left to do once a commit's transaction is
// committed. Welcomes go out before any event, so a device never sees a
// conversation it was added to before it can join the group.
type acceptedCommit struct {
	seq      int64
	welcomes func()
	event    func()
}

// applyCommit accepts one commit for convID inside the append section: the
// caller must hold the lease and the commit must be for the current epoch.
func (a *API) applyCommit(tx *store.Tx, c *Caller, convID string, in commitInput) (acceptedCommit, error) {
	if err := decodeBase64(in.MLS, maxMLSBytes, "mls"); err != nil {
		return acceptedCommit{}, err
	}
	if err := decodeBase64(in.GroupInfo, maxMLSBytes, "groupInfo"); err != nil {
		return acceptedCommit{}, err
	}
	if err := validateState(in.State); err != nil {
		return acceptedCommit{}, err
	}
	members, err := tx.MemberIDs(convID)
	if err != nil {
		return acceptedCommit{}, err
	}
	if !contains(members, c.UserID) {
		return acceptedCommit{}, errNotFound
	}
	if err := requireVerified(tx, c); err != nil {
		return acceptedCommit{}, err
	}
	lease, err := tx.Lease(convID)
	if errors.Is(err, store.ErrNotFound) || (err == nil && (lease.ID != in.LeaseID || lease.DeviceID != c.SessionID ||
		lease.ExpiresAt <= time.Now().UnixMilli())) {
		reason := "none"
		switch {
		case err != nil:
		case lease.DeviceID != c.SessionID:
			reason = "held by " + lease.DeviceID
		case lease.ID != in.LeaseID:
			reason = "replaced"
		default:
			reason = "expired"
		}
		c.Log.Debug("commit refused: lease", "conv", convID, "epoch", in.Epoch, "lease", reason)
		return acceptedCommit{}, &Error{http.StatusConflict, "lease_invalid", "The commit lease is missing or expired"}
	} else if err != nil {
		return acceptedCommit{}, err
	}
	epoch, err := tx.ConversationEpoch(convID)
	if err != nil {
		return acceptedCommit{}, err
	}
	if in.Epoch != epoch {
		c.Log.Debug("commit refused: other epoch", "conv", convID, "device_epoch", in.Epoch, "epoch", epoch)
		return acceptedCommit{}, &Error{http.StatusConflict, "epoch_mismatch", "The conversation moved on; catch up and retry"}
	}
	fields := map[string]any{"epoch": epoch, "mls": in.MLS, "from": c.UserID, "device": c.SessionID}
	if in.State != "" {
		fields["state"] = in.State
	}
	ev, send, err := a.appendConvEvent(tx, convID, protocol.EventMLSCommit, eventData(fields), store.AppendOptions{})
	if err != nil {
		return acceptedCommit{}, err
	}
	if err := tx.SetConversationEpoch(convID, epoch+1); err != nil {
		return acceptedCommit{}, err
	}
	if err := tx.PutGroupInfo(convID, epoch+1, in.GroupInfo, in.State); err != nil {
		return acceptedCommit{}, err
	}
	if err := tx.DeleteLease(convID); err != nil {
		return acceptedCommit{}, err
	}
	sendWelcomes, err := a.queueWelcomes(tx, c, convID, epoch+1, in.State, in.Welcomes)
	if err != nil {
		return acceptedCommit{}, err
	}
	c.Log.Debug("commit accepted", "conv", convID, "epoch", epoch, "seq", ev.Seq, "welcomes", len(in.Welcomes))
	return acceptedCommit{ev.Seq, sendWelcomes, func() {
		send()
		a.hub.Publish(ev, members)
		if in.State == "" {
			// Someone has to seal the state for this epoch: wake them.
			a.push.Notify(members, c.SessionID, push.StateNeeded)
		}
	}}, nil
}

// commit accepts a stand-alone commit (adding devices, removing leaves,
// self-updates, external joins).
func (a *API) commit(ctx context.Context, c *Caller, convID string, in commitInput) (int64, error) {
	if hub, err := a.mirrorHub(ctx, convID); err != nil {
		return 0, err
	} else if hub != "" {
		return a.relayCommit(ctx, c, hub, convID, in)
	}
	var seq int64
	err := a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		accepted, err := a.applyCommit(tx, c, convID, in)
		if err != nil {
			return nil, err
		}
		seq = accepted.seq
		return func() {
			accepted.welcomes()
			accepted.event()
		}, nil
	})
	return seq, err
}

func (a *API) commitHTTP(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var in commitInput
	if err := readJSONLimit(w, r, &in, 4*maxMLSBytes); err != nil {
		return err
	}
	seq, err := a.commit(r.Context(), c, r.PathValue("id"), in)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]int64{"seq": seq})
	return nil
}

func (a *API) groupInfo(w http.ResponseWriter, r *http.Request, c *Caller) error {
	out, err := a.groupInfoOf(r.Context(), c, r.PathValue("id"))
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, out)
	return nil
}

// groupInfoOf is convID's latest GroupInfo, from its hub if another server
// orders it.
func (a *API) groupInfoOf(ctx context.Context, c *Caller, convID string) (map[string]any, error) {
	if err := a.requireMember(ctx, convID, c); err != nil {
		return nil, err
	}
	if hub, err := a.mirrorHub(ctx, convID); err != nil || hub != "" {
		var out map[string]any
		if err == nil {
			err = a.relay(ctx, c, hub, "conv.group_info", map[string]any{"conv": convID}, &out)
		}
		return out, err
	}
	g, err := a.store.GroupInfo(ctx, convID)
	if err != nil {
		return nil, err
	}
	c.Log.Debug("group info", "conv", convID, "epoch", g.Epoch, "state", g.State != "")
	out := map[string]any{"epoch": g.Epoch, "data": g.Data}
	if g.State != "" {
		out["state"] = g.State
	}
	return out, nil
}

// putGroupState takes the group's state sealed for the current epoch, whose
// commit came without it. The first one counts: it is opaque here, and the
// members check it themselves.
func (a *API) putGroupState(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Epoch int64  `json:"epoch"`
		Data  string `json:"data"`
	}
	if err := readJSONLimit(w, r, &req, 2*maxStateBytes); err != nil {
		return err
	}
	if err := a.sealState(r.Context(), c, r.PathValue("id"), &req.Epoch, req.Data); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}

// sealState stores convID's state for epoch, at its hub if another server
// orders it.
func (a *API) sealState(ctx context.Context, c *Caller, convID string, epoch *int64, data string) error {
	if err := a.requireMember(ctx, convID, c); err != nil {
		return err
	}
	if data == "" || epoch == nil {
		return badRequest("data must be non-empty base64")
	}
	if err := validateState(data); err != nil {
		return err
	}
	if hub, err := a.mirrorHub(ctx, convID); err != nil {
		return err
	} else if hub != "" {
		return a.relay(ctx, c, hub, "conv.state", map[string]any{"conv": convID, "epoch": *epoch, "data": data}, nil)
	}
	return a.store.AppendEvents(ctx, func(tx *store.Tx) (func(), error) {
		if err := requireVerified(tx, c); err != nil {
			return nil, err
		}
		current, err := tx.ConversationEpoch(convID)
		if err != nil {
			return nil, err
		}
		if *epoch != current {
			return nil, &Error{http.StatusConflict, "epoch_mismatch", "The conversation moved on"}
		}
		stored, err := tx.PutGroupState(convID, data)
		if err != nil {
			return nil, err
		}
		if !stored {
			return nil, &Error{http.StatusConflict, "state_exists", "Another member sealed it already"}
		}
		ev, send, err := a.appendConvEvent(tx, convID, protocol.EventGroupState,
			eventData(map[string]any{"epoch": current, "data": data, "from": c.UserID, "device": c.SessionID}),
			store.AppendOptions{})
		if err != nil {
			return nil, err
		}
		members, err := tx.MemberIDs(convID)
		c.Log.Debug("group state sealed", "conv", convID, "epoch", current)
		return func() {
			send()
			a.hub.Publish(ev, members)
		}, err
	})
}

// Key packages

func (a *API) uploadKeyPackages(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Packages   []string `json:"packages"`
		LastResort string   `json:"lastResort"`
	}
	if err := readJSONLimit(w, r, &req, 4*maxMLSBytes); err != nil {
		return err
	}
	ctx := r.Context()
	devices, err := a.store.DeviceKeysOf(ctx, c.UserID)
	if err != nil {
		return err
	}
	verified := false
	for _, d := range devices {
		verified = verified || (d.DeviceID == c.SessionID && d.Signature != nil)
	}
	if !verified {
		return &Error{http.StatusForbidden, "not_verified", "Only verified devices publish key packages"}
	}
	count, _, err := a.store.KeyPackageCount(ctx, c.SessionID)
	if err != nil {
		return err
	}
	if count+len(req.Packages) > maxKeyPackages {
		return badRequest("too many key packages")
	}
	for _, p := range append(append([]string{}, req.Packages...), req.LastResort) {
		if p == "" {
			continue
		}
		if err := decodeBase64(p, 64*1024, "key package"); err != nil {
			return err
		}
	}
	if err := a.store.AddKeyPackages(ctx, c.SessionID, req.Packages, req.LastResort); err != nil {
		return err
	}
	c.Log.Debug("key packages uploaded", "packages", len(req.Packages), "last_resort", req.LastResort != "")
	return a.keyPackageCount(w, r, c)
}

func (a *API) keyPackageCount(w http.ResponseWriter, r *http.Request, c *Caller) error {
	count, lastResort, err := a.store.KeyPackageCount(r.Context(), c.SessionID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"count": count, "lastResort": lastResort})
	return nil
}

// claimKeyPackages returns one key package per requested device; devices
// without any are left out.
func (a *API) claimKeyPackages(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Devices []string `json:"devices"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	if len(req.Devices) > maxWelcomes {
		return badRequest("too many devices")
	}
	out := map[string]string{}
	var missing []string
	allowed := map[string]bool{c.UserID: true}
	// Devices of users of other servers, by server: claimed from those.
	remote := map[string][]string{}
	for _, d := range req.Devices {
		owner, err := a.store.SessionOwner(r.Context(), d)
		if errors.Is(err, store.ErrNotFound) {
			if owner, err := a.store.RemoteDeviceOwner(r.Context(), d); err == nil {
				remote[hostOf(owner)] = append(remote[hostOf(owner)], d)
				continue
			}
			missing = append(missing, d)
			continue
		} else if err != nil {
			return err
		}
		// One-time packages are spent by claiming them, and only someone about
		// to add their owner has any use for them.
		ok, seen := allowed[owner]
		if !seen {
			if ok, err = a.store.MayClaimPackagesOf(r.Context(), c.UserID, owner); err != nil {
				return err
			}
			allowed[owner] = ok
		}
		if !ok {
			return errNotAContact
		}
		data, err := a.store.ClaimKeyPackage(r.Context(), d)
		if errors.Is(err, store.ErrNotFound) {
			missing = append(missing, d)
			continue
		} else if err != nil {
			return err
		}
		out[d] = data
	}
	for host, devices := range remote {
		packages, err := a.claimRemote(r.Context(), c.UserID, host, devices)
		if err != nil {
			return err
		}
		for _, d := range devices {
			if data, ok := packages[d]; ok {
				out[d] = data
			} else {
				missing = append(missing, d)
			}
		}
	}
	c.Log.Debug("key packages claimed", "devices", len(req.Devices), "found", len(out), "missing", missing)
	writeJSON(w, http.StatusOK, map[string]any{"packages": out})
	return nil
}

// Device inbox

type inboxItemJSON struct {
	store.InboxItem
	Data json.RawMessage `json:"data"`
}

func inboxJSON(item store.InboxItem) inboxItemJSON {
	return inboxItemJSON{InboxItem: item, Data: json.RawMessage(item.Payload)}
}

// pushInbox delivers an inbox item live if the device is online; it stays
// in the inbox until the device acknowledges it either way.
func (a *API) pushInbox(userID, deviceID string, item store.InboxItem) {
	a.hub.SendToDevice(userID, deviceID, map[string]any{"type": protocol.FrameInbox, "item": inboxJSON(item)})
}

func (a *API) inbox(w http.ResponseWriter, r *http.Request, c *Caller) error {
	items, err := a.store.Inbox(r.Context(), c.SessionID, inboxPageLimit)
	if err != nil {
		return err
	}
	out := []inboxItemJSON{}
	for _, item := range items {
		out = append(out, inboxJSON(item))
	}
	c.Log.Debug("inbox", "items", len(out))
	writeJSON(w, http.StatusOK, map[string]any{"items": out})
	return nil
}

func (a *API) ackInbox(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		IDs []int64 `json:"ids"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return err
	}
	if err := a.store.AckInbox(r.Context(), c.SessionID, req.IDs); err != nil {
		return err
	}
	c.Log.Debug("inbox acknowledged", "items", len(req.IDs))
	writeJSON(w, http.StatusOK, struct{}{})
	return nil
}
