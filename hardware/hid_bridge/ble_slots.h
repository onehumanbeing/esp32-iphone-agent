#pragma once
// Who may keep one of the board's peer slots, and which identity to advertise (ble_link.cpp). Pure, host-tested.
//
// A link keeps its slot by doing a job: a CLI session, the app (subscribed to its channels), or the phone's
// keyboard link (the BLE HID target). Anything else gets a grace period and is then dropped: a stranger's plain
// link, and macOS reconnecting to the board it bonded as a keyboard but never types on (#195: it took the second
// slot for good, so the board stopped advertising the CLI's identity).

enum AdvId { ADV_NONE, ADV_APP, ADV_CLI };

struct PeerLink {
  bool up;     // a central holds this slot
  bool cli;    // it came in on the CLI's random address
  bool job;    // CLI session, app subscription or HID target
  bool fresh;  // still within its grace (or plain while the pairing window is open: iOS shows its dialog)
};

inline bool ble_slot_idle(const PeerLink &p) { return p.up && !p.job && !p.fresh; }

// A link up on one identity advertises the other; with none, cliTurn says whose turn it is. Only links with a job
// decide the identity: an idle one on the app's address must not hide the CLI's while it waits to be dropped.
inline AdvId ble_wanted_adv(const PeerLink *p, int n, bool cliTurn) {
  int up = 0;
  bool app = false, cli = false;
  for (int i = 0; i < n; i++) {
    if (!p[i].up) continue;
    up++;
    if (p[i].cli) cli = true;
    else if (p[i].job) app = true;
  }
  if (up >= n || (app && cli)) return ADV_NONE;
  if (app) return ADV_CLI;  // the CLI still learns the app holds the board (owner app, busy)
  if (cli) return ADV_APP;  // the app can always come and take over
  return cliTurn ? ADV_CLI : ADV_APP;
}
