package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"fileswitch/internal/store"
)

// Event is pushed to every connected device of a user over Server-Sent Events,
// so other devices see new files immediately.
type Event struct {
	Type        string      `json:"type"`
	Node        *store.Node `json:"node,omitempty"`
	ParentID    string      `json:"parent_id,omitempty"`
	OldParentID string      `json:"old_parent_id,omitempty"`
	DeviceID    string      `json:"device_id,omitempty"` // device that caused the change
	Target      string      `json:"target,omitempty"`    // device.revoked: the revoked device
}

type Hub struct {
	mu        sync.Mutex
	subs      map[string]map[chan []byte]struct{}
	onPublish func()
}

func NewHub() *Hub { return &Hub{subs: map[string]map[chan []byte]struct{}{}} }

func (h *Hub) Subscribe(userID string) (<-chan []byte, func()) {
	ch := make(chan []byte, 64)
	h.mu.Lock()
	if h.subs[userID] == nil {
		h.subs[userID] = map[chan []byte]struct{}{}
	}
	h.subs[userID][ch] = struct{}{}
	h.mu.Unlock()
	return ch, func() {
		h.mu.Lock()
		delete(h.subs[userID], ch)
		if len(h.subs[userID]) == 0 {
			delete(h.subs, userID)
		}
		h.mu.Unlock()
	}
}

func (h *Hub) Publish(userID string, ev Event) {
	b, err := json.Marshal(ev)
	if err != nil {
		return
	}
	if h.onPublish != nil {
		h.onPublish()
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs[userID] {
		select {
		case ch <- b:
		default: // slow subscriber: drop; it resyncs on reconnect
		}
	}
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request, a *Auth) error {
	rc := http.NewResponseController(w)
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	ch, cancel := s.hub.Subscribe(a.User.ID)
	defer cancel()
	fmt.Fprintf(w, "event: hello\ndata: {\"device_id\":%q}\n\n", a.Device.ID)
	rc.Flush()
	ping := time.NewTicker(25 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-r.Context().Done():
			return nil
		case b := <-ch:
			fmt.Fprintf(w, "data: %s\n\n", b)
		case <-ping.C:
			// Revoked devices are disconnected at the next ping.
			if _, err := s.db.Device(a.Device.ID); err != nil {
				return nil
			}
			fmt.Fprint(w, ": ping\n\n")
		}
		if err := rc.Flush(); err != nil {
			return nil
		}
	}
}
