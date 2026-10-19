// TCP video link, see wifi_video.h. One app at a time on port 7201. The app sends text lines: "hello <token>",
// then "ka" every second and "resync" if its assembler lost its place. The board sends records
// [u16 LE length][chunk]; a zero-length record answers hello and ka. TCP keeps chunks whole and in order,
// so there are no nacks: a send that stalls for SEND_TIMEOUT_MS drops the session and the app reconnects.
#include "wifi_video.h"
#if WV_TCP
#include <esp_random.h>
#include "lwip/sockets.h"
#include "src/video/gop.h"

const uint16_t PORT = 7201;
const uint32_t PEER_TIMEOUT_MS = 3000;
const int SEND_TIMEOUT_MS = 2000;
const int RECV_TIMEOUT_MS = 5000;

static int listener = -1, client = -1;
static SemaphoreHandle_t lock;              // client + writes (a record goes out whole)
static volatile uint32_t lastSeen;
static volatile bool authed, resync;
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
        if (strcmp(line + 6, token)) goto done;  // wrong token: not our app
        xSemaphoreTake(lock, portMAX_DELAY);
        authed = true;
        resync = true;  // a new session starts from the IDR
        writeRecord(NULL, 0);
        xSemaphoreGive(lock);
      } else if (authed && !strcmp(line, "ka")) {
        xSemaphoreTake(lock, portMAX_DELAY);
        writeRecord(NULL, 0);
        xSemaphoreGive(lock);
      } else if (authed && !strcmp(line, "resync")) {
        resync = true;
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

bool wv_active() { return authed && client >= 0 && millis() - lastSeen < PEER_TIMEOUT_MS; }

bool wv_send(const uint8_t *chunk, size_t n) {
  if (n > VCHUNK_HDR + WV_PAYLOAD || !wv_active()) return false;
  xSemaphoreTake(lock, portMAX_DELAY);
  bool ok = writeRecord(chunk, n);
  xSemaphoreGive(lock);
  return ok;
}

bool wv_take_resync() {
  if (!resync) return false;
  resync = false;
  return true;
}

uint32_t wv_kbps() { return millis() - winStart < 3000 ? kbps : 0; }
uint32_t wv_nacks() { return 0; }
uint32_t wv_drops() { return drops; }

#endif  // WV_TCP
