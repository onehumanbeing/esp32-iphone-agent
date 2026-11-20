#ifdef M5_STOPWATCH
#include "voice_rec.h"
#include <M5Unified.h>
#include <atomic>
#include "ble_link.h"
#include "logbuf.h"
#include "src/ui/ima_adpcm.h"

static const uint32_t RATE = 16000;
static const size_t FRAME = 800;          // samples per mic request: 50 ms
static const size_t LAG = RATE * 8;       // 8 s of sound (256 KB PSRAM) the link may fall behind; older is dropped
static const uint32_t PUMP_MS = 30;       // sending between two mic frames, so the mic always has a request queued
static const uint8_t F_VOICE = 0xC0, F_START = 0x01, F_END = 0x02;

static std::atomic<bool> held{false}, streaming{false}, micDone{false}, micEnded{true}, busy{false};
static std::atomic<int> level{0};
static char locale[8];

static int16_t *ring, *frames;  // PSRAM, for one recording
static struct Scratch { uint8_t chunk[256]; int16_t pcm[2 * 250]; uint8_t out[3 + 250]; int8_t db[40]; } *x;  // PSRAM too
static uint32_t w, r, lost;     // sample counts: written, sent; lost to the lag limit
static uint16_t seq;
static bool toSerial;  // this recording: no app subscribed on BLE when it began

static void take(const int16_t *f) {
  double sum = 0;
  for (size_t i = 0; i < FRAME; i++) {
    sum += (double)f[i] * f[i];
    ring[(w + i) % LAG] = f[i];
  }
  w += FRAME;
  if (w - r > LAG) lost += w - LAG - r, r = w - LAG;
  float db = 10 * log10f((float)(sum / FRAME) / (32768.0f * 32768.0f) + 1e-10f);  // dBFS
  if (w / FRAME <= 40) x->db[w / FRAME - 1] = (int8_t)(db < -127 ? -127 : db);  // the first 2 s, for the log
  level = db <= -60 ? 0 : db >= -10 ? 1000 : (int)((db + 60) * 20);
}

static bool chunk(uint8_t flags, const uint8_t *p, size_t n) {
  uint8_t *b = x->chunk;
  b[0] = (uint8_t)seq, b[1] = (uint8_t)(seq >> 8), b[2] = F_VOICE | flags;
  memcpy(b + 3, p, n);
  if (toSerial) {  // no app on BLE: the chunks go to USB serial as hex (tests: hardware/tools/voice_dump.py)
    static const char HEX_[] = "0123456789abcdef";
    String l = "vchunk ";
    for (size_t i = 0; i < n + 3; i++) l += HEX_[b[i] >> 4], l += HEX_[b[i] & 15];
    Serial.println(l);
    return seq++, true;
  }
  for (int tries = 0; tries < 3; tries++) {  // a full buffer waits in ble_video_send already; a stall gets 3 goes
    if (ble_video_send(b, n + 3)) return seq++, true;
    if (!ble_video_room()) return false;
  }
  return false;
}

// One chunk of ADPCM from r on: [pred i16 LE][index][2 samples a byte]; false when nothing went (none or no room).
static ima_state st;
static bool sendSound(size_t room, bool last) {
  int16_t *pcm = x->pcm;
  uint8_t *out = x->out;
  size_t bytes = min((size_t)(room - 3 - 3), (size_t)250), have = (w - r) / 2;
  if (!last && have < bytes) return false;  // whole chunks while recording
  bytes = min(bytes, have);
  if (!bytes) return false;
  for (size_t i = 0; i < 2 * bytes; i++) pcm[i] = ring[(r + i) % LAG];
  out[0] = (uint8_t)st.pred, out[1] = (uint8_t)((uint16_t)st.pred >> 8), out[2] = st.index;
  ima_state before = st;
  ima_encode(&st, pcm, 2 * bytes, out + 3);
  if (!chunk(0, out, 3 + bytes)) { st = before; return false; }
  r += 2 * bytes;
  return true;
}

static void voiceTask(void *) {
  uint32_t t0 = millis(), frame = 0, sent0 = 0;
  bool mic = true, started = false, gone = false;
  w = r = lost = 0, st = {0, 0};
  toSerial = ble_video_room() < 16;
  M5.Mic.record(frames, FRAME, RATE);
  M5.Mic.record(frames + FRAME, FRAME, RATE);
  for (int i = 2;; i++) {
    if (mic) {
      M5.Mic.record(frames + (i % 3) * FRAME, FRAME, RATE);  // waits for a free slot: the oldest frame is in
      take(frames + ((i - 2) % 3) * FRAME);
      frame++;
      if (!held) {  // the two frames still in the mic, then it can go
        while (M5.Mic.isRecording()) vTaskDelay(1);
        take(frames + ((i - 1) % 3) * FRAME);
        take(frames + (i % 3) * FRAME);
        mic = false, level = 0;
        micDone = true;  // voice_poll() ends the mic on the screen task
      }
    }
    if (!streaming) {
      if (!mic) break;  // released before the hold: nothing goes out
      continue;
    }
    size_t room = toSerial ? 256 : ble_video_room();
    if (room < 16) {  // the app's link is gone
      if (!gone) board_log("voice: the app's link is gone, %lu ms of sound not sent", (unsigned long)((w - r) / 16));
      gone = true;
      if (!mic) break;
      r = w;
      continue;
    }
    if (!started) {
      started = chunk(F_START, (const uint8_t *)locale, strlen(locale));
      sent0 = millis();
    }
    uint32_t pump = millis();
    while (started && (!mic || millis() - pump < PUMP_MS) && sendSound(room, !mic)) {}
    if (!mic && r == w) {
      chunk(F_END, nullptr, 0);
      break;
    }
  }
  if (streaming) board_log("voice: %lu ms recorded%s, %lu ms lost to the lag, sent in %lu ms after the first chunk, %lu chunks",
            (unsigned long)(w / 16), streaming ? "" : " (a short press: dropped)", (unsigned long)(lost / 16),
            (unsigned long)(streaming ? millis() - sent0 : 0), (unsigned long)seq);
  if (streaming) {  // a recording: how it sounded at first (the codec's start), and the task's headroom
    char dbs[40 * 5 + 1] = "";
    for (uint32_t i = 0; i < 40 && i < w / FRAME; i++) snprintf(dbs + strlen(dbs), 6, " %d", x->db[i]);
    board_log("voice: dBFS per 50 ms from the press:%s; stack left %u", dbs, (unsigned)uxTaskGetStackHighWaterMark(nullptr));
  }
  (void)t0, (void)frame;
  streaming = false;
  while (!micEnded) vTaskDelay(5);  // voice_poll() ends the mic on the screen task
  heap_caps_free(ring), heap_caps_free(frames), heap_caps_free(x);
  ring = frames = nullptr, x = nullptr;
  busy = false;
  vTaskDelete(nullptr);
}

bool voice_press(const char *loc) {
  if (busy) return false;
  if (!ring) ring = (int16_t *)heap_caps_malloc(LAG * 2, MALLOC_CAP_SPIRAM);
  if (!frames) frames = (int16_t *)heap_caps_malloc(3 * FRAME * 2, MALLOC_CAP_SPIRAM);
  if (!x) x = (Scratch *)heap_caps_malloc(sizeof *x, MALLOC_CAP_SPIRAM);
  if (!ring || !frames || !x) { board_log("voice: no PSRAM for the recording"); return false; }
  uint32_t h0 = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
  if (!M5.Mic.begin()) { board_log("voice: the mic did not start"); return false; }
  strlcpy(locale, loc, sizeof locale);
  held = true, streaming = false, micDone = false, micEnded = false, busy = true;
  if (xTaskCreatePinnedToCore(voiceTask, "voice", 3584, nullptr, 3, nullptr, 1) != pdPASS) {
    board_log("voice: no memory for the task (internal heap %u)", (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    M5.Mic.end();
    micEnded = true, busy = false;
    return false;
  }
  board_log("voice: mic on, internal heap %u -> %u", (unsigned)h0, (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
  return true;
}

void voice_stream() { if (busy && held) streaming = true; }
void voice_release() { held = false; }
int voice_level() { return level; }

void voice_poll() {
  if (micDone && !micEnded) {
    M5.Mic.end();
    micEnded = true;
  }
}
#endif
