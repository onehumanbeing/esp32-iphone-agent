// TCP video link, see wifi_video.h. One app at a time on port 7201. The app sends text lines: "hello <token>"
// (or "hello <token> at <ts>": its decoder is still in step up to the AU with that timestamp), then "ka" every second and "resync" if its assembler lost its place,
// and "audio" if it wants the AirPlay audio too (older firmware ignores the line). The board sends records
// [u16 LE length][chunk]; a zero-length record answers hello and ka. TCP keeps chunks whole and in order,
// so there are no nacks: a send that stalls for SEND_TIMEOUT_MS drops the session and the app reconnects.
#include "wifi_video.h"
#include "logbuf.h"
#if WV_TCP
#include <esp_random.h>
#include "freertos/message_buffer.h"
#include "lwip/sockets.h"
#include "src/airplay/airplay.h"
#include "src/video/gop.h"

const uint16_t PORT = 7201;
const uint32_t PEER_TIMEOUT_MS = 3000;
const int SEND_TIMEOUT_MS = 2000;
const int RECV_TIMEOUT_MS = 5000;

static int listener = -1, client = -1;
static SemaphoreHandle_t lock;              // client + writes (a record goes out whole)
static volatile uint32_t lastSeen;
static volatile bool authed, resync, resumeAsked, audioWanted;
static volatile uint32_t resumeTs;
static char token[33];
static uint32_t winStart, winBytes;
static volatile uint32_t kbps, drops;

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
  if (writeAll(client, rec, n + 2)) {
    count(n + 2);
    return true;
  }
  drops++;
  shutdown(client, SHUT_RDWR);  // the reader sees it and closes
  authed = false;
  return false;
}

static void serve(int fd) {
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
  xSemaphoreGive(lock);
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
        xSemaphoreTake(lock, portMAX_DELAY);
        authed = true;
        resync = true;  // a new session starts from the IDR, or from just after the app's last AU
        resumeAsked = rest[tl] != 0;
        resumeTs = resumeAsked ? strtoul(rest + tl + 4, NULL, 10) : 0;
        writeRecord(NULL, 0);
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
  xSemaphoreGive(lock);
  close(fd);
}

static void serverTask(void *) {
  for (;;) {
    int fd = accept(listener, NULL, NULL);
    if (fd >= 0) serve(fd);  // one app at a time; a new one waits until this one is gone
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
  if (was && !on) board_log("wv: inactive (%s, last ka %lu ms ago)", client < 0 ? "closed" : !authed ? "not authed" : "ka late",
                            (unsigned long)(millis() - lastSeen));
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

// ---- audio: the mirror task queues records, audioTask writes them (a stalled send must not hold up AirPlay) ----

const size_t AUDIO_QUEUE = 16 * 1024;  // about 1 s of AAC-ELD
static MessageBufferHandle_t audioQ;
static volatile uint32_t audioDrops;

static void audioTask(void *) {
  static uint8_t rec[VCHUNK_HDR + WV_PAYLOAD];
  for (;;) {
    size_t n = xMessageBufferReceive(audioQ, rec, sizeof rec, portMAX_DELAY);
    if (!n || !wv_active() || !audioWanted) { if (n) audioDrops++; continue; }
    xSemaphoreTake(lock, portMAX_DELAY);
    if (!writeRecord(rec, n)) audioDrops++;
    xSemaphoreGive(lock);
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
  static uint16_t seq;
  static bool started;  // the app saw this segment's VF_START
  if (!audioWanted || !wv_active()) { started = false; return; }
  if (event == AIRPLAY_AUDIO_FRAME && !started) event = AIRPLAY_AUDIO_START;  // the app joined mid-segment
  if (event == AIRPLAY_AUDIO_END && !started) return;
  if (len > WV_PAYLOAD - 8 || !audioStart()) { audioDrops++; return; }
  uint8_t rec[VCHUNK_HDR + WV_PAYLOAD];
  uint32_t ms = millis();
  rec[0] = (uint8_t)seq;
  rec[1] = (uint8_t)(seq >> 8);
  rec[2] = WV_AUDIO | (event == AIRPLAY_AUDIO_START ? VF_START : event == AIRPLAY_AUDIO_END ? VF_END : 0);
  size_t n = VCHUNK_HDR;
  if (event != AIRPLAY_AUDIO_END) {
    for (int i = 0; i < 4; i++) rec[n + i] = (uint8_t)(ms >> (8 * i)), rec[n + 4 + i] = (uint8_t)(ts >> (8 * i));
    memcpy(rec + n + 8, frame, len);
    n += 8 + len;
  }
  if (xMessageBufferSend(audioQ, rec, n, 0) != n) { audioDrops++; return; }
  if (event == AIRPLAY_AUDIO_START) board_log("wv: audio segment to the app (seq %u)", (unsigned)seq);
  if (event == AIRPLAY_AUDIO_END) board_log("wv: audio segment ended (seq %u, %lu dropped so far)", (unsigned)seq, (unsigned long)audioDrops);
  seq++;
  started = event != AIRPLAY_AUDIO_END;
}

uint32_t wv_audio_drops() { return audioDrops; }

uint32_t wv_kbps() { return millis() - winStart < 3000 ? kbps : 0; }
uint32_t wv_nacks() { return 0; }
uint32_t wv_drops() { return drops; }

#endif  // WV_TCP
