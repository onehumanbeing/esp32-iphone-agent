// CLI link, see cli_link.h.
#include "cli_link.h"
#include <Preferences.h>
#include <esp_heap_caps.h>
#include <esp_mac.h>
#include <esp_random.h>
#include "ble_link.h"
#include "src/cli/cli_proto.h"

const int MAX_CLIENTS = 4;
const int SLOTS = 2;                       // ble_link's MAX_PEERS
const uint32_t VIDEO_TIMEOUT_MS = 1500;    // as for the app's video

struct PairedClient {
  uint8_t id[CLI_ID_LEN], key[CLI_KEY_LEN];
};
struct Session {
  volatile bool welcomed, authed;
  int client;
  uint8_t c2b[16], b2c[16];
  uint32_t rx, txCtrl, txVideo;
};

static Preferences prefs;
static PairedClient clients[MAX_CLIENTS];
static int clientCount, nextClient;
static Session sessions[SLOTS];
static uint8_t boardId[6];
// Frame buffers in PSRAM (~2 KB): one for frames from the computer (host task), one per sending task.
static uint8_t *rxText, *ctrlBuf, *ctrlOut, *videoOut;
const size_t TEXT_CAP = 520, OUT_CAP = 520 + CLI_OVERHEAD;

extern "C" void cli_random(uint8_t *p, size_t n) { esp_fill_random(p, n); }

static void saveClients() {
  prefs.begin("cli", false);
  prefs.putBytes("c", clients, sizeof clients);
  prefs.putUChar("n", clientCount);
  prefs.putUChar("next", nextClient);
  prefs.end();
}

void cli_begin() {
  uint8_t *p = (uint8_t *)heap_caps_malloc(TEXT_CAP * 2 + OUT_CAP * 2, MALLOC_CAP_SPIRAM);
  if (!p) p = (uint8_t *)malloc(TEXT_CAP * 2 + OUT_CAP * 2);
  rxText = p;
  ctrlBuf = p + TEXT_CAP;
  ctrlOut = p + TEXT_CAP * 2;
  videoOut = p + TEXT_CAP * 2 + OUT_CAP;
  esp_read_mac(boardId, ESP_MAC_BT);
  prefs.begin("cli", true);
  clientCount = prefs.getUChar("n", 0);
  nextClient = prefs.getUChar("next", 0);
  if (prefs.getBytes("c", clients, sizeof clients) != sizeof clients || clientCount > MAX_CLIENTS) clientCount = nextClient = 0;
  prefs.end();
}

void cli_forget_all() {
  memset(clients, 0, sizeof clients);
  clientCount = nextClient = 0;
  saveClients();
  for (int i = 0; i < SLOTS; i++)
    if (sessions[i].welcomed) ble_cli_drop(i);
}

static int findClient(const uint8_t *id) {
  for (int i = 0; i < clientCount; i++)
    if (!memcmp(clients[i].id, id, CLI_ID_LEN)) return i;
  return -1;
}

static void plain(int slot, uint8_t type, const uint8_t *p, size_t n) {
  uint8_t out[80];
  out[0] = type;
  memcpy(out + 1, p, n);
  ble_cli_notify(slot, out, n + 1, false, 1000);
}

static void error(int slot, const char *why) { plain(slot, CLI_ERROR, (const uint8_t *)why, strlen(why)); }

static void pair(int slot, const uint8_t *p, size_t n) {
  if (n != 32 + CLI_ID_LEN) return error(slot, "bad pair request");
  if (!ble_pair_window_open())
    return error(slot, "pairing window closed: unplug and replug the board, then pair within 3 minutes");
  uint8_t priv[32], pub[32], key[CLI_KEY_LEN];
  esp_fill_random(priv, sizeof priv);
  bool ok = cli_pair(priv, p, pub, key);
  memset(priv, 0, sizeof priv);
  if (!ok) return error(slot, "bad key");
  const uint8_t *id = p + 32;
  int i = findClient(id);
  if (i < 0) {
    i = clientCount < MAX_CLIENTS ? clientCount++ : nextClient;  // full: replace the oldest
    nextClient = (i + 1) % MAX_CLIENTS;
  }
  memcpy(clients[i].id, id, CLI_ID_LEN);
  memcpy(clients[i].key, key, CLI_KEY_LEN);
  saveClients();
  uint8_t out[32 + 6 + CLI_MAC_LEN];
  memcpy(out, pub, 32);
  memcpy(out + 32, boardId, 6);
  cli_mac(key, "paired", id, CLI_ID_LEN, NULL, 0, out + 38);
  Serial.println("cli: paired a new client");
  plain(slot, CLI_PAIRED, out, sizeof out);
}

static void hello(int slot, const uint8_t *p, size_t n) {
  if (n != CLI_ID_LEN + CLI_NONCE_LEN) return error(slot, "bad hello");
  int c = findClient(p);
  if (c < 0) return error(slot, "not paired");
  Session &s = sessions[slot];
  uint8_t bn[CLI_NONCE_LEN], out[CLI_NONCE_LEN + 6 + CLI_MAC_LEN];
  esp_fill_random(bn, sizeof bn);
  s.authed = false;
  if (!cli_session(clients[c].key, p + CLI_ID_LEN, bn, s.c2b, s.b2c)) return error(slot, "session failed");
  s.client = c;
  s.rx = s.txCtrl = s.txVideo = 0;
  s.welcomed = true;
  memcpy(out, bn, CLI_NONCE_LEN);
  memcpy(out + CLI_NONCE_LEN, boardId, 6);
  cli_mac(clients[c].key, "hello", p + CLI_ID_LEN, CLI_NONCE_LEN, bn, CLI_NONCE_LEN, out + CLI_NONCE_LEN + 6);
  plain(slot, CLI_WELCOME, out, sizeof out);
}

static void data(int slot, const uint8_t *p, size_t n) {
  Session &s = sessions[slot];
  uint8_t *text = rxText;
  uint32_t ctr;
  if (!s.welcomed || !text || n > TEXT_CAP + CLI_OVERHEAD) return;
  int len = cli_open(s.c2b, 'C', p, n, &ctr, text);
  if (len < 0) return;  // forged or for another session: ignore
  if (ctr != s.rx + 1) { ble_cli_drop(slot); return; }  // a replay, or a lost frame: start over
  s.rx = ctr;
  if (!s.authed) {
    if (cli_slot() >= 0) { ble_cli_drop(slot); return; }  // one computer at a time
    s.authed = true;
    Serial.println("cli: session up");
  }
  if (len > 1 && text[0] == 'c') ble_cli_push_cmd((const char *)text + 1, len - 1);
}

void cli_on_frame(int slot, const uint8_t *p, size_t n) {
  if (slot < 0 || slot >= SLOTS || !n) return;
  switch (p[0]) {
    case CLI_PAIR: return pair(slot, p + 1, n - 1);
    case CLI_HELLO: return hello(slot, p + 1, n - 1);
    case CLI_DATA: return data(slot, p, n);
  }
}

void cli_reset(int slot) {
  if (slot < 0 || slot >= SLOTS) return;
  sessions[slot].authed = sessions[slot].welcomed = false;
}

bool cli_authed(int slot) { return slot >= 0 && slot < SLOTS && sessions[slot].authed; }

int cli_slot() {
  for (int i = 0; i < SLOTS; i++)
    if (sessions[i].authed) return i;
  return -1;
}

bool cli_send_ctrl(char kind, const char *text, size_t n, uint32_t timeout_ms) {
  int slot = cli_slot();
  if (slot < 0) return false;
  Session &s = sessions[slot];
  uint8_t *buf = ctrlBuf, *out = ctrlOut;
  size_t room = ble_cli_mtu(slot) - 3 - CLI_OVERHEAD - 1;
  if (n > room) n = room;
  buf[0] = (uint8_t)kind;
  memcpy(buf + 1, text, n);
  size_t len = cli_seal(s.b2c, CLI_DATA, 'B', s.txCtrl + 1, buf, n + 1, out);
  if (!len || !ble_cli_notify(slot, out, len, false, timeout_ms)) {
    ble_cli_drop(slot);  // the CLI would see a counter gap anyway
    return false;
  }
  s.txCtrl++;
  return true;
}

size_t cli_video_room() {
  int slot = cli_slot();
  if (slot < 0 || !ble_cli_subscribed(slot)) return 0;
  return ble_cli_mtu(slot) - 3 - CLI_OVERHEAD - 3;  // ATT header, the seal, the chunk's own header (VCHUNK_HDR)
}

bool cli_send_video(const uint8_t *chunk, size_t n) {
  int slot = cli_slot();
  if (slot < 0) return false;
  Session &s = sessions[slot];
  uint8_t *out = videoOut;
  if (n > OUT_CAP - CLI_OVERHEAD) return false;
  size_t len = cli_seal(s.b2c, CLI_VIDEO, 'V', s.txVideo + 1, chunk, n, out);
  s.txVideo++;  // a chunk that fails is a gap the CLI handles like a seq gap
  return len && ble_cli_notify(slot, out, len, true, VIDEO_TIMEOUT_MS);
}
