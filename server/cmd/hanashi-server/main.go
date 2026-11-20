// Command hanashi-server runs the Hanashi chat server. Configuration is
// read from HANASHI_* environment variables; see the repository README.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"maps"
	"net"
	"net/http"
	"os"
	"os/signal"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"hanashi/server/internal/api"
	"hanashi/server/internal/config"
	"hanashi/server/internal/federation"
	"hanashi/server/internal/hub"
	"hanashi/server/internal/media"
	"hanashi/server/internal/push"
	"hanashi/server/internal/store"
)

func main() {
	// Set from the configuration (HANASHI_LOG_LEVEL) once it is read.
	level := new(slog.LevelVar)
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	if err := run(log, level); err != nil {
		log.Error("server stopped", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger, level *slog.LevelVar) error {
	cfg, err := config.FromEnv(os.LookupEnv)
	if err != nil {
		return fmt.Errorf("configuration: %w", err)
	}
	level.Set(cfg.LogLevel)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	st, err := store.Open(ctx, cfg.DatabaseDSN, cfg.CreateDatabase, time.Minute)
	if err != nil {
		return err
	}
	defer st.Close()
	mediaStore, err := media.NewStore(cfg.MediaDir())
	if err != nil {
		return err
	}
	h := hub.New()
	pusher, err := push.Setup(ctx, st, h, cfg.PushContact, log, push.Options{AllowPrivate: cfg.PushAllowPrivate})
	if err != nil {
		return fmt.Errorf("push: %w", err)
	}
	fed, err := federation.Setup(ctx, st, federation.OptionsOf(cfg), log)
	if err != nil {
		return fmt.Errorf("federation: %w", err)
	}
	handler := api.New(cfg, st, h, mediaStore, pusher, fed, log)

	listener, err := net.Listen("tcp", net.JoinHostPort(cfg.Bind, strconv.Itoa(cfg.Port)))
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second}
	log.Info("Hanashi server listening",
		"version", api.Version, "addr", listener.Addr().String(), "users", "name@"+cfg.Host,
		"registration", cfg.Registration, "data", cfg.DataDir, "log_level", cfg.LogLevel)
	if !config.PublicHost(cfg.Host) {
		log.Warn("HANASHI_HOST is not a public domain name. User IDs and keys are tied to it for good: "+
			"changing it later means new accounts, and other servers could never reach these ones",
			"host", cfg.Host)
	}
	if cfg.Federation {
		servers := "any (HANASHI_FEDERATION_SERVERS=*)"
		if !cfg.FederationAnyServer {
			servers = strings.Join(slices.Sorted(maps.Keys(cfg.FederationServers)), ",")
		}
		log.Info("Federating with other servers", "servers", servers)
		go fed.Run(ctx)
	}
	if cfg.Calls() {
		log.Info("Carrying calls through LiveKit", "url", cfg.LiveKitURL)
		if len(cfg.LiveKitAPISecret) < 32 {
			log.Warn("HANASHI_LIVEKIT_API_SECRET is short: use at least 32 random characters")
		}
	}
	go handler.Run(ctx)

	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(listener) }()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	log.Info("shutting down")
	h.CloseAll()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
