// TCP video link, see wifi_video.h. One app at a time on port 7201. The app sends text lines: "hello <token>"
// (or "hello <token> at <ts>": its decoder is still in step up to the AU with that timestamp), then "ka" every second and "resync" if its assembler lost its place,
// and "audio" if it wants the AirPlay audio too (older firmware ignores the line). The board sends records
// [u16 LE length][chunk]; a zero-length record answers hello and ka. TCP keeps chunks whole and in order,
// so there are no nacks: a send that stalls for SEND_TIMEOUT_MS drops the session and the app reconnects.
// On a home network (src/net/lan_lock.h) the app proves the token instead of sending it: "chal" is answered with a
// record "chal<nonce>", then "auth <hmac> [at <ts>]" opens the session, encrypted from there on, and makes the app's
// address the board's owner. Once there is an owner the plain "hello" is refused. "resume [at <ts>]" on an open
// session asks what "hello … at" asks, without the token.
#include "wifi_video.h"
#include "cli_link.h"
#include "logbuf.h"
#include "netcfg.h"
#include "src/net/lan_lock.h"
#if WV_TCP
#include <esp_random.h>
#include "freertos/message_buffer.h"
#include "lwip/sockets.h"
#include "src/airplay/airplay.h"
#include "src/video/gop.h"

const uint16_t PORT = 7201;
// Wi-Fi and BLE share one radio: a long BLE HID gesture (a flick, 7.3 s round trip) left Wi-Fi with no air time
// for ~4 s both ways, the 3 s "ka late" dropped the session, the GOP overflowed and the video froze (2026-11-27,
// 8 "ka late" in 7 h). A stall that short keeps the session; a gone app still closes its socket.
const uint32_t PEER_TIMEOUT_MS = 8000;
const int SEND_TIMEOUT_MS = 6000;
const int RECV_TIMEOUT_MS = 10000;  // longer than PEER_TIMEOUT_MS: recv timing out closes the session

static int listener = -1, client = -1;
static SemaphoreHandle_t lock;              // client + writes (a record goes out whole)
static volatile uint32_t lastSeen;
static volatile bool authed, resync, resumeAsked, audioWanted;
static volatile uint32_t resumeTs;
static char token[33];
static char nonce[LAN_NONCE_HEX + 1];  // this connection's challenge, until an `auth` uses it
static lan_ctr ctr;                    // an `auth` session: records encrypted (under lock)
static uint32_t winStart, winBytes;
static volatile uint32_t kbps, drops;
static volatile uint32_t records, maxWriteMs;  // for the `diag` lines
static const char *volatile inactiveWhy = "-";

static void count(size_t n) {
  uint32_t now = millis();
  winBytes += n;
  if (now - winStart >= 1000) {
    kbps = winBytes * 8 / (now - winStart);
    winBytes = 0;
    winStart = now;
  }
}

static bool writeAll(int fd, const uint8_t *p, size_t n) {
  while (n) {
    int k = send(fd, p, n, 0);
    if (k <= 0) return false;
    p += k;
    n -= k;
  }
  return true;
}

// Under lock. Closes the session if the record can't go out (stalled link or a gone app). Length and chunk go
// out in one send: two sends with TCP_NODELAY made a 2-byte segment per record, half the packets wasted.
static bool writeRecord(const uint8_t *p, size_t n) {
  static uint8_t rec[2 + VCHUNK_HDR + WV_PAYLOAD];
  if (client < 0 || n > sizeof rec - 2) return false;
  rec[0] = (uint8_t)n;
  rec[1] = (uint8_t)(n >> 8);
  if (n) memcpy(rec + 2, p, n);
  lan_ctr_crypt(&ctr, rec + 2, n);  // an `auth` session only; the keystream runs on across records
  uint32_t started = millis();
  bool ok = writeAll(client, rec, n + 2);
  uint32_t took = millis() - started;  // a send waits while the radio can't get the data out
  if (took > maxWriteMs) maxWriteMs = took;
  if (ok) {
    records++;
    count(n + 2);
    return true;
  }
  drops++;
  shutdown(client, SHUT_RDWR);  // the reader sees it and closes
  authed = false;
  return false;
}

// After "hello <token>" or "auth <hmac>": the session is on (under lock). `rest` is what follows: "" or " at <ts>".
static void open_session(const char *rest) {
  authed = true;
  resync = true;  // a new session starts from the IDR, or from just after the app's last AU
  resumeAsked = rest[0] != 0;
  resumeTs = resumeAsked ? strtoul(rest + 4, NULL, 10) : 0;
  writeRecord(NULL, 0);
}

static void serve(int fd, uint32_t peer) {
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  timeval tv = {SEND_TIMEOUT_MS / 1000, (SEND_TIMEOUT_MS % 1000) * 1000};
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
  // The app sends "ka" every second. A phone that left the hotspot sends no FIN, and with a still screen the
  // board has nothing to send either: without this the dead session blocked the next one forever (one at a time).
  timeval rx = {RECV_TIMEOUT_MS / 1000, (RECV_TIMEOUT_MS % 1000) * 1000};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rx, sizeof rx);
  xSemaphoreTake(lock, portMAX_DELAY);
  client = fd;
  authed = false;
  audioWanted = false;  // asked again on every connection; a resume hello on this one keeps it
  nonce[0] = 0;
  lan_ctr_stop(&ctr);
  xSemaphoreGive(lock);
  char who[16];
  lan_format_ip(peer, who);
  char line[96];
  size_t used = 0;
  for (;;) {
    int n = recv(fd, line + used, sizeof line - 1 - used, 0);
    if (n <= 0) break;
    lastSeen = millis();
    used += n;
    for (char *nl; (nl = (char *)memchr(line, '\n', used));) {
      *nl = 0;
      if (!strncmp(line, "hello ", 6)) {
        const char *rest = line + 6;
        size_t tl = strlen(token);
        if (strncmp(rest, token, tl) || (rest[tl] && strncmp(rest + tl, " at ", 4))) goto done;  // not our app
        if (lan_locked()) {  // on a home network with an owner the token never travels in the clear
          board_log("wv: plain hello from %s refused (LAN lock)", who);
          goto done;
        }
        xSemaphoreTake(lock, portMAX_DELAY);
        open_session(rest + tl);
        xSemaphoreGive(lock);
      } else if (!authed && !strcmp(line, "chal")) {
        uint8_t r[16];
        esp_fill_random(r, sizeof r);
        uint8_t rec[4 + LAN_NONCE_HEX];
        xSemaphoreTake(lock, portMAX_DELAY);
        lan_nonce(nonce, r);
        memcpy(rec, "chal", 4);
        memcpy(rec + 4, nonce, LAN_NONCE_HEX);
        writeRecord(rec, sizeof rec);
        xSemaphoreGive(lock);
      } else if (!authed && !strncmp(line, "auth ", 5)) {
        const char *mac = line + 5, *at = strchr(mac, ' ');
        char given[LAN_MAC_HEX + 1] = "", msg[8 + LAN_NONCE_HEX];
        size_t ml = at ? (size_t)(at - mac) : strlen(mac);
        if (ml == LAN_MAC_HEX) memcpy(given, mac, ml), given[ml] = 0;
        snprintf(msg, sizeof msg, "video %s", nonce);
        bool ok = nonce[0] && lan_mac_ok(token, msg, given) && (!at || !strncmp(at, " at ", 4));
        if (!ok) {
          board_log("wv: auth from %s refused", who);
          goto done;
        }
        xSemaphoreTake(lock, portMAX_DELAY);
        lan_ctr_start(&ctr, token, nonce);
        nonce[0] = 0;  // one use
        open_session(at ? at : "");
        xSemaphoreGive(lock);
        if (net_set_owner(peer)) board_log("wv: %s owns the board on this network", who);
      } else if (authed && !strncmp(line, "resume", 6) && (!line[6] || !strncmp(line + 6, " at ", 4))) {
        xSemaphoreTake(lock, portMAX_DELAY);  // "hello … at" on an open session, without the token (any session)
        open_session(line + 6);
        xSemaphoreGive(lock);
      } else if (authed && !strcmp(line, "ka")) {
        xSemaphoreTake(lock, portMAX_DELAY);
        writeRecord(NULL, 0);
        xSemaphoreGive(lock);
      } else if (authed && !strcmp(line, "resync")) {
        resync = true;
      } else if (authed && !strcmp(line, "audio")) {
        audioWanted = true;
        board_log("wv: app wants audio");
      }
      size_t rest = used - (nl + 1 - line);
      memmove(line, nl + 1, rest);
      used = rest;
    }
    if (used == sizeof line - 1) break;  // no newline in a full buffer: not our protocol
  }
done:
  xSemaphoreTake(lock, portMAX_DELAY);
  client = -1;
  authed = false;
  lan_ctr_stop(&ctr);
  xSemaphoreGive(lock);
  close(fd);
}

static void serverTask(void *) {
  for (;;) {
    sockaddr_in peer = {};
    socklen_t pl = sizeof peer;
    int fd = accept(listener, (sockaddr *)&peer, &pl);
    if (fd >= 0) serve(fd, peer.sin_addr.s_addr);  // one app at a time; a new one waits until this one is gone
  }
}

bool wv_begin() {
  uint8_t r[16];
  esp_fill_random(r, sizeof r);
  for (int i = 0; i < 16; i++) sprintf(token + 2 * i, "%02x", r[i]);
  lock = xSemaphoreCreateMutex();
  listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0) return false;
  int one = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(PORT);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(listener, (sockaddr *)&addr, sizeof addr) < 0 || listen(listener, 1) < 0) return false;
  return xTaskCreatePinnedToCore(serverTask, "wv_tcp", 4096, NULL, 3, NULL, 1) == pdPASS;
}

String wv_token() { return token; }

bool wv_active() {
  bool on = authed && client >= 0 && millis() - lastSeen < PEER_TIMEOUT_MS;
  static bool was;  // log why the session stopped counting: a late "ka" sends the app's video over BLE
  if (was && !on) {
    inactiveWhy = client < 0 ? "closed" : !authed ? "not authed" : "ka late";
    board_log("wv: inactive (%s, last ka %lu ms ago)", inactiveWhy, (unsigned long)(millis() - lastSeen));
  }
  if (!was && on) board_log("wv: active");
  was = on;
  return on;
}

bool wv_send(const uint8_t *chunk, size_t n) {
  if (n > VCHUNK_HDR + WV_PAYLOAD || !wv_active()) return false;
  xSemaphoreTake(lock, portMAX_DELAY);
  bool ok = writeRecord(chunk, n);
  xSemaphoreGive(lock);
  return ok;
}

bool wv_take_resume(uint32_t *ts) {
  xSemaphoreTake(lock, portMAX_DELAY);
  bool asked = resumeAsked;
  *ts = resumeTs;
  resumeAsked = false;
  xSemaphoreGive(lock);
  return asked;
}

bool wv_take_resync() {
  if (!resync) return false;
  resync = false;
  return true;
}

// ---- audio: the mirror task queues frames, audioTask writes them as records to the app (TCP 7201) and to a CLI
// that asked for them (cli_link, Wi-Fi only), each with its own seq and segment start: a stalled send must not
// hold up AirPlay ----

const size_t AUDIO_QUEUE = 16 * 1024;  // about 1 s of AAC-ELD
static MessageBufferHandle_t audioQ;
static volatile uint32_t audioDrops;

struct AudioDest {
  const char *name;
  uint16_t seq;
  bool started;  // it saw this segment's VF_START
};

// One queued frame ([event][u32 ms][u32 ts][frame]) as a record for d; false if it isn't one for d.
static size_t audioRecord(AudioDest &d, const uint8_t *q, size_t n, uint8_t *rec) {
  int event = q[0];
  if (event == AIRPLAY_AUDIO_FRAME && !d.started) event = AIRPLAY_AUDIO_START;  // it joined mid-segment
  if (event == AIRPLAY_AUDIO_END && !d.started) return 0;
  rec[0] = (uint8_t)d.seq;
  rec[1] = (uint8_t)(d.seq >> 8);
  rec[2] = WV_AUDIO | (event == AIRPLAY_AUDIO_START ? VF_START : event == AIRPLAY_AUDIO_END ? VF_END : 0);
  size_t len = VCHUNK_HDR;
  if (event != AIRPLAY_AUDIO_END) {
    memcpy(rec + len, q + 1, n - 1);
    len += n - 1;
  }
  if (event == AIRPLAY_AUDIO_START) board_log("wv: audio segment to the %s (seq %u)", d.name, (unsigned)d.seq);
  if (event == AIRPLAY_AUDIO_END)
    board_log("wv: audio segment to the %s ended (seq %u, %lu dropped so far)", d.name, (unsigned)d.seq, (unsigned long)audioDrops);
  d.seq++;
  d.started = event != AIRPLAY_AUDIO_END;
  return len;
}

static void audioTask(void *) {
  static uint8_t q[1 + 8 + WV_PAYLOAD], rec[VCHUNK_HDR + 8 + WV_PAYLOAD];
  static AudioDest app = {"app"}, cli = {"computer"};
  for (;;) {
    size_t n = xMessageBufferReceive(audioQ, q, sizeof q, portMAX_DELAY);
    if (!n) continue;
    bool toApp = wv_active() && audioWanted, toCli = cli_audio_wanted();
    if (!toApp) app.started = false;
    if (!toCli) cli.started = false;
    if (!toApp && !toCli) { audioDrops++; continue; }
    size_t len;
    if (toApp && (len = audioRecord(app, q, n, rec))) {
      xSemaphoreTake(lock, portMAX_DELAY);
      if (!writeRecord(rec, len)) audioDrops++;
      xSemaphoreGive(lock);
    }
    if (toCli && (len = audioRecord(cli, q, n, rec)) && !cli_send_audio(rec, len)) audioDrops++;
  }
}

// Started with the first audio, so a board that never hears any keeps the internal RAM.
static bool audioStart() {
  static bool tried, ok;
  if (tried) return ok;
  tried = true;
  static StaticMessageBuffer_t ctl;
  uint8_t *store = (uint8_t *)heap_caps_malloc(AUDIO_QUEUE + 1, MALLOC_CAP_SPIRAM);
  audioQ = store ? xMessageBufferCreateStatic(AUDIO_QUEUE, store, &ctl) : NULL;
  ok = audioQ && xTaskCreatePinnedToCore(audioTask, "wv_audio", 3072, NULL, 2, NULL, 1) == pdPASS;
  if (!ok) board_log("wv: audio task failed to start");
  return ok;
}

void wv_audio(int event, const uint8_t *frame, size_t len, uint32_t ts) {
  if (!(audioWanted && wv_active()) && !cli_audio_wanted()) return;
  if (len > WV_PAYLOAD - 8 || !audioStart()) { audioDrops++; return; }  // a record must fit one TCP record
  uint8_t q[1 + 8 + WV_PAYLOAD];
  uint32_t ms = millis();
  q[0] = (uint8_t)event;
  for (int i = 0; i < 4; i++) q[1 + i] = (uint8_t)(ms >> (8 * i)), q[5 + i] = (uint8_t)(ts >> (8 * i));
  size_t n = 1 + 8;
  if (event != AIRPLAY_AUDIO_END) {
    memcpy(q + n, frame, len);
    n += len;
  }
  if (xMessageBufferSend(audioQ, q, n, 0) != n) audioDrops++;
}

uint32_t wv_audio_drops() { return audioDrops; }

uint32_t wv_kbps() { return millis() - winStart < 3000 ? kbps : 0; }
uint32_t wv_nacks() { return 0; }
uint32_t wv_drops() { return drops; }
void wv_diag(uint32_t *r, uint32_t *maxMs) {
  *r = records;
  *maxMs = maxWriteMs;
  maxWriteMs = 0;
}
const char *wv_why() { return inactiveWhy; }

#endif  // WV_TCP
