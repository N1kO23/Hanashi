package federation

import (
	"math"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Limits on what other servers ask of this one: each may make so many
// requests a second, file fetches fewer, and only so many requests from all of
// them may be under way at once. Keys of servers not seen before are fetched
// only so often, so that requests naming made-up servers cannot make this one
// knock on many doors. Over a limit, a request is answered 429 (or 503) with
// when to try again, and the sender's queue waits that long.

const (
	// DefaultRate is how many requests a second each other server may make.
	DefaultRate = 100
	// How many requests from other servers may be under way at once.
	defaultInFlight = 64
	// How many keys of servers not seen before are fetched, a minute.
	newKeysPerMinute = 30
)

// limiter is a token bucket for each key: rate tokens a second, at most
// burst of them saved up.
type limiter struct {
	mu      sync.Mutex
	rate    float64
	burst   float64
	buckets map[string]*bucket
	pruned  time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

func newLimiter(rate float64, burst int) *limiter {
	return &limiter{rate: rate, burst: float64(max(burst, 1)), buckets: map[string]*bucket{}}
}

// take spends a token of key's; without one, it answers how long until
// there is one.
func (l *limiter) take(key string, now time.Time) (time.Duration, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if now.Sub(l.pruned) > time.Minute {
		// A bucket that has filled up again is as good as none.
		for k, b := range l.buckets {
			if b.tokens+now.Sub(b.last).Seconds()*l.rate >= l.burst {
				delete(l.buckets, k)
			}
		}
		l.pruned = now
	}
	b := l.buckets[key]
	if b == nil {
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}
	b.tokens = math.Min(l.burst, b.tokens+now.Sub(b.last).Seconds()*l.rate)
	b.last = now
	if b.tokens >= 1 {
		b.tokens--
		return 0, true
	}
	return time.Duration((1 - b.tokens) / l.rate * float64(time.Second)), false
}

// limits are this server's, as its options say.
type limits struct {
	requests, media, newKeys *limiter
	inFlight                 chan struct{}
}

func newLimits(opts Options) *limits {
	rate := opts.Rate
	if rate <= 0 {
		rate = DefaultRate
	}
	burst := opts.Burst
	if burst <= 0 {
		burst = int(rate * 10)
	}
	inFlight := opts.InFlight
	if inFlight <= 0 {
		inFlight = defaultInFlight
	}
	return &limits{
		requests: newLimiter(rate, burst),
		media:    newLimiter(math.Max(rate/10, 0.1), max(burst/10, 1)),
		newKeys:  newLimiter(newKeysPerMinute/60.0, newKeysPerMinute),
		inFlight: make(chan struct{}, inFlight),
	}
}

// allow spends one of origin's requests (for path), or refuses it.
func (l *limits) allow(origin, path string) error {
	now := time.Now()
	wait, ok := l.requests.take(origin, now)
	if ok && strings.HasSuffix(path, "/media") {
		wait, ok = l.media.take(origin, now)
	}
	if ok {
		return nil
	}
	return &Error{Status: http.StatusTooManyRequests, Code: "too_many_requests",
		Message: "Too many requests from " + origin + "; try again later", RetryAfter: wait}
}

// Admit lets a request from another server in, unless too many are under
// way; release lets the next one in.
func (f *Federation) Admit() (release func(), err error) {
	select {
	case f.limits.inFlight <- struct{}{}:
		return func() { <-f.limits.inFlight }, nil
	default:
		return nil, &Error{Status: http.StatusServiceUnavailable, Code: "busy",
			Message: "This server is busy; try again shortly", RetryAfter: time.Second}
	}
}
