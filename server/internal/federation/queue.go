package federation

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"hanashi/server/internal/store"
)

const (
	// A transaction carries at most this many items, and about this many bytes.
	batchItems  = 100
	batchBytes  = 1 << 20
	sendTimeout = 60 * time.Second
	// The wait after a failed send starts at firstRetry and doubles, up to
	// lastRetry.
	firstRetry = time.Second
	lastRetry  = time.Hour
	// Items still waiting this long are given up on.
	itemLifetime = 30 * 24 * time.Hour
	// How often every destination is looked at, besides being woken.
	sweepInterval = time.Minute
)

// Enqueue puts item (a JSON object with a "type") on its way to host's
// server, in tx: nothing is told that did not happen, and nothing that
// happened goes untold. Once tx is committed, Wake sends it.
func Enqueue(tx *store.Tx, host string, item map[string]any) error {
	data, err := json.Marshal(item)
	if err != nil {
		return err
	}
	return tx.QueueFederationItem(host, string(data))
}

// Item is one thing another server tells this one, in the order it happened.
type Item struct {
	// ID is unique in the sender's stream, and grows.
	ID   int64  `json:"id"`
	Type string `json:"type"`
	// From and To are users of the sender's and of this server, for items
	// between two people; User is who an item about one person is about.
	From string `json:"from,omitempty"`
	To   string `json:"to,omitempty"`
	User string `json:"user,omitempty"`
}

// Transaction is the body of POST /federation/v1/send.
type Transaction struct {
	Header
	// Stream names the sender's run of item IDs; a new one starts them again.
	Stream string            `json:"stream"`
	Items  []json.RawMessage `json:"items"`
}

// Refusal is an item the receiver did not take, and why; it is not sent again.
type Refusal struct {
	ID    int64  `json:"id"`
	Error string `json:"error"`
}

// Run sends what waits for other servers until ctx ends.
func (f *Federation) Run(ctx context.Context) {
	if !f.opts.Enabled {
		return
	}
	f.mu.Lock()
	f.ctx = ctx
	f.mu.Unlock()
	ticker := time.NewTicker(sweepInterval)
	defer ticker.Stop()
	for {
		destinations, err := f.queue.FederationDestinations(ctx)
		if err != nil && ctx.Err() == nil {
			f.log.Warn("federation: listing what waits", "err", err)
		}
		for _, host := range destinations {
			f.Wake(host)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Wake sends what waits for host's server, unless that is under way.
func (f *Federation) Wake(host string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.ctx == nil {
		return
	}
	if wake, ok := f.senders[host]; ok {
		select {
		case wake <- struct{}{}:
		default:
		}
		return
	}
	wake := make(chan struct{}, 1)
	f.senders[host] = wake
	go f.send(f.ctx, host, wake)
}

// send carries host's items over in order, waiting longer and longer while
// its server cannot take them, until none wait.
func (f *Federation) send(ctx context.Context, host string, wake chan struct{}) {
	for ctx.Err() == nil {
		state, err := f.queue.FederationServer(ctx, host)
		if err != nil {
			f.log.Warn("federation: reading how sending goes", "to", host, "err", err)
			state = store.FederationServer{NextAttempt: time.Now().Add(firstRetry).UnixMilli()}
		}
		if wait := time.Until(time.UnixMilli(state.NextAttempt)); wait > 0 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(wait):
			}
		}
		if !f.Allowed(host) {
			break // Its items wait, should it be allowed again.
		}
		if n, err := f.queue.ExpireFederationItems(ctx, host, time.Now().Add(-itemLifetime).UnixMilli()); err != nil {
			f.log.Warn("federation: giving up on old items", "to", host, "err", err)
		} else if n > 0 {
			f.log.Warn("federation: gave up on items its server never took", "to", host, "items", n)
		}
		items, err := f.queue.FederationItems(ctx, host, batchItems, batchBytes)
		if err != nil {
			f.log.Warn("federation: reading what waits", "to", host, "err", err)
			f.failed(ctx, host, state, err)
			continue
		}
		if len(items) == 0 {
			// Done, unless woken meanwhile: Wake signals under the same lock.
			f.mu.Lock()
			select {
			case <-wake:
				f.mu.Unlock()
				continue
			default:
				delete(f.senders, host)
				f.mu.Unlock()
				return
			}
		}
		refused, err := f.transmit(ctx, host, items)
		if err != nil {
			f.failed(ctx, host, state, err)
			continue
		}
		for _, r := range refused {
			f.log.Warn("federation: an item was not taken", "to", host, "item", r.ID, "error", r.Error)
		}
		if err := f.queue.DropFederationItems(ctx, host, items[len(items)-1].ID); err != nil {
			f.log.Warn("federation: forgetting what was sent", "to", host, "err", err)
		}
		if state.Failures > 0 {
			f.log.Info("federation: sending again", "to", host, "after_failures", state.Failures)
			if err := f.queue.SetFederationServer(ctx, host, store.FederationServer{}); err != nil {
				f.log.Warn("federation: noting a send", "to", host, "err", err)
			}
		}
	}
	f.mu.Lock()
	delete(f.senders, host)
	f.mu.Unlock()
}

// failed notes a failed send, and when to try again.
func (f *Federation) failed(ctx context.Context, host string, state store.FederationServer, err error) {
	state.Failures++
	wait := retryAfter(state.Failures)
	var refused *Error
	if errors.As(err, &refused) && refused.RetryAfter > wait {
		wait = refused.RetryAfter // As it said, when it was too busy.
	}
	state.NextAttempt = time.Now().Add(wait).UnixMilli()
	state.LastError = err.Error()
	f.log.Info("federation: could not send", "to", host, "failures", state.Failures, "retry_in", wait, "err", err)
	if err := f.queue.SetFederationServer(ctx, host, state); err != nil {
		f.log.Warn("federation: noting a failed send", "to", host, "err", err)
	}
}

// retryAfter is the wait after failures failed sends in a row.
func retryAfter(failures int) time.Duration {
	wait := firstRetry
	for i := 1; i < failures && wait < lastRetry; i++ {
		wait *= 2
	}
	return min(wait, lastRetry)
}

func (f *Federation) transmit(ctx context.Context, host string, items []store.QueuedItem) ([]Refusal, error) {
	list := make([]json.RawMessage, 0, len(items))
	for _, item := range items {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal([]byte(item.Item), &fields); err != nil {
			return nil, err
		}
		fields["id"], _ = json.Marshal(item.ID)
		data, err := json.Marshal(fields)
		if err != nil {
			return nil, err
		}
		list = append(list, data)
	}
	ctx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	var answer struct {
		Refused []Refusal `json:"refused"`
	}
	err := f.post(ctx, host, sendPath, map[string]any{"stream": f.stream, "items": list}, &answer)
	return answer.Refused, err
}

// ParseTransaction reads the items of a verified POST /federation/v1/send,
// which must come in the order they were sent.
func ParseTransaction(body []byte) (string, []Item, []json.RawMessage, error) {
	var tx Transaction
	bad := &Error{Status: http.StatusBadRequest, Code: "bad_request", Message: "Not a transaction"}
	if json.Unmarshal(body, &tx) != nil || len(tx.Stream) != 26 || len(tx.Items) == 0 || len(tx.Items) > batchItems {
		return "", nil, nil, bad
	}
	items := make([]Item, len(tx.Items))
	for i, raw := range tx.Items {
		if err := json.Unmarshal(raw, &items[i]); err != nil || items[i].ID <= 0 || items[i].Type == "" ||
			(i > 0 && items[i].ID <= items[i-1].ID) {
			return "", nil, nil, bad
		}
	}
	return tx.Stream, items, tx.Items, nil
}
