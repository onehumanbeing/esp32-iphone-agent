package daemon

import (
	"testing"
	"time"
)

// noteApp takes s.mu while Server.conn / devices / closeAll hold s.mu and then
// take c.mu, so onStatus must release c.mu before invoking the app callback.
func TestOnStatusNotifiesAfterReleasingConnMu(t *testing.T) {
	c := newConn("0123456789ab", "test", "")

	called := false
	c.onApp = func() {
		called = true
		acquired := make(chan struct{})
		go func() {
			c.mu.Lock()
			c.mu.Unlock()
			close(acquired)
		}()
		select {
		case <-acquired:
		case <-time.After(3 * time.Second):
			// Return so onStatus can release c.mu; blocking here would hang the test.
			t.Error("app callback ran while c.mu was still held")
		}
	}

	c.onStatus([]byte(`{"owner":"app","busy":1}`))
	if !called {
		t.Fatal("app callback was not invoked for owner: app")
	}
}
