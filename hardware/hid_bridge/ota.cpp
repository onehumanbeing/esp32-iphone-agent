#include "ota.h"
#include <Update.h>
#include <esp_ota_ops.h>
#include "lwip/sockets.h"
#include "wifi_video.h"
#include "logbuf.h"
#include <esp_random.h>
#include "mbedtls/sha256.h"
#include "src/net/lan_lock.h"

const uint16_t PORT = 7300;
const int IDLE_MS = 5000;  // no bytes for this long: the app is gone

static volatile bool busy;

// Keep the image until it proves itself (see ota_confirm); the core would mark it good at boot otherwise.
// extern "C": the core's weak default is C, and a C++ definition (mangled) silently didn't replace it, so a
// broken image was confirmed at boot and boot-looped instead of rolling back (2026-10-19).
extern "C" bool verifyRollbackLater() { return true; }

static void reply(int c, const char *s) { send(c, s, strlen(s), 0); }

static void fail(int c, const char *why) {
  if (Update.isRunning()) Update.abort();
  char s[96];
  snprintf(s, sizeof s, "err %s\n", why);
  reply(c, s);
  board_log("ota: %s", why);
}

static bool readLine(int c, char *buf, size_t cap) {
  size_t n = 0;
  while (n + 1 < cap) {
    char ch;
    if (recv(c, &ch, 1, 0) != 1) return false;
    if (ch == '\n') break;
    buf[n++] = ch;
  }
  buf[n] = 0;
  return n + 1 < cap;
}

// Two headers. "ota <token> <size> <md5>": the token in the clear, fine on the board's own hotspot, refused under
// the LAN lock. Or "chal" (answered "chal <nonce>"), then "ota2 <size> <sha256> <hmac>" with
// hmac = HMAC-SHA256(token, "ota <nonce> <size> <sha256>"): the token never travels and the image is checked
// against the SHA-256 it signed before the board boots it (src/net/lan_lock.h).
static void session(int c) {
  timeval tv = {IDLE_MS / 1000, 0};
  setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  char head[192], tok[40], md5[40], sha[72], mac[72], nonce[LAN_NONCE_HEX + 1] = "";
  unsigned long size = 0;
  if (!readLine(c, head, sizeof head)) return fail(c, "usage: ota <token> <size> <md5>");
  if (!strcmp(head, "chal")) {
    uint8_t r[16];
    esp_fill_random(r, sizeof r);
    lan_nonce(nonce, r);
    char line[8 + LAN_NONCE_HEX];
    snprintf(line, sizeof line, "chal %s\n", nonce);
    reply(c, line);
    if (!readLine(c, head, sizeof head)) return fail(c, "usage: ota2 <size> <sha256> <hmac>");
  }
  bool signedImage = !strncmp(head, "ota2 ", 5);
  if (signedImage) {
    if (!nonce[0] || sscanf(head, "ota2 %lu %71s %71s", &size, sha, mac) != 3 || strlen(sha) != 64)
      return fail(c, "usage: chal, then ota2 <size> <sha256> <hmac>");
    char msg[160];
    snprintf(msg, sizeof msg, "ota %s %lu %s", nonce, size, sha);
    if (!lan_mac_ok(wv_token().c_str(), msg, mac)) return fail(c, "wrong token");
  } else {
    if (sscanf(head, "ota %39s %lu %39s", tok, &size, md5) != 3) return fail(c, "usage: ota <token> <size> <md5>");
    if (lan_locked()) return fail(c, "use chal and ota2 on this network");
    if (wv_token() != tok) return fail(c, "wrong token");
    if (strlen(md5) != 32) return fail(c, "bad md5");
  }
  if (!Update.begin(size, U_FLASH)) return fail(c, Update.errorString());
  if (!signedImage) Update.setMD5(md5);
  static mbedtls_sha256_context hash;
  mbedtls_sha256_init(&hash);
  mbedtls_sha256_starts(&hash, 0);
  busy = true;
  reply(c, "ok\n");
  board_log("ota: receiving %lu bytes", size);
  static uint8_t buf[4096];
  for (size_t got = 0; got < size;) {
    int n = recv(c, buf, size - got < sizeof buf ? size - got : sizeof buf, 0);
    if (n <= 0) { busy = false; return fail(c, "connection lost"); }
    if (Update.write(buf, n) != (size_t)n) { busy = false; return fail(c, Update.errorString()); }
    if (signedImage) mbedtls_sha256_update(&hash, buf, n);
    got += n;
  }
  if (signedImage) {
    uint8_t d[32];
    char got[65];
    mbedtls_sha256_finish(&hash, d);
    for (int i = 0; i < 32; i++) sprintf(got + 2 * i, "%02x", d[i]);
    if (strcasecmp(got, sha)) { busy = false; return fail(c, "image does not match its sha256"); }
  }
  mbedtls_sha256_free(&hash);
  if (!Update.end()) { busy = false; return fail(c, Update.errorString()); }  // includes the MD5 check (ota)
  reply(c, "done\n");
  board_log("ota: done, rebooting");
  delay(500);
  ESP.restart();
}

static void otaTask(void *) {
  int srv = socket(AF_INET, SOCK_STREAM, 0);
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(PORT);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  int one = 1;
  setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  if (srv < 0 || bind(srv, (sockaddr *)&addr, sizeof addr) < 0 || listen(srv, 1) < 0) {
    board_log("ota: listen failed");
    vTaskDelete(NULL);
  }
  for (;;) {
    int c = accept(srv, NULL, NULL);
    if (c < 0) continue;
    session(c);
    busy = false;
    close(c);
  }
}

static const char *stateName(esp_ota_img_states_t s) {
  switch (s) {
    case ESP_OTA_IMG_NEW: return "new";
    case ESP_OTA_IMG_PENDING_VERIFY: return "pending";
    case ESP_OTA_IMG_VALID: return "valid";
    case ESP_OTA_IMG_INVALID: return "invalid";
    case ESP_OTA_IMG_ABORTED: return "aborted";
    default: return "undefined";
  }
}

bool ota_begin() {
  const esp_partition_t *run = esp_ota_get_running_partition(), *other = esp_ota_get_next_update_partition(NULL);
  esp_ota_img_states_t a = ESP_OTA_IMG_UNDEFINED, b = ESP_OTA_IMG_UNDEFINED;
  esp_ota_get_state_partition(run, &a);
  if (other) esp_ota_get_state_partition(other, &b);
  board_log("ota: running %s (%s), other %s (%s)", run->label, stateName(a), other ? other->label : "-", stateName(b));
  return xTaskCreatePinnedToCore(otaTask, "ota", 6144, NULL, 2, NULL, 1) == pdPASS; }

bool ota_busy() { return busy; }

void ota_confirm() {
  esp_ota_img_states_t state;
  if (esp_ota_get_state_partition(esp_ota_get_running_partition(), &state) != ESP_OK) return;
  if (state != ESP_OTA_IMG_PENDING_VERIFY) return;
  esp_ota_mark_app_valid_cancel_rollback();
  board_log("ota: new firmware confirmed");
}
