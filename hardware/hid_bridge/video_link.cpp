// Mirrored H.264 from AirPlay to BLE, see video_link.h.
#include "video_link.h"
#include <esp_heap_caps.h>
#include "ble_link.h"
#include "cli_link.h"
#include "wifi_video.h"
#include "src/video/gop.h"

// GOP since the latest IDR. A still screen gets an IDR only every few minutes (iOS 26: maybe once per mirroring
// session), so room for ~27 min of AUs at 5 fps (P-frames of a still screen are tiny). When it fills, it freezes
// (gop.h): a stream that is in step goes on from the tail below, everyone else needs the next IDR (status fz).
const size_t GOP_CAP = 4 * 1024 * 1024;
const int MAX_AUS = 8192;
const size_t TAIL_CAP = 512 * 1024;     // AUs after a frozen GOP, until the streams have sent them
const int TAIL_AUS = 1024;
const size_t SCRATCH_CAP = 512 * 1024;   // largest access unit we forward
const size_t MAX_CHUNK = 512;

struct Req {
  char id[16];
  uint32_t kb;
  bool bench;
  char who;
};

// One receiver of the video: the app (over Wi-Fi while its session is up, else BLE) or the CLI (its own BLE
// link, cli_link.cpp). Each keeps its own place in the GOP and its own chunk numbering, and runs on its own task
// with its own buffers: a CLI catching up on MBs over BLE, or waiting for room, never holds up the app's video.
struct Sink {
  char who;
  uint8_t *scratch;  // the AU being sent
  uint8_t *chunk;
  uint8_t cfg[GOP_CFG_MAX];
  QueueHandle_t reqs;
  TaskHandle_t task;
  volatile bool streaming;  // asked for `stream on` (the app over Wi-Fi streams regardless)
  uint16_t seq;
  uint32_t txGen = UINT32_MAX;
  int next, tailNext;
  bool catchingUp, lastWifi;
  volatile uint32_t followGen = UINT32_MAX;  // the generation it sends in order, AU after AU
  volatile bool onTail;                      // it goes on from the tail past a frozen GOP
};

static gop_buf gop, tail;
static volatile bool tailLive;  // the tail holds every AU since the GOP froze
static Sink sinks[2] = {{FROM_APP}, {FROM_CLI}};
static SemaphoreHandle_t lock;
static uint8_t appChunk[VCHUNK_HDR + WV_PAYLOAD], cliChunk[VCHUNK_HDR + MAX_CHUNK];
static volatile uint32_t appBleAt;  // last chunk of the app's video over BLE: the CLI's waits for a pause
const uint32_t APP_BLE_PAUSE_MS = 50;
static uint32_t winStart, winBytes, winFrames, lastIdr;
static volatile uint32_t lastAu;
static volatile uint32_t statKbps, statIdrMs, statAt;
static volatile float statFps;

static Sink &sinkOf(char who) { return sinks[who == FROM_CLI]; }

// Chunk room and send, per sink. The app's video goes over Wi-Fi while it holds a session there, else BLE.
static bool appWifi(const Sink &s) { return s.who == FROM_APP && wv_active(); }
static size_t videoRoom(const Sink &s) {
  if (s.who == FROM_CLI) return min(cli_video_room(), MAX_CHUNK);
  return appWifi(s) ? WV_PAYLOAD : min(ble_video_room(), MAX_CHUNK);
}
// The app's video over BLE comes first: the CLI's shares the same air, so it only goes in the app's pauses.
static bool videoSend(const Sink &s, bool wifi, const uint8_t *p, size_t n) {
  if (s.who == FROM_CLI) {
    while (millis() - appBleAt < APP_BLE_PAUSE_MS) vTaskDelay(pdMS_TO_TICKS(10));
    return cli_send_video(p, n);
  }
  if (wifi) return wv_send(p, n);
  appBleAt = millis();
  return ble_video_send(p, n);
}

// One access unit as chunks. A failed chunk still consumes its seq, so the receiver sees a gap.
static bool sendAu(Sink &s, const uint8_t *p, size_t n, uint8_t flags, uint32_t ts) {
  bool wifi = appWifi(s);  // one transport per access unit
  size_t room = videoRoom(s);
  if (room < 5) return false;
  vchunk c;
  vchunk_begin(&c, p, n, flags, ts);
  for (size_t len; (len = vchunk_next(&c, s.chunk, room, s.seq)) > 0;) {
    bool ok = videoSend(s, wifi, s.chunk, len);
    s.seq++;
    if (!ok) return false;
  }
  return true;
}

// Copies AU i of generation gen into the sink's scratch; false if the GOP moved on.
static bool copyAu(Sink &s, uint32_t gen, int i, gop_au *au) {
  xSemaphoreTake(lock, portMAX_DELAY);
  bool ok = gop.gen == gen && i < gop.n && gop.aus[i].len <= SCRATCH_CAP;
  if (ok) {
    *au = gop.aus[i];
    memcpy(s.scratch, gop.arena + au->off, au->len);
  }
  xSemaphoreGive(lock);
  return ok;
}

// Copies tail AU i into the sink's scratch; false if there is none (yet) or the tail broke off.
static bool copyTail(Sink &s, uint32_t gen, int i, gop_au *au) {
  xSemaphoreTake(lock, portMAX_DELAY);
  bool ok = gop.gen == gen && tailLive && s.onTail && i < tail.n && tail.aus[i].len <= SCRATCH_CAP;
  if (ok) {
    *au = tail.aus[i];
    memcpy(s.scratch, tail.arena + au->off, au->len);
  }
  xSemaphoreGive(lock);
  return ok;
}

// Once every stream on the tail has sent all of it, empty it: it only has to hold what the slowest is behind.
static void tailSent(uint32_t gen) {
  xSemaphoreTake(lock, portMAX_DELAY);
  bool done = gop.gen == gen;
  for (Sink &s : sinks)
    if (s.onTail && s.tailNext < tail.n) done = false;
  if (done) {
    gop_clear(&tail);
    for (Sink &s : sinks) s.tailNext = 0;
  }
  xSemaphoreGive(lock);
}

static bool frozenNow() {
  xSemaphoreTake(lock, portMAX_DELAY);
  bool f = gop.frozen;
  xSemaphoreGive(lock);
  return f;
}

// The sink fell out of order: its frozen GOP can't go on, the next IDR has to come.
static void unfollow(Sink &s) {
  s.followGen = UINT32_MAX;
  s.onTail = false;
}

// Snapshot of the GOP state: generation, AU count, SPS/PPS. A frozen GOP counts as none (it may end minutes
// ago), except for a stream that goes on from the tail.
static bool snapshot(uint32_t *gen, int *n, uint8_t *cfg, size_t *cfg_len, uint32_t *cfg_ts, const Sink *following) {
  xSemaphoreTake(lock, portMAX_DELAY);
  *gen = gop.gen;
  if (gop.frozen && !(following && tailLive && following->onTail && following->followGen == gop.gen)) {
    *n = 0;
    *cfg_len = 0;
    xSemaphoreGive(lock);
    return false;
  }
  *n = gop.wait_idr ? 0 : gop.n;
  *cfg_len = gop.cfg_len;
  *cfg_ts = gop.cfg_ts;
  memcpy(cfg, gop.cfg, gop.cfg_len);
  xSemaphoreGive(lock);
  return *n > 0 && *cfg_len > 0;
}

static String doSnap(Sink &s) {
  uint8_t *cfg = s.cfg;
  if (!videoRoom(s)) return "err video not subscribed";
  for (int attempt = 0; attempt < 3; attempt++) {
    uint32_t gen, cfg_ts;
    size_t cfg_len;
    int n;
    if (!snapshot(&gen, &n, cfg, &cfg_len, &cfg_ts, NULL))
      return frozenNow() ? "err video frozen (restart screen mirroring)" : "err no video (start screen mirroring)";
    if (!sendAu(s, cfg, cfg_len, VF_CONFIG | VF_SNAP, cfg_ts)) return "err video send failed";
    bool complete = true;
    for (int i = 0; i < n && complete; i++) {
      gop_au au;
      complete = copyAu(s, gen, i, &au);
      if (complete && !sendAu(s, s.scratch, au.len, VF_SNAP | (au.idr ? VF_IDR : 0), au.ts)) return "err video send failed";
    }
    if (complete) return "ok";  // else a new IDR replaced the GOP mid-send: start over with it
  }
  return "err video changing too fast";
}

static String doBench(Sink &s, uint32_t kb) {
  bool wifi = appWifi(s);
  size_t room = videoRoom(s);
  if (!room) return "err video not subscribed";
  uint32_t start = millis();
  uint8_t *chunk = s.chunk;
  memset(chunk + VCHUNK_HDR, 0xA5, room);
  for (size_t left = kb * 1024; left;) {
    size_t n = min(left, room);
    chunk[0] = (uint8_t)s.seq;
    chunk[1] = (uint8_t)(s.seq >> 8);
    chunk[2] = VF_BENCH;
    bool ok = videoSend(s, wifi, chunk, VCHUNK_HDR + n);
    s.seq++;
    if (!ok) return "err video send failed";
    left -= n;
  }
  return "ok " + String(millis() - start);
}

// Continuous mode: send every AU once, catching up from the GOP's IDR when streaming starts (P-frames
// can't be skipped: each needs the one before, and the next IDR may be minutes away). After a failed
// send, start over from the GOP's IDR. Past a frozen GOP, go on with the tail.
static void streamStep(Sink &s) {
  uint8_t *cfg = s.cfg;
  bool wifi = appWifi(s);
  // A new transport, or the app lost chunks it can't get back: resend config + whole GOP. Not again while the
  // last resend is still going: a GOP can be MBs (the next IDR may be minutes away), and restarting it at every
  // request (the app asks every 2 s) kept the air full, so mirroring and BLE starved (2026-10-20 03:00 log).
  bool resyncAsked = s.who == FROM_APP && wv_take_resync();
  if (wifi != s.lastWifi || (resyncAsked && !s.catchingUp)) s.txGen = UINT32_MAX;
  s.lastWifi = wifi;
  if (s.txGen == UINT32_MAX) unfollow(s);
  // Over Wi-Fi the app stays in step all the time, not only while it asked (`stream on`): turning the stream on
  // at a run start meant resending the whole GOP since mirroring began (a minute and more of P-frames), and the
  // run waited for it (2026-10-20 "waiting frame" log: 1 frame/s arriving, 57 s behind). AirPlay sends little
  // while the screen is still, so the steady stream is cheap.
  if (!(s.streaming || wifi) || !videoRoom(s)) {
    s.txGen = UINT32_MAX;  // resend config + whole GOP when streaming resumes
    unfollow(s);
    return;
  }
  uint32_t gen, cfg_ts;
  size_t cfg_len;
  int n;
  if (!snapshot(&gen, &n, cfg, &cfg_len, &cfg_ts, &s)) return;
  if (gen != s.txGen) {
    s.txGen = gen;
    s.next = s.tailNext = 0;
    s.catchingUp = true;
    if (!sendAu(s, cfg, cfg_len, VF_CONFIG, cfg_ts)) { s.txGen = UINT32_MAX; unfollow(s); return; }
    s.followGen = gen;
  }
  for (gop_au au; s.next < n && copyAu(s, gen, s.next, &au); s.next++)
    if (!sendAu(s, s.scratch, au.len, au.idr ? VF_IDR : 0, au.ts)) { s.txGen = UINT32_MAX; unfollow(s); return; }
  if (s.next < n) return;
  s.catchingUp = false;
  for (gop_au au; copyTail(s, gen, s.tailNext, &au); s.tailNext++)
    if (!sendAu(s, s.scratch, au.len, 0, au.ts)) { s.txGen = UINT32_MAX; unfollow(s); return; }
  tailSent(gen);
}

static void videoTask(void *arg) {
  Sink &s = *(Sink *)arg;
  for (;;) {
    Req r;
    if (xQueueReceive(s.reqs, &r, 0) == pdTRUE) {
      String reply = String(r.id) + " " + (r.bench ? doBench(s, r.kb) : doSnap(s));
      Serial.println("video: " + reply);  // the reply only goes over BLE; mirror it for serial-driven tests
      ble_reply(reply, s.who);
    }
    streamStep(s);
    ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(20));
  }
}

bool video_begin() {
  uint8_t *arena = (uint8_t *)heap_caps_malloc(GOP_CAP, MALLOC_CAP_SPIRAM);
  gop_au *aus = (gop_au *)heap_caps_malloc(MAX_AUS * sizeof(gop_au), MALLOC_CAP_SPIRAM);
  uint8_t *tailArena = (uint8_t *)heap_caps_malloc(TAIL_CAP, MALLOC_CAP_SPIRAM);
  gop_au *tailAus = (gop_au *)heap_caps_malloc(TAIL_AUS * sizeof(gop_au), MALLOC_CAP_SPIRAM);
  sinks[0].chunk = appChunk;
  sinks[1].chunk = cliChunk;
  for (Sink &s : sinks) {
    s.scratch = (uint8_t *)heap_caps_malloc(SCRATCH_CAP, MALLOC_CAP_SPIRAM);
    s.reqs = xQueueCreate(4, sizeof(Req));
  }
  if (!arena || !aus || !tailArena || !tailAus || !sinks[0].scratch || !sinks[0].reqs) return false;
  gop_init(&gop, arena, GOP_CAP, aus, MAX_AUS);
  gop_init(&tail, tailArena, TAIL_CAP, tailAus, TAIL_AUS);
  lock = xSemaphoreCreateMutex();
  if (xTaskCreatePinnedToCore(videoTask, "video", 6 * 1024, &sinks[0], 2, &sinks[0].task, 1) != pdPASS) return false;
  // The CLI's video is extra: without room for it the app's goes on, the CLI's snap answers "err busy"
  if (!sinks[1].scratch || !sinks[1].reqs ||
      xTaskCreatePinnedToCore(videoTask, "clivideo", 6 * 1024, &sinks[1], 2, &sinks[1].task, 1) != pdPASS)
    Serial.println("video: no room for the CLI's video");
  return true;
}

void video_on_config(const uint8_t *sps_pps, size_t len) {
  xSemaphoreTake(lock, portMAX_DELAY);
  gop_set_config(&gop, sps_pps, len, millis());
  xSemaphoreGive(lock);
}

void video_on_au(const uint8_t *au, size_t len, bool idr) {
  uint32_t now = millis();
  lastAu = now;
  winBytes += len;
  winFrames++;
  if (idr) {
    if (lastIdr) statIdrMs = now - lastIdr;
    lastIdr = now;
  }
  if (now - winStart >= 1000) {
    statKbps = winBytes * 8 / (now - winStart);
    statFps = winFrames * 1000.0f / (now - winStart);
    statAt = now;
    winBytes = winFrames = 0;
    winStart = now;
  }
  xSemaphoreTake(lock, portMAX_DELAY);
  bool wasFrozen = gop.frozen, wasLive = tailLive;
  gop_push(&gop, au, len, idr, now);
  bool froze = gop.frozen && !wasFrozen;
  if (froze) {
    gop_clear(&tail);
    tailLive = false;
    for (Sink &s : sinks) {
      s.onTail = s.followGen == gop.gen;
      s.tailNext = 0;
      tailLive |= s.onTail;
    }
  }
  if (gop.frozen && tailLive && gop_append(&tail, au, len, false, now) < 0) tailLive = false;  // a stream fell too far behind
  bool tailBroke = gop.frozen && !froze && wasLive && !tailLive;
  int aus = gop.n;
  uint32_t kb = gop.used / 1024;
  xSemaphoreGive(lock);
  if (froze) Serial.printf("video: GOP full (%d AUs, %lu KB); %s\n", aus, (unsigned long)kb,
                           tailLive ? "the streams in step go on from the tail" : "frozen until the next IDR");
  if (tailBroke) Serial.println("video: a stream fell behind the tail; frozen until the next IDR");
  for (Sink &s : sinks)
    if (s.task) xTaskNotifyGive(s.task);
}

void video_stream(bool on, char who) { sinkOf(who).streaming = on; }

static void request(const String &id, bool bench, uint32_t kb, char who) {
  Req r = {{0}, kb, bench, who};
  strncpy(r.id, id.c_str(), sizeof r.id - 1);
  QueueHandle_t q = sinkOf(who).reqs;
  if (!q || !sinkOf(who).task || xQueueSend(q, &r, 0) != pdTRUE) ble_reply(id + " err busy", who);
}

void video_snap(const String &id, char who) { request(id, false, 0, who); }
void video_bench(const String &id, uint32_t kb, char who) { request(id, true, kb, who); }

VideoStats video_stats(char who) {
  bool fresh = millis() - statAt < 3000;  // mirroring stopped: report zeros, not stale numbers
  xSemaphoreTake(lock, portMAX_DELAY);
  uint32_t gopBytes = gop.used, overflows = gop.overflows;
  bool frozen = gop.frozen && !(tailLive && sinkOf(who).onTail);
  xSemaphoreGive(lock);
  uint32_t age = lastAu ? millis() - lastAu : 0;
  return {fresh ? statKbps : 0, statIdrMs, gopBytes, age, fresh ? statFps : 0, overflows, frozen};
}
