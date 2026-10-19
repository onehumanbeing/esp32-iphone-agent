// UDP video link, see wifi_video.h. Control datagrams from the app (text): "hello <token>", "ka",
// "nack <from> <to>" (inclusive seq range) and "resync". hello and ka are answered with "ok".
#include "wifi_video.h"
#if !WV_TCP
#include <esp_heap_caps.h>
#include <esp_random.h>
#include "lwip/sockets.h"
#include "src/video/gop.h"

const uint16_t PORT = 7200;
const uint32_t PEER_TIMEOUT_MS = 3000;
const int SLOTS = 1024;                     // resend window: ~1.4 MB in PSRAM, seconds of video
const size_t SLOT_CAP = VCHUNK_HDR + WV_PAYLOAD;
const int MAX_NACK = 256;                   // chunks per request

struct Slot {
  uint16_t seq, len;
  uint8_t data[SLOT_CAP];
};

static int sock = -1;
static Slot *slots;
static SemaphoreHandle_t lock;              // peer + slots
static sockaddr_in peer;
static volatile uint32_t lastSeen;
static volatile bool havePeer, resync;
static char token[33];
static uint32_t winStart, winBytes;
static volatile uint32_t kbps, nacks, drops;

static void count(size_t n) {
  uint32_t now = millis();
  winBytes += n;
  if (now - winStart >= 1000) {
    kbps = winBytes * 8 / (now - winStart);
    winBytes = 0;
    winStart = now;
  }
}

// The Wi-Fi driver's queue can be full while the air is busy: wait for room (backpressure, up to 200 ms),
// then drop the datagram. Dropping at once only made the app ask for it again on the same busy air. The app
// asks for it again (nack) or for a fresh IDR, and stops its keep-alives if the link is gone.
static bool sendRaw(const uint8_t *p, size_t n, const sockaddr_in &to) {
  for (uint32_t start = millis(); millis() - start < 200;) {
    if (sendto(sock, p, n, 0, (const sockaddr *)&to, sizeof to) == (int)n) {
      count(n);
      return true;
    }
    if (errno != ENOMEM && errno != EAGAIN) break;
    vTaskDelay(1);
  }
  drops++;
  return false;
}

static void resend(uint16_t from, uint16_t to) {
  int n = (uint16_t)(to - from) + 1;
  if (n > MAX_NACK) n = MAX_NACK;
  nacks++;
  for (int i = 0; i < n; i++) {
    uint16_t s = from + i;
    static uint8_t buf[SLOT_CAP];
    xSemaphoreTake(lock, portMAX_DELAY);
    Slot &slot = slots[s % SLOTS];
    size_t len = slot.seq == s ? slot.len : 0;
    if (len) memcpy(buf, slot.data, len);
    sockaddr_in to = peer;
    xSemaphoreGive(lock);
    if (!len) continue;  // fell out of the window: the app's gap timeout asks for a resync
    if (!sendRaw(buf, len, to)) break;  // link congested: don't hold up keep-alives; the app nacks again
  }
}

static void ctrlTask(void *) {
  char msg[96];
  for (;;) {
    sockaddr_in from;
    socklen_t fl = sizeof from;
    int n = recvfrom(sock, msg, sizeof msg - 1, 0, (sockaddr *)&from, &fl);
    if (n <= 0) continue;
    msg[n] = 0;
    xSemaphoreTake(lock, portMAX_DELAY);
    bool known = havePeer && from.sin_addr.s_addr == peer.sin_addr.s_addr && from.sin_port == peer.sin_port;
    xSemaphoreGive(lock);
    if (!strncmp(msg, "hello ", 6)) {
      if (strcmp(msg + 6, token)) continue;  // wrong token: not our app
      xSemaphoreTake(lock, portMAX_DELAY);
      peer = from;
      havePeer = true;
      xSemaphoreGive(lock);
      lastSeen = millis();
      resync = true;  // a new session starts from the IDR
      sendto(sock, "ok", 2, 0, (sockaddr *)&from, sizeof from);
      continue;
    }
    if (!known) continue;
    lastSeen = millis();
    if (!strcmp(msg, "ka")) sendto(sock, "ok", 2, 0, (sockaddr *)&from, sizeof from);  // the app's liveness check
    unsigned a, b;
    if (sscanf(msg, "nack %u %u", &a, &b) == 2) resend((uint16_t)a, (uint16_t)b);
    else if (!strcmp(msg, "resync")) resync = true;
  }
}

bool wv_begin() {
  slots = (Slot *)heap_caps_calloc(SLOTS, sizeof(Slot), MALLOC_CAP_SPIRAM);
  if (!slots) return false;
  for (int i = 0; i < SLOTS; i++) slots[i].seq = (uint16_t)(i + 1);  // never matches before it is written
  uint8_t r[16];
  esp_fill_random(r, sizeof r);
  for (int i = 0; i < 16; i++) sprintf(token + 2 * i, "%02x", r[i]);
  lock = xSemaphoreCreateMutex();
  sock = socket(AF_INET, SOCK_DGRAM, 0);
  if (sock < 0) return false;
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(PORT);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(sock, (sockaddr *)&addr, sizeof addr) < 0) return false;
  return xTaskCreatePinnedToCore(ctrlTask, "wv_ctrl", 4096, NULL, 3, NULL, 1) == pdPASS;
}

String wv_token() { return token; }

bool wv_active() { return havePeer && millis() - lastSeen < PEER_TIMEOUT_MS; }

bool wv_send(const uint8_t *chunk, size_t n) {
  if (n > SLOT_CAP || !wv_active()) return false;
  uint16_t seq = chunk[0] | chunk[1] << 8;
  xSemaphoreTake(lock, portMAX_DELAY);
  Slot &slot = slots[seq % SLOTS];
  slot.seq = seq;
  slot.len = n;
  memcpy(slot.data, chunk, n);
  sockaddr_in to = peer;
  xSemaphoreGive(lock);
  sendRaw(chunk, n, to);
  return true;  // kept for resends even if the driver dropped it
}

bool wv_take_resync() {
  if (!resync) return false;
  resync = false;
  return true;
}

uint32_t wv_kbps() { return millis() - winStart < 3000 ? kbps : 0; }
uint32_t wv_nacks() { return nacks; }
uint32_t wv_drops() { return drops; }

#endif  // !WV_TCP
