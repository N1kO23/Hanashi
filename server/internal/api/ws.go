package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/coder/websocket"

	"hanashi/server/internal/hub"
	"hanashi/server/internal/protocol"
)

const (
	authTimeout  = 10 * time.Second
	pingInterval = 30 * time.Second
	// Room for a commit with its GroupInfo and Welcomes.
	maxFrameBytes = 4 * maxMLSBytes
)

// clientFrame is any frame a client sends; unused fields stay empty.
type clientFrame struct {
	Type     string          `json:"type"`
	Token    string          `json:"token"`
	Client   int             `json:"client"`
	RID      string          `json:"rid"`
	Envelope json.RawMessage `json:"envelope"`
	Conv     string          `json:"conv"`
	UpTo     *int64          `json:"upTo"`
	Commit   *commitInput    `json:"commit"`
	State    string          `json:"state"`
}

// webSocket authenticates with the first frame, then pushes live events and
// handles send/read/typing requests. Each request carries a client-chosen
// "rid" that the matching ack or nack echoes.
func (a *API) webSocket(w http.ResponseWriter, r *http.Request) {
	// Native apps send no Origin; tokens are not cookies, so cross-origin
	// pages gain nothing from connecting.
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	ws.SetReadLimit(maxFrameBytes)
	ctx := r.Context()

	caller, err := a.authenticateSocket(ctx, ws)
	if err != nil {
		a.log.Debug("websocket refused", "err", err)
		refusal, status := errUnauthorized, websocket.StatusCode(4001)
		if errors.Is(err, errClientTooOld) {
			refusal, status = errClientTooOld, 4002
		}
		data, _ := json.Marshal(map[string]string{"type": protocol.FrameError, "error": refusal.Code})
		_ = ws.Write(ctx, websocket.MessageText, data)
		_ = ws.Close(status, refusal.Code)
		return
	}
	mode, err := a.store.PresenceMode(ctx, caller.UserID)
	if err != nil {
		mode = protocol.ModeAuto
	}
	conn := hub.NewConn(ws, caller.UserID, caller.SessionID)
	a.hub.Add(conn, mode)
	defer func() {
		a.hub.Remove(conn)
		a.presenceChanged(caller.UserID)
	}()
	caller.Log.Debug("websocket connected")
	conn.Send(map[string]string{"type": protocol.FrameReady})
	a.sendPresence(ctx, conn)
	a.presenceChanged(caller.UserID)

	go func() {
		ticker := time.NewTicker(pingInterval)
		defer ticker.Stop()
		for {
			select {
			case <-conn.Done():
				return
			case <-ticker.C:
				pingCtx, cancel := context.WithTimeout(ctx, pingInterval/2)
				err := ws.Ping(pingCtx)
				cancel()
				if err != nil {
					caller.Log.Debug("websocket ping unanswered", "err", err)
					conn.Close(websocket.StatusGoingAway, "ping timeout")
					return
				}
			}
		}
	}()

	for {
		_, data, err := ws.Read(ctx)
		if err != nil {
			caller.Log.Debug("websocket closed", "status", websocket.CloseStatus(err), "err", err)
			conn.Close(websocket.StatusNormalClosure, "")
			return
		}
		var frame clientFrame
		if err := json.Unmarshal(data, &frame); err != nil {
			caller.Log.Debug("websocket closed: bad frame")
			conn.Close(websocket.StatusUnsupportedData, "bad frame")
			return
		}
		a.handleFrame(ctx, conn, caller, frame)
	}
}

func (a *API) authenticateSocket(ctx context.Context, ws *websocket.Conn) (*Caller, error) {
	authCtx, cancel := context.WithTimeout(ctx, authTimeout)
	defer cancel()
	_, data, err := ws.Read(authCtx)
	if err != nil {
		return nil, err
	}
	var frame clientFrame
	if err := json.Unmarshal(data, &frame); err != nil || frame.Type != protocol.FrameAuth {
		return nil, errUnauthorized
	}
	if frame.Client < a.cfg.MinClient {
		return nil, errClientTooOld
	}
	return a.authenticate(ctx, frame.Token)
}

func (a *API) handleFrame(ctx context.Context, conn *hub.Conn, c *Caller, f clientFrame) {
	if f.Type != protocol.FrameTyping {
		c.Log.Debug("frame", "type", f.Type, "rid", f.RID, "conv", f.Conv)
	}
	switch f.Type {
	case protocol.FrameSend:
		seq, err := a.postMessage(ctx, c, f.Envelope)
		if err != nil {
			a.nack(conn, c, f.RID, err)
			return
		}
		conn.Send(map[string]any{"type": protocol.FrameAck, "rid": f.RID, "seq": seq})
	case protocol.FrameRead:
		if f.UpTo == nil {
			a.nack(conn, c, f.RID, badRequest(`"upTo" is required`))
			return
		}
		readUpTo, err := a.markRead(ctx, c, f.Conv, *f.UpTo)
		if err != nil {
			a.nack(conn, c, f.RID, err)
			return
		}
		conn.Send(map[string]any{"type": protocol.FrameAck, "rid": f.RID, "readUpTo": readUpTo})
	case protocol.FrameCommit:
		if f.Commit == nil {
			a.nack(conn, c, f.RID, badRequest(`"commit" is required`))
			return
		}
		seq, err := a.commit(ctx, c, f.Conv, *f.Commit)
		if err != nil {
			a.nack(conn, c, f.RID, err)
			return
		}
		conn.Send(map[string]any{"type": protocol.FrameAck, "rid": f.RID, "seq": seq})
	case protocol.FramePresence:
		switch f.State {
		case "active", "idle":
			if a.hub.SetIdle(conn, f.State == "idle") {
				a.presenceChanged(c.UserID)
			}
		case "":
			a.sendPresence(ctx, conn) // Someone new may share a conversation now.
		}
	case protocol.FrameTyping:
		if members, err := a.store.MemberIDs(ctx, f.Conv); err == nil {
			for _, m := range members {
				if m == c.UserID {
					a.hub.Typing(f.Conv, c.UserID, members)
					a.tellTyping(f.Conv, c.UserID, members)
					break
				}
			}
		}
	default:
		if f.RID != "" {
			a.nack(conn, c, f.RID, badRequest("Unknown frame type "+f.Type))
		}
	}
}

func (a *API) nack(conn *hub.Conn, c *Caller, rid string, err error) {
	apiErr := a.toAPIError(err)
	if apiErr.Status == http.StatusInternalServerError && !errors.Is(err, context.Canceled) {
		c.Log.Error("websocket request failed", "err", err)
	}
	c.Log.Debug("request refused", "rid", rid, "error", apiErr.Code, "message", apiErr.Message)
	frame := map[string]any{"type": protocol.FrameNack, "rid": rid, "error": apiErr.Code, "status": apiErr.Status}
	if apiErr.Message != "" {
		frame["message"] = apiErr.Message
	}
	if server := serverOf(err); server != "" {
		frame["server"] = server
	}
	conn.Send(frame)
}
