package livekit

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Client calls LiveKit's room API (Twirp, with JSON) as this server.
type Client struct {
	// URL is LiveKit's http(s) address.
	URL  string
	Keys Keys
	HTTP *http.Client
}

// APIError is LiveKit's answer to a call it refused.
type APIError struct {
	Status int
	Code   string
	Msg    string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("livekit: %d %s: %s", e.Status, e.Code, e.Msg)
}

func notFound(err error) bool {
	e, ok := err.(*APIError)
	return ok && (e.Code == "not_found" || e.Status == http.StatusNotFound)
}

func (c *Client) call(ctx context.Context, method string, grant Grant, request, response any) error {
	token, err := c.Keys.Token("", grant, time.Now(), time.Minute)
	if err != nil {
		return err
	}
	body, err := json.Marshal(request)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.URL+"/twirp/livekit.RoomService/"+method, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return err
	}
	if res.StatusCode != http.StatusOK {
		var twirp struct {
			Code string `json:"code"`
			Msg  string `json:"msg"`
		}
		json.Unmarshal(raw, &twirp)
		return &APIError{Status: res.StatusCode, Code: twirp.Code, Msg: twirp.Msg}
	}
	if response == nil {
		return nil
	}
	return json.Unmarshal(raw, response)
}

// DeleteRoom ends a room, disconnecting everyone in it. One that is not
// there is fine.
func (c *Client) DeleteRoom(ctx context.Context, room string) error {
	err := c.call(ctx, "DeleteRoom", Grant{RoomCreate: true}, map[string]string{"room": room}, nil)
	if notFound(err) {
		return nil
	}
	return err
}

// ListParticipants returns who is in a room: none if it is not there.
func (c *Client) ListParticipants(ctx context.Context, room string) ([]Participant, error) {
	var response struct {
		Participants []Participant `json:"participants"`
	}
	err := c.call(ctx, "ListParticipants", Grant{Room: room, RoomAdmin: true}, map[string]string{"room": room}, &response)
	if notFound(err) {
		return nil, nil
	}
	return response.Participants, err
}

// RemoveParticipant disconnects identity from a room; one that is not there
// is fine.
func (c *Client) RemoveParticipant(ctx context.Context, room, identity string) error {
	err := c.call(ctx, "RemoveParticipant", Grant{Room: room, RoomAdmin: true},
		map[string]string{"room": room, "identity": identity}, nil)
	if notFound(err) {
		return nil
	}
	return err
}
