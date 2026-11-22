// Package config reads server settings from HANASHI_* environment variables.
package config

import (
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"hanashi/server/internal/protocol"
)

type Registration string

const (
	RegistrationOpen   Registration = "open"
	RegistrationInvite Registration = "invite"
	RegistrationClosed Registration = "closed"
)

type Config struct {
	// Host is the public host name: the host part of every user ID.
	Host           string
	Bind           string
	Port           int
	DataDir        string
	Registration   Registration
	InviteCodes    map[string]bool
	MaxUploadBytes int64
	// DatabaseDSN is a go-sql-driver/mysql DSN for MariaDB.
	DatabaseDSN string
	// CreateDatabase creates the DSN's database if it does not exist.
	CreateDatabase bool
	// MinClient is the lowest client level served: protocol.MinClient, or
	// more if the operator wants older apps gone.
	MinClient int
	// LeaseDuration is how long a device may hold a conversation's commit
	// lease (30 s unless a test shortens it).
	LeaseDuration time.Duration
	// PresenceInterval is how often this server repeats its users' statuses
	// to other servers, which forget them after a few times that (2 min
	// unless a test shortens it).
	PresenceInterval time.Duration
	// PushContact is how push services can reach the operator (mailto: or
	// https: URL); it goes into every push's VAPID signature.
	PushContact string
	// PushAllowPrivate lets push endpoints be on loopback or private
	// networks, e.g. a UnifiedPush distributor on the local network.
	PushAllowPrivate bool
	// KlipyAPIKey enables GIF search: signed-in apps get it and call KLIPY
	// themselves (KLIPY does not allow calls through a server).
	KlipyAPIKey string
	// SourceURL is where this server's source code is; apps show it to its
	// users. The AGPL asks whoever runs a changed server for others to offer
	// them its source, so a changed server's operator points it at theirs.
	// DefaultSourceURL unless set.
	SourceURL string
	// LogLevel is the least important level logged. Debug adds each lease,
	// commit, key change, sync and WebSocket frame, by user and device (never
	// message contents, keys or tokens).
	LogLevel slog.Level
	// Federation lets users reach those of other servers, and theirs reach
	// them (see docs/federation.md). Off unless the operator turns it on.
	Federation bool
	// FederationServers are the only other servers federated with, unless
	// FederationAnyServer: the operator asked for any (HANASHI_FEDERATION_SERVERS=*).
	// Federation needs one or the other.
	FederationServers   map[string]bool
	FederationAnyServer bool
	// FederationResolve gives the address of other servers' hosts instead of
	// looking them up: for tests and private networks, and the only way to
	// reach one over http://.
	FederationResolve map[string]string
	// FederationRate is how many requests a second each other server may
	// make; FederationBurst and FederationInFlight are for tests (see
	// federation.Options).
	FederationRate     float64
	FederationBurst    int
	FederationInFlight int
	// HandOver is what this server hands over to the servers of their other
	// members, which order them from then on: the groups none of its users
	// are in (HandOverGroupsLeft), or everything it orders (HandOverAll), for
	// an operator about to shut it down. See docs/federation.md.
	HandOver HandOver
	// HandOverRetry is how long a conversation that could not be handed over
	// waits for its next try, at first (10 minutes, doubling up to 6 hours);
	// with HandOverAll, also how often the server looks for new ones. Tests
	// shorten it.
	HandOverRetry time.Duration
	// NoHubMove makes the server one that cannot follow a conversation to
	// another hub, as servers before 1.1.0 cannot (for tests).
	NoHubMove bool
	// LiveKitURL is where apps reach the LiveKit server that carries calls
	// (ws:// or wss://; see docs/calls.md), with tokens this server signs
	// with LiveKitAPIKey and LiveKitAPISecret. LiveKitAPIURL is where this
	// server reaches LiveKit's API: the same host over http(s) unless set.
	// No URL: no calls.
	LiveKitURL       string
	LiveKitAPIURL    string
	LiveKitAPIKey    string
	LiveKitAPISecret string
	// CallRingTimeout is how long a call of two rings before it is missed
	// (45 s). CallSweepInterval and CallReconcileInterval are how often calls
	// are looked over, and compared with LiveKit's rooms (2 s and 15 s
	// unless a test shortens them).
	CallRingTimeout       time.Duration
	CallSweepInterval     time.Duration
	CallReconcileInterval time.Duration
}

type HandOver string

const (
	HandOverGroupsLeft HandOver = "auto"
	HandOverAll        HandOver = "all"
)

// Calls reports whether the operator set up a LiveKit server for calls.
func (c Config) Calls() bool { return c.LiveKitURL != "" }

var klipyAPIKey = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// DefaultSourceURL is Hanashi's own repository: the source of a server that
// nobody changed.
const DefaultSourceURL = "https://github.com/N1kO23/Hanashi"

func (c Config) MediaDir() string { return filepath.Join(c.DataDir, "media") }

// PublicHost reports whether host could be reached by other servers: a domain
// name, not localhost, an IP address or anything with a port. User IDs and
// keys are tied to the host for good, so a server cannot move to one later.
func PublicHost(host string) bool {
	return strings.Contains(host, ".") && !strings.Contains(host, ":") && net.ParseIP(host) == nil &&
		!strings.HasSuffix(host, ".localhost") && !strings.HasSuffix(host, ".local")
}

// FromEnv builds a Config from a lookup function such as os.LookupEnv.
func FromEnv(lookup func(string) (string, bool)) (Config, error) {
	get := func(key, fallback string) string {
		if v, ok := lookup(key); ok && v != "" {
			return v
		}
		return fallback
	}
	cfg := Config{
		Host:         get("HANASHI_HOST", "localhost"),
		Bind:         get("HANASHI_BIND", "0.0.0.0"),
		DataDir:      get("HANASHI_DATA_DIR", "data"),
		Registration: Registration(get("HANASHI_REGISTRATION", "open")),
		InviteCodes:  map[string]bool{},
		DatabaseDSN:  get("HANASHI_DB_DSN", ""),
	}
	if !protocol.ValidHost(cfg.Host) {
		return cfg, fmt.Errorf("HANASHI_HOST %q is not a valid host name", cfg.Host)
	}
	port, err := strconv.Atoi(get("HANASHI_PORT", "8080"))
	if err != nil || port < 0 || port > 65535 {
		return cfg, fmt.Errorf("HANASHI_PORT must be a port number")
	}
	cfg.Port = port
	switch cfg.Registration {
	case RegistrationOpen, RegistrationInvite, RegistrationClosed:
	default:
		return cfg, fmt.Errorf("HANASHI_REGISTRATION must be open, invite or closed")
	}
	for _, code := range strings.Split(get("HANASHI_INVITE_CODES", ""), ",") {
		if code = strings.TrimSpace(code); code != "" {
			cfg.InviteCodes[code] = true
		}
	}
	mb, err := strconv.ParseInt(get("HANASHI_MAX_UPLOAD_MB", "100"), 10, 64)
	if err != nil || mb <= 0 {
		return cfg, fmt.Errorf("HANASHI_MAX_UPLOAD_MB must be a positive number")
	}
	cfg.MaxUploadBytes = mb * 1024 * 1024
	if cfg.DatabaseDSN == "" {
		return cfg, fmt.Errorf("HANASHI_DB_DSN is required, e.g. hanashi:secret@tcp(localhost:3306)/hanashi")
	}
	cfg.CreateDatabase, _ = strconv.ParseBool(get("HANASHI_DB_CREATE", "false"))
	minClient, err := strconv.Atoi(get("HANASHI_MIN_CLIENT", "0"))
	if err != nil || minClient < 0 {
		return cfg, fmt.Errorf("HANASHI_MIN_CLIENT must be a client level: 0 or more")
	}
	cfg.MinClient = max(minClient, protocol.MinClient)
	cfg.LeaseDuration = 30 * time.Second
	cfg.PresenceInterval = 2 * time.Minute
	cfg.PushContact = get("HANASHI_PUSH_CONTACT", "mailto:admin@"+cfg.Host)
	if !strings.HasPrefix(cfg.PushContact, "mailto:") && !strings.HasPrefix(cfg.PushContact, "https://") {
		return cfg, fmt.Errorf("HANASHI_PUSH_CONTACT must be a mailto: or https:// URL")
	}
	cfg.PushAllowPrivate, _ = strconv.ParseBool(get("HANASHI_PUSH_ALLOW_PRIVATE", "false"))
	cfg.KlipyAPIKey = get("HANASHI_KLIPY_API_KEY", "")
	if cfg.KlipyAPIKey != "" && !klipyAPIKey.MatchString(cfg.KlipyAPIKey) {
		return cfg, fmt.Errorf("HANASHI_KLIPY_API_KEY may only contain letters, digits, \"-\" and \"_\"")
	}
	cfg.SourceURL = get("HANASHI_SOURCE_URL", DefaultSourceURL)
	if u, err := url.Parse(cfg.SourceURL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return cfg, fmt.Errorf("HANASHI_SOURCE_URL must be an http:// or https:// URL")
	}
	if err := cfg.LogLevel.UnmarshalText([]byte(get("HANASHI_LOG_LEVEL", "info"))); err != nil {
		return cfg, fmt.Errorf("HANASHI_LOG_LEVEL must be debug, info, warn or error")
	}
	switch get("HANASHI_FEDERATION", "off") {
	case "on":
		cfg.Federation = true
	case "off":
	default:
		return cfg, fmt.Errorf("HANASHI_FEDERATION must be on or off")
	}
	cfg.FederationServers = map[string]bool{}
	for _, host := range strings.Split(get("HANASHI_FEDERATION_SERVERS", ""), ",") {
		if host = strings.ToLower(strings.TrimSpace(host)); host == "" {
			continue
		} else if host == "*" {
			cfg.FederationAnyServer = true
		} else if !protocol.ValidHost(host) {
			return cfg, fmt.Errorf("HANASHI_FEDERATION_SERVERS: %q is not a host name", host)
		} else {
			cfg.FederationServers[host] = true
		}
	}
	switch {
	case cfg.FederationAnyServer && len(cfg.FederationServers) > 0:
		return cfg, fmt.Errorf("HANASHI_FEDERATION_SERVERS is either * (any server) or a list of servers, not both")
	case cfg.Federation && !cfg.FederationAnyServer && len(cfg.FederationServers) == 0:
		return cfg, fmt.Errorf("HANASHI_FEDERATION=on needs HANASHI_FEDERATION_SERVERS: the servers to federate with, " +
			"comma-separated, or * for any server")
	}
	rate, err := strconv.ParseFloat(get("HANASHI_FEDERATION_RATE", "100"), 64)
	if err != nil || rate <= 0 {
		return cfg, fmt.Errorf("HANASHI_FEDERATION_RATE must be a number of requests a second, above 0")
	}
	cfg.FederationRate = rate
	switch cfg.HandOver = HandOver(get("HANASHI_HAND_OVER", string(HandOverGroupsLeft))); cfg.HandOver {
	case HandOverGroupsLeft:
	case HandOverAll:
		if !cfg.Federation {
			return cfg, fmt.Errorf("HANASHI_HAND_OVER=all hands conversations to other servers: it needs HANASHI_FEDERATION=on")
		}
	default:
		return cfg, fmt.Errorf("HANASHI_HAND_OVER must be auto or all")
	}
	cfg.HandOverRetry = 10 * time.Minute
	cfg.FederationResolve = map[string]string{}
	for _, pair := range strings.Split(get("HANASHI_FEDERATION_RESOLVE", ""), ",") {
		if pair = strings.TrimSpace(pair); pair == "" {
			continue
		}
		host, address, _ := strings.Cut(pair, "=")
		u, err := url.Parse(address)
		if !protocol.ValidHost(host) || err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return cfg, fmt.Errorf("HANASHI_FEDERATION_RESOLVE: %q is not host=http(s)://address", pair)
		}
		cfg.FederationResolve[host] = strings.TrimSuffix(address, "/")
	}
	if err := cfg.readLiveKit(get); err != nil {
		return cfg, err
	}
	cfg.CallRingTimeout = 45 * time.Second
	cfg.CallSweepInterval = 2 * time.Second
	cfg.CallReconcileInterval = 15 * time.Second
	return cfg, nil
}

// readLiveKit takes the LiveKit settings: all of them, or none (no calls).
func (cfg *Config) readLiveKit(get func(key, fallback string) string) error {
	cfg.LiveKitURL = strings.TrimSuffix(get("HANASHI_LIVEKIT_URL", ""), "/")
	cfg.LiveKitAPIURL = strings.TrimSuffix(get("HANASHI_LIVEKIT_API_URL", ""), "/")
	cfg.LiveKitAPIKey = get("HANASHI_LIVEKIT_API_KEY", "")
	cfg.LiveKitAPISecret = get("HANASHI_LIVEKIT_API_SECRET", "")
	given := 0
	for _, v := range []string{cfg.LiveKitURL, cfg.LiveKitAPIKey, cfg.LiveKitAPISecret} {
		if v != "" {
			given++
		}
	}
	if given == 0 && cfg.LiveKitAPIURL == "" {
		return nil
	}
	if given != 3 {
		return fmt.Errorf("calls need HANASHI_LIVEKIT_URL, HANASHI_LIVEKIT_API_KEY and HANASHI_LIVEKIT_API_SECRET, all three")
	}
	u, err := url.Parse(cfg.LiveKitURL)
	if err != nil || (u.Scheme != "ws" && u.Scheme != "wss") || u.Host == "" {
		return fmt.Errorf("HANASHI_LIVEKIT_URL must be a ws:// or wss:// URL")
	}
	if cfg.LiveKitAPIURL == "" {
		api := *u
		api.Scheme = map[string]string{"ws": "http", "wss": "https"}[u.Scheme]
		cfg.LiveKitAPIURL = strings.TrimSuffix(api.String(), "/")
	} else if a, err := url.Parse(cfg.LiveKitAPIURL); err != nil || (a.Scheme != "http" && a.Scheme != "https") || a.Host == "" {
		return fmt.Errorf("HANASHI_LIVEKIT_API_URL must be an http:// or https:// URL")
	}
	return nil
}
