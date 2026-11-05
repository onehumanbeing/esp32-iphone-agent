// A simulated board for the esp32agent CLI: the real cli_link.cpp (pairing, sessions, sealed frames) behind a pipe
// instead of BLE, with an H.264 file as the mirrored screen. Usage (the CLI's sim transport runs it):
//   cli_sim [screen.h264]      stdin/stdout: records [u16 LE length][frame]; length 0 = the link dropped
// Env: CLI_SIM_NVS=path (pairings survive restarts), CLI_SIM_WINDOW=0 (pairing window closed), CLI_SIM_FROZEN=1.
// Commands are logged to stderr as "cmd: <line>" so tests can check what the CLI sent.
#include <poll.h>
#include <stdlib.h>
#include <sys/time.h>
#include <unistd.h>
#include <vector>
#include "Arduino.h"
#include "Preferences.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "ble_link.h"
#include "cli_link.h"
#include "src/video/gop.h"
#include "src/log/logring.h"
#include <stdarg.h>

SerialStub Serial;
static uint64_t t0;
static uint64_t nowMs() {
  timeval tv;
  gettimeofday(&tv, NULL);
  return (uint64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}
uint32_t millis() { return (uint32_t)(nowMs() - t0); }
void esp_fill_random(void *p, size_t n) { arc4random_buf(p, n); }
int esp_read_mac(uint8_t *mac, int) {
  static const uint8_t m[6] = {0x24, 0x6f, 0x28, 0xaa, 0x6a, 0xd5};
  memcpy(mac, m, 6);
  return 0;
}

// NVS: one file of key=hex lines.
static std::string nvs[8][2];
static int nvsCount;
static std::string *slotFor(const char *key) {
  for (int i = 0; i < nvsCount; i++)
    if (nvs[i][0] == key) return &nvs[i][1];
  nvs[nvsCount][0] = key;
  return &nvs[nvsCount++][1];
}
static void nvsSave() {
  const char *path = getenv("CLI_SIM_NVS");
  FILE *f = path ? fopen(path, "w") : NULL;
  if (!f) return;
  for (int i = 0; i < nvsCount; i++) {
    fprintf(f, "%s=", nvs[i][0].c_str());
    for (unsigned char ch : nvs[i][1]) fprintf(f, "%02x", ch);
    fprintf(f, "\n");
  }
  fclose(f);
}
static void nvsLoad() {
  const char *path = getenv("CLI_SIM_NVS");
  FILE *f = path ? fopen(path, "r") : NULL;
  char line[512];
  while (f && fgets(line, sizeof line, f)) {
    char *eq = strchr(line, '=');
    if (!eq) continue;
    *eq = 0;
    std::string v;
    for (char *h = eq + 1; h[0] && h[1] && h[0] != '\n'; h += 2) {
      unsigned x;
      sscanf(h, "%2x", &x);
      v.push_back((char)x);
    }
    *slotFor(line) = v;
  }
  if (f) fclose(f);
}
bool Preferences::begin(const char *, bool) { return true; }
size_t Preferences::putBytes(const char *k, const void *p, size_t n) { *slotFor(k) = std::string((const char *)p, n); nvsSave(); return n; }
size_t Preferences::getBytes(const char *k, void *p, size_t n) {
  std::string *v = slotFor(k);
  if (v->size() != n) return 0;
  memcpy(p, v->data(), n);
  return n;
}
size_t Preferences::putUChar(const char *k, uint8_t v) { *slotFor(k) = std::string(1, (char)v); nvsSave(); return 1; }
uint8_t Preferences::getUChar(const char *k, uint8_t def) { std::string *v = slotFor(k); return v->size() == 1 ? (uint8_t)(*v)[0] : def; }

// The radio side cli_link.cpp talks to.
static bool linked = true;
static void writeRecord(const uint8_t *p, size_t n) {
  uint8_t hdr[2] = {(uint8_t)n, (uint8_t)(n >> 8)};
  fwrite(hdr, 1, 2, stdout);
  fwrite(p, 1, n, stdout);
  fflush(stdout);
}
bool ble_pair_window_open() { const char *w = getenv("CLI_SIM_WINDOW"); return !w || strcmp(w, "0"); }
uint16_t ble_cli_mtu(int) { return 247; }
bool ble_cli_subscribed(int) { return linked; }
bool ble_cli_notify(int, const uint8_t *p, size_t n, bool, uint32_t) {
  if (!linked || n > 244) return false;
  writeRecord(p, n);
  return true;
}
void ble_cli_drop(int) {
  if (!linked) return;
  linked = false;
  writeRecord(NULL, 0);
  cli_reset(0);
}
// No Wi-Fi link in the sim (cli_tcp.h).
bool cli_tcp_up() { return false; }
bool cli_tcp_send(const uint8_t *, size_t, uint32_t) { return false; }
void cli_tcp_drop() {}
static std::vector<std::string> cmds;
void ble_cli_push_cmd(const char *line, size_t n) { cmds.push_back(std::string(line, n)); }

// The mirrored screen: the file's access units, a config record first, about 5 per second.
struct Au { std::vector<uint8_t> data; bool idr; };
static std::vector<uint8_t> config;
static std::vector<Au> aus;
static void loadScreen(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(1); }
  std::vector<uint8_t> b;
  for (int ch; (ch = fgetc(f)) != EOF;) b.push_back((uint8_t)ch);
  fclose(f);
  std::vector<size_t> starts;
  for (size_t i = 0; i + 3 < b.size(); i++)
    if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) starts.push_back(i > 0 && b[i - 1] == 0 ? i - 1 : i), i += 2;
  for (size_t k = 0; k < starts.size(); k++) {
    size_t s = starts[k], e = k + 1 < starts.size() ? starts[k + 1] : b.size();
    size_t h = b[s + 2] == 1 ? s + 3 : s + 4;
    int type = b[h] & 0x1f;
    std::vector<uint8_t> nal(b.begin() + s, b.begin() + e);
    if (type == 7 || type == 8) { if (aus.empty()) config.insert(config.end(), nal.begin(), nal.end()); }
    else if (type == 1 || type == 5) aus.push_back({nal, type == 5});
  }
  fprintf(stderr, "sim: %zu access units, config %zu bytes\n", aus.size(), config.size());
}

static uint16_t seq;
static bool sendAu(const std::vector<uint8_t> &d, uint8_t flags) {
  uint8_t chunk[VCHUNK_HDR + 512];
  size_t room = cli_video_room();
  if (room < 5) return false;
  vchunk c;
  vchunk_begin(&c, d.data(), d.size(), flags, millis());
  for (size_t len; (len = vchunk_next(&c, chunk, room, seq)) > 0; seq++)
    if (!cli_send_video(chunk, len)) return false;
  return true;
}

static void reply(const std::string &line) { cli_send_ctrl('r', line.data(), line.size(), 1000); }
static char ringBuf[2048];
static logring ring = {ringBuf, sizeof ringBuf, 0, 0};
// logbuf.cpp's board_log: cli_link.cpp's lines go to stderr and the simulated RAM log.
void board_log(const char *fmt, ...) {
  char line[256];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  fprintf(stderr, "%s\n", line);
  logring_add(&ring, line);
}

int main(int argc, char **argv) {
  t0 = nowMs();
  setvbuf(stdout, NULL, _IOFBF, 1 << 16);
  nvsLoad();
  if (argc > 1) loadScreen(argv[1]);
  cli_begin();
  logring_add(&ring, "[0.001] boot sim fw 0.2.3");
  logring_add(&ring, "[0.120] wifi: hotspot up");
  bool streaming = false, frozen = getenv("CLI_SIM_FROZEN") && !strcmp(getenv("CLI_SIM_FROZEN"), "1");
  size_t shown = 0;  // AUs of the file mirrored so far (the board's GOP)
  size_t sent = 0;   // of those, sent on the CLI's stream
  uint32_t lastStatus = 0, lastAu = 0;
  std::vector<uint8_t> in;
  for (;;) {
    pollfd p = {0, POLLIN, 0};
    if (poll(&p, 1, 20) > 0) {
      uint8_t buf[4096];
      ssize_t n = read(0, buf, sizeof buf);
      if (n <= 0) return 0;
      in.insert(in.end(), buf, buf + n);
      while (in.size() >= 2) {
        size_t len = in[0] | in[1] << 8;
        if (in.size() < 2 + len) break;
        if (len == 0) { cli_reset(0); linked = true; streaming = false; }  // the CLI reconnected
        else { linked = true; cli_on_frame(0, in.data() + 2, len); }
        in.erase(in.begin(), in.begin() + 2 + len);
      }
    }
    for (std::string line : cmds) {
      fprintf(stderr, "cmd: %s\n", line.c_str());
      size_t sp = line.find(' ');
      std::string id = line.substr(0, sp), rest = sp == std::string::npos ? "" : line.substr(sp + 1);
      if (rest == "stream on") { streaming = true; sent = 0; seq++; }  // resend the GOP from the IDR
      if (rest == "stream off") streaming = false;
      if (rest == "snap") {
        bool ok = !frozen && shown && sendAu(config, VF_CONFIG | VF_SNAP);
        for (size_t i = 0; ok && i < shown; i++) ok = sendAu(aus[i].data, VF_SNAP | (aus[i].idr ? VF_IDR : 0));
        reply(id + (ok ? " ok" : frozen ? " err video frozen (restart screen mirroring)" : " err no video (start screen mirroring)"));
      } else if (rest.rfind("logs", 0) == 0) {  // the board's RAM log (logbuf.cpp), from the real ring
        unsigned long from = 0, max = 120;
        sscanf(rest.c_str(), "logs %lu %lu", &from, &max);
        char page[401];
        uint32_t next = logring_read(&ring, from, page, (max > 400 ? 400 : max) + 1);
        reply(id + " ok " + std::to_string(next) + " " + std::to_string(ring.end) + " " + page);
      } else if (rest == "crash") {
        reply(id + " ok rst power-on, last dump: none");
      } else {
        reply(id + " ok");
      }
    }
    cmds.clear();
    if (cli_slot() < 0) continue;
    uint32_t now = millis();
    if (now - lastAu >= 200 && shown < aus.size() && !frozen) { shown++; lastAu = now; }
    if (streaming && !frozen) {
      if (sent == 0 && shown && !sendAu(config, VF_CONFIG)) continue;
      for (; sent < shown; sent++)
        if (!sendAu(aus[sent].data, aus[sent].idr ? VF_IDR : 0)) break;
    }
    if (now - lastStatus >= 1000) {
      lastStatus = now;
      char s[200];
      int n = snprintf(s, sizeof s, "{\"fw\":\"0.2.1\",\"up\":%u,\"usb\":\"ok\",\"net\":\"ap\",\"ap\":\"%s\",\"w\":480,\"h\":1040,\"fz\":%d}",
                       now, aus.empty() ? "idle" : "streaming", frozen);
      cli_send_ctrl('s', s, n, 1000);
    }
  }
}
