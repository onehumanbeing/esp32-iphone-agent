// Mirrored H.264 from AirPlay to BLE, see video_link.h.
#include "video_link.h"
#include <esp_heap_caps.h>
#include "ble_link.h"
#include "cli_link.h"
#include "wifi_video.h"
#include "src/video/gop.h"
#include "logbuf.h"

// GOP since the latest IDR. A still screen gets an IDR only every few minutes (iOS 26: maybe once per mirroring
// session), so room for ~27 min of AUs at 5 fps (P-frames of a still screen are tiny). When it fills, it freezes
// (gop.h): a stream that is in step goes on from the tail below, everyone else needs the next IDR (status fz).
#ifndef GOP_CAP_KB
#define GOP_CAP_KB 4096  // flash.sh --small-gop: 256, to test a frozen GOP within minutes
#endif
const size_t GOP_CAP = GOP_CAP_KB * 1024;
const int MAX_AUS = 8192;
const size_t TAIL_CAP = 512 * 1024;     // the newest AUs after a frozen GOP (a ring), to go on from or resume in
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
// One sink, one task: it sends to one side at a time, the app whenever it is there (Wi-Fi or BLE), else the CLI.
// Two (a task, queue and buffers each) cost ~8 KB of internal RAM while only one side ever drives the phone.
struct Sink {
  char who;          // the side it sends to now
  uint8_t *scratch;  // the AU being sent
  uint8_t cfg[GOP_CFG_MAX];
  QueueHandle_t reqs;
  TaskHandle_t task;
  volatile bool streaming[2];  // each side asked for `stream on` (the app over Wi-Fi streams regardless)
  uint16_t seq[2];             // each side's chunk numbers
  uint32_t txGen = UINT32_MAX;
  int next, tailNext;
  bool catchingUp;
  volatile uint32_t followGen = UINT32_MAX;  // the generation it sends in order, AU after AU
  volatile bool onTail;                      // it goes on from the tail past a frozen GOP
  bool resumed;                              // the next AU goes on from the app's last one: VF_RESUME
  uint32_t cliGen;                           // the CLI session it streams to (cli_gen()): a new one starts over
};

static gop_buf gop, tail;
static volatile bool tailLive;  // the tail holds every AU since the GOP froze (sent ones may be dropped)
static bool tailTrimmed;        // its oldest AUs were dropped: a resume must land in the tail itself
static Sink sink = {FROM_APP};
static SemaphoreHandle_t lock;
static uint8_t chunk[VCHUNK_HDR + (WV_PAYLOAD > MAX_CHUNK ? WV_PAYLOAD : MAX_CHUNK)];
static uint32_t winStart, winBytes, winFrames, lastIdr;
static volatile uint32_t lastAu;
static volatile uint32_t statKbps, statIdrMs, statAt;
static volatile float statFps;

static int sideOf(char who) { return who == FROM_CLI; }

static void unfollow(Sink &s, char why);
static uint8_t resumeFlag(Sink &s) {
  bool r = s.resumed;
  s.resumed = false;
  return r ? VF_RESUME : 0;
}

// Points the sink at who; a new side gets the config and the whole GOP first.
static void sendTo(Sink &s, char who) {
  if (s.who == who) return;
  s.who = who;
  s.txGen = UINT32_MAX;
  unfollow(s, 'w');
}

static char owner() { return cli_slot() >= 0 && !ble_app_active() ? FROM_CLI : FROM_APP; }

// Chunk room and send, per sink. The app's video goes over Wi-Fi while it holds a session there, else BLE.
static bool appWifi(const Sink &s) { return s.who == FROM_APP && wv_active(); }
static size_t videoRoom(const Sink &s) {
  if (s.who == FROM_CLI) return min(cli_video_room(), WV_PAYLOAD);  // BLE: under MAX_CHUNK; Wi-Fi: as the app's
  return appWifi(s) ? WV_PAYLOAD : min(ble_video_room(), MAX_CHUNK);
}
// The app's video over BLE comes first: the CLI's shares the same air, so it only goes in the app's pauses.
static bool videoSend(const Sink &s, bool wifi, const uint8_t *p, size_t n) {
  if (s.who == FROM_CLI) return cli_send_video(p, n);
  return wifi ? wv_send(p, n) : ble_video_send(p, n);
}

// One access unit as chunks. A failed chunk still consumes its seq, so the receiver sees a gap.
static bool sendAu(Sink &s, const uint8_t *p, size_t n, uint8_t flags, uint32_t ts) {
  bool wifi = appWifi(s);  // one transport per access unit
  size_t room = videoRoom(s);
  if (room < 5) return false;
  vchunk c;
  vchunk_begin(&c, p, n, flags, ts);
  uint16_t &seq = s.seq[sideOf(s.who)];
  // The app's chunks share one numbering over both links, and its one assembler takes both: a BLE chunk that
  // lands after newer Wi-Fi ones reads as a ~65535 gap there (2026-11-06, fw 0.2.3). Log every switch.
  static int8_t appLink = -1;  // -1 unknown, 0 BLE, 1 Wi-Fi
  if (s.who == FROM_APP && appLink != (int8_t)wifi) {
    if (appLink >= 0) board_log("video: app link %s -> %s at seq %u", appLink ? "wifi" : "ble", wifi ? "wifi" : "ble", seq);
    appLink = wifi;
  }
  for (size_t len; (len = vchunk_next(&c, chunk, room, seq)) > 0;) {
    bool ok = videoSend(s, wifi, chunk, len);
    seq++;
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

static bool frozenNow() {
  xSemaphoreTake(lock, portMAX_DELAY);
  bool f = gop.frozen;
  xSemaphoreGive(lock);
  return f;
}

// Why the sink last stopped following while it was in step, and when (vdbg): w new side, r resync, n not
// streaming / no room, c/g/t a failed config / GOP / tail send, b fell a whole tail ring behind.
static char lastWhy = '-';
static uint32_t lastWhyAt, tailBreaks;

// The sink fell out of order: its frozen GOP can't go on, the next IDR has to come.
static void unfollow(Sink &s, char why) {
  if (s.followGen != UINT32_MAX) lastWhy = why, lastWhyAt = millis();
  s.followGen = UINT32_MAX;
  s.onTail = false;
  s.resumed = false;
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
  uint16_t &seq = s.seq[sideOf(s.who)];
  memset(chunk + VCHUNK_HDR, 0xA5, room);
  for (size_t left = kb * 1024; left;) {
    size_t n = min(left, room);
    chunk[0] = (uint8_t)seq;
    chunk[1] = (uint8_t)(seq >> 8);
    chunk[2] = VF_BENCH;
    bool ok = videoSend(s, wifi, chunk, VCHUNK_HDR + n);
    seq++;
    if (!ok) return "err video send failed";
    left -= n;
  }
  return "ok " + String(millis() - start);
}

// The app reconnected with its decoder in step up to the AU stamped ts: go on right after it, in the GOP or in
// the tail past a frozen GOP, instead of resending the GOP from its IDR (minutes of P-frames, and impossible once
// the GOP froze: the screen stayed frozen until mirroring restarted, 2026-11-02). False if that AU is gone.
static bool resumeAt(Sink &s, uint32_t ts) {
  xSemaphoreTake(lock, portMAX_DELAY);
  int i = gop.wait_idr ? -1 : gop_find(&gop, ts);
  int j = gop.frozen && tailLive ? gop_find(&tail, ts) : -1;
  if (j < 0 && i >= 0 && gop.frozen && (!tailLive || tailTrimmed)) i = -1;  // the AUs right after it are gone
  bool ok = i >= 0 || j >= 0;
  if (ok) {
    s.txGen = s.followGen = gop.gen;
    s.next = j >= 0 ? gop.n : i + 1;
    s.tailNext = j >= 0 ? j + 1 : 0;
    s.onTail = gop.frozen;
    s.catchingUp = s.next < gop.n;
    s.resumed = true;
  }
  xSemaphoreGive(lock);
  return ok;
}

// Continuous mode: send every AU once, catching up from the GOP's IDR when streaming starts (P-frames
// can't be skipped: each needs the one before, and the next IDR may be minutes away). After a failed
// send, start over from the GOP's IDR. Past a frozen GOP, go on with the tail.
static void streamStep(Sink &s) {
  sendTo(s, owner());
  uint8_t *cfg = s.cfg;
  bool wifi = appWifi(s);
  // A new transport, or the app lost chunks it can't get back: resend config + whole GOP. Not again while the
  // last resend is still going: a GOP can be MBs (the next IDR may be minutes away), and restarting it at every
  // request (the app asks every 2 s) kept the air full, so mirroring and BLE starved (2026-10-20 03:00 log).
  bool resyncAsked = s.who == FROM_APP && wv_take_resync();
  uint32_t resumeTs;
  bool resume = wifi && resyncAsked && wv_take_resume(&resumeTs) && resumeAt(s, resumeTs);
  // A new transport goes on in place: the app's one assembler takes both links, a new app session asks for the IDR
  // itself (`hello`), and chunks lost on the old link end in a resume (`hello … at`). Resending the GOP at every
  // Wi-Fi/BLE flip replayed minutes of old screens into the decoder, 18 times in 11 min (2026-11-06).
  if (!resume && resyncAsked && !s.catchingUp) s.txGen = UINT32_MAX;
  if (s.who == FROM_CLI && s.cliGen != cli_gen()) {  // a new session (or the same one moved to Wi-Fi / BLE)
    s.cliGen = cli_gen();
    s.txGen = UINT32_MAX;
  }
  if (s.txGen == UINT32_MAX) unfollow(s, 'r');
  // Over Wi-Fi the app stays in step all the time, not only while it asked (`stream on`): turning the stream on
  // at a run start meant resending the whole GOP since mirroring began (a minute and more of P-frames), and the
  // run waited for it (2026-10-20 "waiting frame" log: 1 frame/s arriving, 57 s behind). AirPlay sends little
  // while the screen is still, so the steady stream is cheap.
  if (!(s.streaming[sideOf(s.who)] || wifi) || !videoRoom(s)) {
    s.txGen = UINT32_MAX;  // resend config + whole GOP when streaming resumes
    unfollow(s, 'n');
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
    if (!sendAu(s, cfg, cfg_len, VF_CONFIG, cfg_ts)) { s.txGen = UINT32_MAX; unfollow(s, 'c'); return; }
    s.followGen = gen;
  }
  for (gop_au au; s.next < n && copyAu(s, gen, s.next, &au); s.next++)
    if (!sendAu(s, s.scratch, au.len, (au.idr ? VF_IDR : 0) | resumeFlag(s), au.ts)) { s.txGen = UINT32_MAX; unfollow(s, 'g'); return; }
  if (s.next < n) return;
  s.catchingUp = false;
  for (gop_au au; copyTail(s, gen, s.tailNext, &au); s.tailNext++)
    if (!sendAu(s, s.scratch, au.len, resumeFlag(s), au.ts)) { s.txGen = UINT32_MAX; unfollow(s, 't'); return; }
}

static void videoTask(void *arg) {
  Sink &s = *(Sink *)arg;
  for (;;) {
    Req r;
    if (xQueueReceive(s.reqs, &r, 0) == pdTRUE) {
      sendTo(s, r.who);  // the CLI's only get here while the app is away (arbiter); the stream follows owner() next
      String reply = String(r.id) + " " + (r.bench ? doBench(s, r.kb) : doSnap(s));
      board_log("video: %s", reply.c_str());  // the reply only goes over BLE; mirror it for serial-driven tests
      ble_reply(reply, r.who);
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
  sink.scratch = (uint8_t *)heap_caps_malloc(SCRATCH_CAP, MALLOC_CAP_SPIRAM);
  sink.reqs = xQueueCreate(4, sizeof(Req));
  if (!arena || !aus || !tailArena || !tailAus || !sink.scratch || !sink.reqs) return false;
  gop_init(&gop, arena, GOP_CAP, aus, MAX_AUS);
  gop_init(&tail, tailArena, TAIL_CAP, tailAus, TAIL_AUS);
  lock = xSemaphoreCreateMutex();
  if (xTaskCreatePinnedToCore(videoTask, "video", 6 * 1024, &sink, 2, &sink.task, 1) != pdPASS) return false;
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
  if (froze) {  // the tail runs for everyone: an app that reconnects goes on from it (resume)
    gop_clear(&tail);
    sink.onTail = sink.followGen == gop.gen;
    sink.tailNext = 0;
    tailLive = true;
    tailTrimmed = false;
  }
  // A ring: full drops the oldest. It used to break once full unless the stream was on it at that moment, and a
  // stream off it for a second (a Wi-Fi hiccup) then found nothing to resume from: frozen until mirroring
  // restarted (2026-11-06, three times in a day).
  int dropped = gop.frozen && tailLive ? gop_append_ring(&tail, au, len, now) : 0;
  if (dropped < 0) tailLive = false;  // one AU larger than the whole tail
  if (dropped > 0) {
    tailTrimmed = true;
    if (sink.onTail && (sink.tailNext -= dropped) < 0) {  // it fell a whole ring behind: AUs it never sent are gone
      sink.tailNext = 0;
      sink.onTail = false;
      lastWhy = 'b', lastWhyAt = now;
    }
  }
  bool tailBroke = gop.frozen && !froze && wasLive && !tailLive;
  int aus = gop.n;
  uint32_t kb = gop.used / 1024;
  xSemaphoreGive(lock);
  if (froze) board_log("video: GOP full (%d AUs, %lu KB); the streams in step go on from the tail\n", aus,
                           (unsigned long)kb);
  if (tailBroke) tailBreaks++;
  if (tailBroke) board_log("video: a stream fell behind the tail; frozen until the next IDR");
  if (sink.task) xTaskNotifyGive(sink.task);
}

void video_stream(bool on, char who) { sink.streaming[sideOf(who)] = on; }

static void request(const String &id, bool bench, uint32_t kb, char who) {
  Req r = {{0}, kb, bench, who};
  strncpy(r.id, id.c_str(), sizeof r.id - 1);
  if (!sink.reqs || !sink.task || xQueueSend(sink.reqs, &r, 0) != pdTRUE) ble_reply(id + " err busy", who);
}

void video_snap(const String &id, char who) { request(id, false, 0, who); }
void video_bench(const String &id, uint32_t kb, char who) { request(id, true, kb, who); }

VideoStats video_stats(char who) {
  bool fresh = millis() - statAt < 3000;  // mirroring stopped: report zeros, not stale numbers
  xSemaphoreTake(lock, portMAX_DELAY);
  uint32_t gopBytes = gop.used, overflows = gop.overflows;
  bool frozen = gop.frozen && !(tailLive && sink.who == who && sink.onTail);
  xSemaphoreGive(lock);
  uint32_t age = lastAu ? millis() - lastAu : 0;
  return {fresh ? statKbps : 0, statIdrMs, gopBytes, age, fresh ? statFps : 0, overflows, frozen};
}

String video_debug() {
  char b[96];
  xSemaphoreTake(lock, portMAX_DELAY);
  // short: a BLE reply is one notification (a 200-char line never arrived, 2026-11-03)
  snprintf(b, sizeof b, "fz%d tl%d tt%d tn%d ot%d fg%d nx%d/%d tx%d cu%d uf%c %lus tb%lu", gop.frozen, tailLive,
           tailTrimmed, tail.n, sink.onTail, sink.followGen == gop.gen, sink.next, gop.n, sink.tailNext,
           sink.catchingUp, lastWhy, (unsigned long)(lastWhyAt ? (millis() - lastWhyAt) / 1000 : 0),
           (unsigned long)tailBreaks);
  xSemaphoreGive(lock);
  return b;
}
