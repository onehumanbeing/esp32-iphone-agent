// The periodic `diag` lines, see diag.h.
#include "diag.h"
#include <stdarg.h>
#include "ble_link.h"
#include "netcfg.h"
#include "video_link.h"
#include "wifi_video.h"
#include "hid_mode.h"
#include "logbuf.h"
#include "tusb.h"
#include "src/airplay/airplay.h"
#ifdef HID_TRANSPORT_BLE
#include "ble_hid.h"
#endif

const uint32_t WINDOW_MS = 5000;

static volatile uint32_t cmds, cmdErrs;

void diag_hid_command(bool ok) {
  cmds++;
  if (!ok) cmdErrs++;
}

// Running totals; a window logs the change between two of them. The max fields restart on every read.
struct Totals {
  uint32_t cmds, cmdErrs;
  uint32_t reports, reportFails, reportWaits, reportMaxMs;  // BLE HID only
  BleDiag ble;
  uint32_t bleDrops, replyDrops;
  VideoDiag v;
  uint32_t lost, conns;
  uint32_t wvRecords, wvMaxMs, wvDrops;
};

static Totals take() {
  Totals t = {};
  t.cmds = cmds;
  t.cmdErrs = cmdErrs;
#ifdef HID_TRANSPORT_BLE
  ble_hid_diag(&t.reports, &t.reportFails, &t.reportWaits, &t.reportMaxMs);
#endif
  t.ble = ble_diag();
  t.bleDrops = ble_drops();
  t.replyDrops = ble_reply_drops();
  t.v = video_diag();
  t.lost = video_stats(FROM_APP).lost;
  t.conns = airplay_data_conns();
  wv_diag(&t.wvRecords, &t.wvMaxMs);
  t.wvDrops = wv_drops();
  return t;
}

// To serial and the app only (diag.h). Each line stays under one BLE reply at the iPhone's usual MTU (185).
static void line(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void line(const char *fmt, ...) {
  char b[160];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(b, sizeof b, fmt, ap);
  va_end(ap);
  Serial.println(b);
  relayLine(b);
}

static const char *hidState() {
#ifdef HID_TRANSPORT_BLE
  if (hid_ble()) return ble_hid_ready() ? "ok" : "off";
#endif
  return !tud_mounted() ? "off" : tud_suspended() ? "asleep" : "ok";
}

typedef unsigned long ul;

void diag_tick() {
  static bool on;
  static uint32_t at;
  static Totals was;
  uint32_t now = millis();
  if (airplay_state() != AIRPLAY_STREAMING) {
    on = false;
    return;
  }
  if (!on) {  // mirroring (re)started: the first window starts now
    on = true;
    at = now;
    was = take();
    return;
  }
  if (now - at < WINDOW_MS) return;
  Totals t = take();
  const VideoDiag &v = t.v, &p = was.v;
  // The mouse and keyboard: commands run and failed; on BLE HID the reports, how many waited for host buffers
  // (the link was busy) and the longest wait. The phone's BLE link as the controller runs it (on BLE HID it carries
  // the reports too): interval (ms), latency, supervision timeout (ms).
  uint16_t itvl = 0, lat = 0, to = 0;
  ble_app_conn(&itvl, &lat, &to);
  line("diag hid %s %s: cmd %lu err %lu rep %lu fail %lu wait %lu max %lums | ble itvl %.2f lat %u to %u phy %u mtu %u coex %s",
       hid_ble() ? "ble" : "usb", hidState(), (ul)(t.cmds - was.cmds), (ul)(t.cmdErrs - was.cmdErrs),
       (ul)(t.reports - was.reports), (ul)(t.reportFails - was.reportFails), (ul)(t.reportWaits - was.reportWaits),
       (ul)t.reportMaxMs, itvl * 1.25f, lat, to * 10u, ble_phy(), ble_mtu(), net_coex_mode());
  // AirPlay in: AUs, KB, the longest gap between two AUs (a still screen still sends ~5 a second), time since the
  // last IDR and IDRs in the window, packets lost for good, new data connections (a sender that reconnected).
  // The Wi-Fi: mode, channel, the phone's RSSI, stations.
  int ch, rssi;
  net_radio(&ch, &rssi);
  line("diag ap: au %lu kb %lu gap %lums idr %lds +%lu lost %lu conn %lu | wifi %s ch %d rssi %d sta %d",
       (ul)(v.aus - p.aus), (ul)((v.bytes - p.bytes) / 1024), (ul)v.maxGapMs,
       v.sinceIdrMs ? (long)(v.sinceIdrMs / 1000) : -1L, (ul)(v.idrs - p.idrs), (ul)(t.lost - was.lost),
       (ul)(t.conns - was.conns), net_mode(), ch, rssi, net_peers());
  // Video out to the app: its Wi-Fi session (1: active), chunks sent and failed on it, TCP records written (video,
  // audio, keepalive answers), the longest write (the radio not getting data out), sessions dropped on a stalled
  // send. Its BLE fallback: chunks, failed, KB; any notify that waited for the host (replies, status, video) and the
  // longest wait; video notifies and replies dropped. Wi-Fi <-> BLE switches of the app's video.
  line("diag vlink: wifi %d ch %lu fail %lu rec %lu wmax %lums sdrop %lu | ble ch %lu fail %lu kb %lu nwait %lu nmax %lums"
       " drop %lu rdrop %lu | flip %lu",
       wv_active(), (ul)(v.wifiChunks - p.wifiChunks), (ul)(v.wifiFails - p.wifiFails), (ul)(t.wvRecords - was.wvRecords),
       (ul)t.wvMaxMs, (ul)(t.wvDrops - was.wvDrops), (ul)(v.bleChunks - p.bleChunks), (ul)(v.bleFails - p.bleFails),
       (ul)((t.ble.videoBytes - was.ble.videoBytes) / 1024), (ul)(t.ble.waits - was.ble.waits), (ul)t.ble.maxWaitMs,
       (ul)(t.bleDrops - was.bleDrops), (ul)(t.replyDrops - was.replyDrops), (ul)(v.flips - p.flips));
  // The GOP now: AUs, KB, overflows since boot, frozen for the app's stream and for how long. The app's resync
  // requests, the ones that went on from its last AU, the ones whose AU was gone; streams that fell off the tail.
  // Whether the app's stream follows the GOP now, and why it last stopped (vdbg `uf`).
  line("diag gop: %d AUs %lu KB ovf %lu fz %d %lus | resync %lu resume %lu miss %lu tb %lu | fol %d uf %c", v.gopAus,
       (ul)v.gopKb, (ul)v.overflows, v.frozen, (ul)(v.frozenMs / 1000), (ul)(v.resyncs - p.resyncs),
       (ul)(v.resumes - p.resumes), (ul)(v.resumeMisses - p.resumeMisses), (ul)(v.tailBreaks - p.tailBreaks),
       v.following, v.lastWhy);
  was = t;
  at = now;
}
