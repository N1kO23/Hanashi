// Package federation is how servers talk to each other (see "Federation" in
// docs/protocol.md): finding another server, proving which server a request
// comes from, queries answered at once, and items carried in order and
// retried until the other server has them.
package federation

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/oklog/ulid/v2"

	"hanashi/server/internal/config"
	"hanashi/server/internal/netguard"
	"hanashi/server/internal/protocol"
	"hanashi/server/internal/store"
)

// Prefix starts the path of every request between servers.
const Prefix = "/federation/v1/"

const (
	keyPath       = Prefix + "key"
	sendPath      = Prefix + "send"
	ephemeralPath = Prefix + "ephemeral"
	// MaxBodyBytes bounds a request between servers.
	MaxBodyBytes = 4 << 20
	// How far another server's clock may be from this one's.
	maxClockSkew = 5 * time.Minute
	queryTimeout = 10 * time.Second
	tellTimeout  = 5 * time.Second
)

// Options say whom a server federates with.
type Options struct {
	// Host is this server's host.
	Host    string
	Enabled bool
	// Servers are the only ones federated with, unless AnyServer.
	Servers   map[string]bool
	AnyServer bool
	// Resolve gives the addresses of hosts instead of looking them up.
	Resolve map[string]string
	// AllowPrivate lets looked-up addresses be on loopback or private
	// networks (tests); those named in Resolve always may.
	AllowPrivate bool
	// Rate is how many requests a second each other server may make (0:
	// DefaultRate), in bursts of Burst (0: ten seconds' worth); InFlight how
	// many from all of them may be under way at once (0: 64).
	Rate     float64
	Burst    int
	InFlight int
}

// OptionsOf takes the options from the server's configuration.
func OptionsOf(cfg config.Config) Options {
	return Options{Host: cfg.Host, Enabled: cfg.Federation, Servers: cfg.FederationServers,
		AnyServer: cfg.FederationAnyServer, Resolve: cfg.FederationResolve,
		Rate: cfg.FederationRate, Burst: cfg.FederationBurst, InFlight: cfg.FederationInFlight}
}

// Queue is where items wait for other servers (store.Store).
type Queue interface {
	FederationDestinations(ctx context.Context) ([]string, error)
	FederationItems(ctx context.Context, destination string, limit, maxBytes int) ([]store.QueuedItem, error)
	DropFederationItems(ctx context.Context, destination string, upTo int64) error
	ExpireFederationItems(ctx context.Context, destination string, before int64) (int64, error)
	FederationServer(ctx context.Context, host string) (store.FederationServer, error)
	SetFederationServer(ctx context.Context, host string, f store.FederationServer) error
}

type Federation struct {
	opts  Options
	queue Queue
	log   *slog.Logger
	key   ed25519.PrivateKey
	keyID string
	// stream names this server's run of item IDs, which start again if its
	// database does.
	stream string
	// public reaches the addresses hosts give; trusted those of Resolve.
	public, trusted *http.Client
	limits          *limits

	mu sync.Mutex
	// Where each host's server answers, until when.
	addresses map[string]address
	// Each host's keys by ID, and when they were last fetched.
	keys      map[string]map[string]ed25519.PublicKey
	keysFetch map[string]time.Time
	// The destinations being sent to, with what wakes their sender; and the
	// context senders run in, once Run starts.
	senders map[string]chan struct{}
	ctx     context.Context
}

// Setup loads the server's signing key, creating it on first start.
func Setup(ctx context.Context, st *store.Store, opts Options, log *slog.Logger) (*Federation, error) {
	seed, err := st.ServerSecret(ctx, "federation_key", func() (string, error) {
		_, key, err := ed25519.GenerateKey(rand.Reader)
		return base64.StdEncoding.EncodeToString(key.Seed()), err
	})
	if err != nil {
		return nil, err
	}
	raw, err := base64.StdEncoding.DecodeString(seed)
	if err != nil || len(raw) != ed25519.SeedSize {
		return nil, errors.New("federation: the stored signing key is damaged")
	}
	stream, err := st.ServerSecret(ctx, "federation_stream", func() (string, error) { return ulid.Make().String(), nil })
	if err != nil {
		return nil, err
	}
	return New(opts, ed25519.NewKeyFromSeed(raw), stream, st, log), nil
}

// New makes a Federation signing with key; Setup is what servers use.
func New(opts Options, key ed25519.PrivateKey, stream string, queue Queue, log *slog.Logger) *Federation {
	return &Federation{
		opts:   opts,
		queue:  queue,
		log:    log,
		key:    key,
		keyID:  keyIDOf(key.Public().(ed25519.PublicKey)),
		stream: stream,
		// Every request has a context with its deadline: files take longer.
		public:    netguard.Client(opts.AllowPrivate, 0),
		trusted:   netguard.Client(true, 0),
		limits:    newLimits(opts),
		addresses: map[string]address{},
		keys:      map[string]map[string]ed25519.PublicKey{},
		keysFetch: map[string]time.Time{},
		senders:   map[string]chan struct{}{},
	}
}

func keyIDOf(key ed25519.PublicKey) string {
	return "ed25519:" + base64.RawURLEncoding.EncodeToString(key[:8])
}

func (f *Federation) Enabled() bool { return f.opts.Enabled }

// Allowed reports whether this server federates with host's.
func (f *Federation) Allowed(host string) bool {
	if !f.opts.Enabled || host == f.opts.Host || !protocol.ValidHost(host) {
		return false
	}
	if _, ok := f.opts.Resolve[host]; !ok && !config.PublicHost(host) {
		return false
	}
	return f.opts.AnyServer || f.opts.Servers[host]
}

// KeyDocument is what GET /federation/v1/key answers.
func (f *Federation) KeyDocument() map[string]string {
	return map[string]string{
		"host":  f.opts.Host,
		"keyId": f.keyID,
		"key":   base64.StdEncoding.EncodeToString(f.key.Public().(ed25519.PublicKey)),
	}
}

// Error is a refusal: another server's answer that was not a success, or
// this server's to a request from another.
type Error struct {
	Status        int
	Code, Message string
	// RetryAfter is when to ask again, if it said so.
	RetryAfter time.Duration
}

func (e *Error) Error() string { return fmt.Sprintf("%d %s: %s", e.Status, e.Code, e.Message) }

// ErrNotAllowed: this server does not federate with that one.
var ErrNotAllowed = errors.New("federation: not allowed with that server")

// Unreachable is another server not answering, or not in a way that counts.
type Unreachable struct{ Err error }

func (e *Unreachable) Error() string { return "federation: unreachable: " + e.Err.Error() }
func (e *Unreachable) Unwrap() error { return e.Err }
