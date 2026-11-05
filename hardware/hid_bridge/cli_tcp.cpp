// CLI link over Wi-Fi, see cli_tcp.h. Reads run on this file's task and hand each frame to cli_on_frame(), as
// NimBLE's host task does for cli_in writes; sends come from cli_link.cpp (BLE TX and video tasks), under a lock.
#include "cli_tcp.h"
#include <esp_heap_caps.h>
#include "lwip/sockets.h"
#include "cli_link.h"
#include "logbuf.h"

const uint16_t PORT = 7202;
const int SEND_TIMEOUT_MS = 2000;
const int IDLE_TIMEOUT_MS = 6000;  // the CLI sends a keepalive every 2 s; a computer gone off Wi-Fi sends no FIN
const size_t FRAME_MAX = 600;      // largest frame from the computer (cli_link.cpp's TEXT_CAP + seal)

static int listener = -1;
static volatile int client = -1;
static SemaphoreHandle_t lock;  // client + writes (a record goes out whole)
static uint8_t *rx, *tx;        // PSRAM
static uint32_t winStart, winBytes;
static volatile uint32_t kbps;

static bool readAll(int fd, uint8_t *p, size_t n) {
  while (n) {
    int k = recv(fd, p, n, 0);
    if (k <= 0) return false;
    p += k;
    n -= k;
  }
  return true;
}

static void serve(int fd) {
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  timeval stx = {SEND_TIMEOUT_MS / 1000, (SEND_TIMEOUT_MS % 1000) * 1000};
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stx, sizeof stx);
  timeval srx = {IDLE_TIMEOUT_MS / 1000, (IDLE_TIMEOUT_MS % 1000) * 1000};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &srx, sizeof srx);
  xSemaphoreTake(lock, portMAX_DELAY);
  client = fd;
  xSemaphoreGive(lock);
  board_log("cli: wifi link up");
  for (;;) {
    uint8_t hdr[2];
    if (!readAll(fd, hdr, 2)) break;
    size_t n = hdr[0] | hdr[1] << 8;
    if (n > FRAME_MAX || (n && !readAll(fd, rx, n))) break;
    if (n) cli_on_frame(CLI_TCP_SLOT, rx, n);
  }
  xSemaphoreTake(lock, portMAX_DELAY);
  client = -1;
  xSemaphoreGive(lock);
  cli_reset(CLI_TCP_SLOT);
  close(fd);
  board_log("cli: wifi link down");
}

static void serverTask(void *) {
  for (;;) {
    int fd = accept(listener, NULL, NULL);
    if (fd >= 0) serve(fd);  // one computer at a time; a new one waits until this one is gone
  }
}

bool cli_tcp_begin() {
  lock = xSemaphoreCreateMutex();
  rx = (uint8_t *)heap_caps_malloc(FRAME_MAX + 2 + CLI_TCP_MTU, MALLOC_CAP_SPIRAM);
  if (!rx) rx = (uint8_t *)malloc(FRAME_MAX + 2 + CLI_TCP_MTU);
  if (!rx) return false;
  tx = rx + FRAME_MAX;
  listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0) return false;
  int one = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(PORT);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(listener, (sockaddr *)&addr, sizeof addr) < 0 || listen(listener, 1) < 0) return false;
  return xTaskCreatePinnedToCore(serverTask, "cli_tcp", 4096, NULL, 3, NULL, 1) == pdPASS;
}

bool cli_tcp_up() { return client >= 0; }

bool cli_tcp_send(const uint8_t *p, size_t n, uint32_t) {
  if (n > CLI_TCP_MTU) return false;
  xSemaphoreTake(lock, portMAX_DELAY);
  bool ok = client >= 0;
  if (ok) {
    tx[0] = (uint8_t)n;  // length and frame in one send: one segment per record
    tx[1] = (uint8_t)(n >> 8);
    memcpy(tx + 2, p, n);
    for (size_t off = 0; ok && off < n + 2;) {
      int k = send(client, tx + off, n + 2 - off, 0);
      ok = k > 0;
      off += ok ? k : 0;
    }
    if (!ok) shutdown(client, SHUT_RDWR);  // stalled (SO_SNDTIMEO) or gone: the reader sees it and closes
  }
  xSemaphoreGive(lock);
  if (ok) {
    uint32_t now = millis();
    winBytes += n + 2;
    if (now - winStart >= 1000) {
      kbps = winBytes * 8 / (now - winStart);
      winBytes = 0;
      winStart = now;
    }
  }
  return ok;
}

void cli_tcp_drop() {
  xSemaphoreTake(lock, portMAX_DELAY);
  if (client >= 0) shutdown(client, SHUT_RDWR);
  xSemaphoreGive(lock);
}

uint32_t cli_tcp_kbps() { return millis() - winStart > 2000 ? 0 : kbps; }
