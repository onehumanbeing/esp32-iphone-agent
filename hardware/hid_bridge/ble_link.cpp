// BLE GATT link, see ble_link.h. Host: h2zero NimBLE-Arduino 2.5.x, buffer sizes in nimble_cfg.h.
//
// Send path: replies and status go through a queue drained by one TX task (callers never block on
// the radio); video is sent from the video task and always yields to them. NimBLE's NOTIFY_TX event
// fires when a notify is queued in the host, not when it is on air, so it cannot pace anything.
// Video is paced on the controller's ACL credits instead (the host's count, returned by HCI Number
// of Completed Packets): while commands flow, at most VIDEO_CTRL_PKTS packets in the controller, so a
// reply or an ATT write response never queues behind more than ~2 KB of video. It also leaves MBUF_RESERVE host
// blocks free, and never sends while a reply or status is waiting.
#include "ble_link.h"
#include "ble_hid.h"
#include <atomic>
#include <utility>
#include <esp_heap_caps.h>
#include <esp_random.h>
#include <NimBLEDevice.h>
#include "nimble/nimble/host/include/host/ble_hs.h"
#include "netcfg.h"
#include "cli_link.h"
#include "src/cli/cli_proto.h"
#include "logbuf.h"

static_assert(MYNEWT_VAL(MSYS_1_BLOCK_COUNT) == 64 && MYNEWT_VAL(MSYS_1_BLOCK_SIZE) == 320,
              "nimble_cfg.h not applied: build with hardware/flash.sh");
static_assert(MYNEWT_VAL(MSYS_2_BLOCK_COUNT) == 0 && MYNEWT_VAL(BLE_TRANSPORT_ACL_FROM_LL_COUNT) == 24, "nimble_cfg.h");
static_assert(MYNEWT_VAL(BLE_STORE_MAX_BONDS) == 8, "nimble_cfg.h: bond slots");
static_assert(MYNEWT_VAL(BLE_ATT_PREFERRED_MTU) == 517 && MYNEWT_VAL(BLE_HS_LOG_LVL) == 5, "nimble_cfg.h");
static_assert(MYNEWT_VAL(BLE_MAX_CONNECTIONS) == 5 && !MYNEWT_VAL(BLE_ROLE_OBSERVER), "nimble_cfg.h: handles");
static_assert(!MYNEWT_VAL(BLE_EXT_ADV), "nimble_cfg.h: one legacy advertising set");
static_assert(MYNEWT_VAL(BLE_L2CAP_COC_MAX_NUM) == 1 && MYNEWT_VAL(BLE_L2CAP_COC_MPS) == 247, "nimble_cfg.h");

#define UUID(s) "6e400001-a9e8-4b1b-9c39-6d6f8a3c" s
const size_t CMD_MAX = 512;
const size_t TEXT_MAX = 514;               // MTU 517 - 3
const uint32_t VIDEO_TIMEOUT_MS = 1500;    // a full buffer waits; only a stalled link drops the chunk
const uint32_t REPLY_TIMEOUT_MS = 3000;    // replies retry this long (video is paused meanwhile)
const uint32_t STATUS_TIMEOUT_MS = 500;    // a newer status replaces it a second later anyway
const int MBUF_RESERVE = 16;               // of 64 msys blocks; video never takes these
const int VIDEO_CTRL_PKTS = 8;             // ACL packets video may have in the controller while commands flow
const uint32_t CMD_ACTIVE_MS = 1000;       // ... i.e. for this long after a `cmd` write; otherwise all of them
const int MBUF_DATA = MYNEWT_VAL(MSYS_1_BLOCK_SIZE) - 16;  // payload per block (16 B mbuf header)
// Up to MAX_PEERS centrals at once: the phone's app, plus a computer (the esp32agent CLI, or a debug harness).
const int MAX_PEERS = 2;
const uint32_t PLAIN_GRACE_MS = 15000;     // a link neither encrypted (app) nor a CLI session by then is dropped
// One legacy advertising set wears one identity at a time: the app's (public address, service 0000) or the CLI's
// (a random static address made at boot, service 0010; it never bonds, so no central holds a stale bond for it,
// docs/cli-protocol.md). Two sets at once need extended advertising, which cost ~9 KB of internal RAM (2026-10-21).
// A link up on one identity advertises the other; with none, the app's holds 3/4 of each second.
enum AdvId { ADV_NONE, ADV_APP, ADV_CLI };
const uint32_t ADV_CYCLE_MS = 1000, ADV_CLI_MS = 250;

enum { CH_REPLY, CH_STATUS, CH_VIDEO, CH_CLI, CH_COUNT };

struct Command {
#ifdef HID_TRANSPORT_BLE
  uint32_t hidSession;
#endif
  char origin;
  char line[CMD_MAX - 1];
};

struct Text {
  char dest;  // FROM_APP or FROM_CLI: whose reply this is
  uint16_t len;
  char s[TEXT_MAX];
};

static NimBLEServer *server;
static NimBLECharacteristic *chars[CH_COUNT], *netChar, *cliIn, *cliInNR;
static QueueHandle_t cmdQueue, replyQueue;
static SemaphoreHandle_t statusLock;
static Text statusText;
static String cliStatus;
static bool statusDirty, cliStatusDirty;
static volatile uint32_t connAt[MAX_PEERS];
static std::atomic<int> ctrlPending;  // replies queued or sending + a status waiting; video yields to them
static volatile int peers[MAX_PEERS] = {-1, -1};
static volatile bool subscribed[MAX_PEERS][CH_COUNT];
#ifdef HID_TRANSPORT_BLE
static std::atomic<int> trustedPhone[MAX_PEERS] = {-1, -1};
static bool hidSubscribed[MAX_PEERS];  // Only accessed by NimBLE subscription, authentication and disconnect callbacks.
#endif
static uint32_t winStart, winBytes;  // touched by the video task only
static volatile uint32_t kbps;
static std::atomic<uint32_t> drops, replyDrops;
static volatile uint32_t lastCmdMs;  // last `cmd` write: replies are expected, keep video's share small
static volatile uint32_t appSeenMs;  // last command from the app that drives the phone
// An app that only pings (every 2 s, in the background too) and logs is idle and lets the CLI in; its next real
// command takes the board back (2026-10-21: the app in the background held the board for good).
const uint32_t APP_IDLE_MS = 10000;

// "<id> <command>": anything but ping, log and the keep-awake nudge (move 1 0, move -1 0) is the app at work.
static bool appWorks(const String &line) {
  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(sp + 1);
  return cmd != "ping" && !cmd.startsWith("log ") && cmd != "move 1 0" && cmd != "move -1 0" &&
         !cmd.startsWith("hear");  // sharing what it heard with the CLI doesn't take the phone from it
}

#if DEBUG_SERIAL
#define BLE_LOG(...) Serial.printf("ble: " __VA_ARGS__)
#else
#define BLE_LOG(...) ((void)0)
#endif

// New phones may pair only this long after power-on (the board is powered by the phone it plugs into, so
// setup always falls in it). Later, only phones bonded before can connect: nobody nearby can pair and drive it.
const uint32_t PAIR_WINDOW_MS = 3 * 60 * 1000;
static uint32_t pairOpened;  // power-on, or the last unpair
static NimBLEAddress known[8];  // bonds at boot plus those made in the window
static int knownCount;

static bool isKnown(const NimBLEAddress &a) {
  for (int i = 0; i < knownCount; i++)
    if (known[i] == a) return true;
  return false;
}

// Commands and notifications need an encrypted (bonded) link: a stranger's plain link gets nothing.
static bool encrypted(int h) {
  ble_gap_conn_desc d;
  return h >= 0 && ble_gap_conn_find(h, &d) == 0 && d.sec_state.encrypted;
}

static bool appLink(int handle) {
#ifdef HID_TRANSPORT_BLE
  return ble_hid_allows(handle);
#else
  return encrypted(handle);
#endif
}

static int slotOf(int h) {
  for (int i = 0; i < MAX_PEERS; i++)
    if (peers[i] == h) return i;
  return -1;
}

// The peer's slot, claimed on first sight: a bonded central's restored subscriptions (and its
// encryption) can be reported before onConnect, and must not be lost.
static int slotFor(int h) {
  int i = slotOf(h);
  if (i < 0 && (i = slotOf(-1)) >= 0) {
    for (int c = 0; c < CH_COUNT; c++) subscribed[i][c] = false;
    peers[i] = h;
  }
  return i;
}

#ifdef HID_TRANSPORT_BLE
bool ble_hid_trusted(int handle) {
  ble_gap_conn_desc link;
  if (handle < 0 || ble_gap_conn_find(handle, &link) != 0 || link.our_ota_addr.type != BLE_ADDR_PUBLIC ||
      !link.sec_state.bonded || !link.sec_state.encrypted) return false;
  for (const auto &phone : trustedPhone) if (phone.load() == handle) return true;
  return false;
}

void ble_hid_subscribe(uint16_t handle, bool on) {
  int slot = on ? slotFor(handle) : slotOf(handle);
  if (slot < 0) return;
  hidSubscribed[slot] = on;
  if (on) ble_hid_claim(handle, true);
  else ble_hid_disconnected(handle);
}
#endif

static int peerCount() {
  int n = 0;
  for (int i = 0; i < MAX_PEERS; i++) n += peers[i] >= 0;
  return n;
}

static int indexOf(NimBLECharacteristic *c) {
  for (int i = 0; i < CH_COUNT; i++)
    if (chars[i] == c) return i;
  return -1;
}

static bool anySubscribed(int ch) {
  for (int i = 0; i < MAX_PEERS; i++)
    if (peers[i] >= 0 && subscribed[i][ch]) return true;
  return false;
}

static void advertise();

static void logConn(const char *what, NimBLEConnInfo &ci) {
  BLE_LOG("%s conn %u: interval %.2f ms, latency %u, timeout %u ms, mtu %u, %s\n", what, ci.getConnHandle(),
          ci.getConnInterval() * 1.25f, ci.getConnLatency(), ci.getConnTimeout() * 10u, ci.getMTU(),
          ci.isEncrypted() ? (ci.isBonded() ? "encrypted+bonded" : "encrypted") : "plain");
}

// 15 ms interval, no latency, 4 s supervision; reliable 1M PHY; DLE 251.
static void tuneLink(uint16_t h) {
  // Keep the connection on 1M: forcing 2M makes weak links repeatedly time out.
  server->setDataLen(h, 251);
  server->updateConnParams(h, 12, 12, 0, 400);
}

class ServerCb : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *s, NimBLEConnInfo &ci) override {
    int i = slotFor(ci.getConnHandle());
    if (i < 0) { s->disconnect(ci.getConnHandle()); return; }
    connAt[i] = millis();
    logConn("connect", ci);
    tuneLink(ci.getConnHandle());
    advertise();  // advertising stopped with this link; go on as the other side, while there is room
  }
  void onDisconnect(NimBLEServer *s, NimBLEConnInfo &ci, int reason) override {
    int i = slotOf(ci.getConnHandle());
    if (i >= 0) {
#ifdef HID_TRANSPORT_BLE
      trustedPhone[i] = -1;
      hidSubscribed[i] = false;
      ble_hid_disconnected(ci.getConnHandle());
#endif
      for (int c = 0; c < CH_COUNT; c++) subscribed[i][c] = false;
      peers[i] = -1;
      cli_reset(i);
    }
    BLE_LOG("disconnect conn %u, reason 0x%x\n", ci.getConnHandle(), reason);
    advertise();
  }
  void onMTUChange(uint16_t mtu, NimBLEConnInfo &ci) override { BLE_LOG("conn %u: mtu %u\n", ci.getConnHandle(), mtu); }
  void onConnParamsUpdate(NimBLEConnInfo &ci) override { logConn("params", ci); }
  void onPhyUpdate(NimBLEConnInfo &ci, uint8_t tx, uint8_t rx) override {
    BLE_LOG("conn %u: phy tx %uM rx %uM\n", ci.getConnHandle(), tx, rx);
  }
  void onAuthenticationComplete(NimBLEConnInfo &ci) override {
    logConn("security", ci);
    if (!ci.isEncrypted()) return;
    NimBLEAddress a = ci.getIdAddress();
    if (!isKnown(a)) {
      if (millis() - pairOpened >= PAIR_WINDOW_MS || knownCount >= 8) {
        BLE_LOG("conn %u: new phone outside the pairing window, refused\n", ci.getConnHandle());
        NimBLEDevice::deleteBond(a);
        server->disconnect(ci.getConnHandle());
        return;
      }
      known[knownCount++] = a;
    }
#ifdef HID_TRANSPORT_BLE
    // A restored subscription can arrive before encryption. Bind the trusted phone only after both.
    int slot = slotFor(ci.getConnHandle());
    if (slot >= 0) {
      trustedPhone[slot] = ci.getConnHandle();
      ble_hid_claim(ci.getConnHandle(), hidSubscribed[slot]);
    }
#endif
  }
};

class CharCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &ci) override {
    const NimBLEAttValue &raw = c->getValue();
    if (c == cliIn || c == cliInNR) { cli_on_frame(slotFor(ci.getConnHandle()), raw.data(), raw.length()); return; }
    String v(raw.c_str(), raw.length());
    if (!ci.isEncrypted()) return;
#ifdef HID_TRANSPORT_BLE
    if (!ble_hid_allows(ci.getConnHandle())) return;
#endif
    if (c == netChar) { net_request(v); return; }
    v.trim();
    if (appWorks(v)) appSeenMs = millis() | 1;
    ble_push_cmd(FROM_APP, v.c_str(), v.length());
  }
  void onRead(NimBLECharacteristic *c, NimBLEConnInfo &ci) override {
#ifdef HID_TRANSPORT_BLE
    if (!ble_hid_allows(ci.getConnHandle())) {
      c->setValue("{}");
      return;
    }
    if (c == chars[CH_STATUS]) {
      xSemaphoreTake(statusLock, portMAX_DELAY);
      c->setValue(reinterpret_cast<const uint8_t *>(statusText.s), statusText.len);
      xSemaphoreGive(statusLock);
      return;
    }
#endif
    if (c != netChar) return;
    String j = net_json();
    c->setValue((const uint8_t *)j.c_str(), j.length());
  }
  void onSubscribe(NimBLECharacteristic *c, NimBLEConnInfo &ci, uint16_t sub) override {
    int i = indexOf(c), p = sub & 1 ? slotFor(ci.getConnHandle()) : slotOf(ci.getConnHandle());
    if (i >= 0 && p >= 0) subscribed[p][i] = sub & 1;
    BLE_LOG("conn %u: %s %s\n", ci.getConnHandle(), sub & 1 ? "subscribed" : "unsubscribed",
            i == CH_REPLY ? "reply" : i == CH_STATUS ? "status" : i == CH_VIDEO ? "video" : "cli");
  }
};

static CharCb charCb;

#if DEBUG_SERIAL
static int onGap(ble_gap_event *e, void *) {  // NimBLEServerCallbacks has no data-length event
  if (e->type == BLE_GAP_EVENT_DATA_LEN_CHG)
    BLE_LOG("data length tx %u B / %u us, rx %u B / %u us\n", e->data_len_chg.max_tx_octets,
            e->data_len_chg.max_tx_time, e->data_len_chg.max_rx_octets, e->data_len_chg.max_rx_time);
  return 0;
}
#endif

extern "C" uint16_t ble_hs_hci_avail_pkts;  // free controller ACL buffers (NimBLE host, ble_hs_hci.c)
static uint16_t ctrlMax;                     // the controller's total, read at boot with no links up

// Room for a video notify of n bytes in the controller: its ACL fragments plus those already in flight.
static bool ctrlRoom(size_t n) {
  if (ble_hs_hci_avail_pkts > ctrlMax) ctrlMax = ble_hs_hci_avail_pkts;
  bool cmds = millis() - lastCmdMs < CMD_ACTIVE_MS;
  int frags = (int)((n + 3 + 4 + 250) / 251), limit = cmds && VIDEO_CTRL_PKTS < ctrlMax ? VIDEO_CTRL_PKTS : ctrlMax;
  return ctrlMax - ble_hs_hci_avail_pkts + frags <= (frags > limit ? frags : limit);
}

// msys blocks one queued notify of n bytes holds: ATT/L2CAP/HCI headers + packet header in the first
// block, plus one for the ACL fragment the host splits off.
static int blocksFor(size_t n) { return (int)((n + 3 + 4 + 4 + 8 + MBUF_DATA - 1) / MBUF_DATA) + 1; }

// One notify through the NimBLE host directly: unlike NimBLECharacteristic::notify() it reports
// "out of buffers", so we can wait instead of silently losing the packet.
static bool notifyOne(int slot, int ch, const uint8_t *p, size_t n, uint32_t start, uint32_t timeout_ms, bool video) {
  int need = blocksFor(n) + (video ? MBUF_RESERVE : 0);
  for (;;) {
    int h = peers[slot];
    // CLI frames are sealed (cli_link.cpp) and go to the CLI's own plain link; everything else needs encryption
    if (h < 0 || !subscribed[slot][ch]) return false;
    if (ch != CH_CLI && !appLink(h)) return false;
    if (!(video && (ctrlPending > 0 || !ctrlRoom(n))) && os_msys_num_free() >= need) {
      os_mbuf *om = ble_hs_mbuf_from_flat(p, n);
      int rc = om ? ble_gatts_notify_custom(h, chars[ch]->getHandle(), om) : BLE_HS_ENOMEM;  // om consumed
      if (rc == 0) return true;
      if (rc != BLE_HS_ENOMEM) {
        BLE_LOG("notify ch %d conn %d failed rc=%d\n", ch, h, rc);
        return false;
      }
    }
    if (millis() - start > timeout_ms) {
      BLE_LOG("notify ch %d conn %d gave up after %lu ms (free %d)\n", ch, h, millis() - start, os_msys_num_free());
      return false;
    }
    vTaskDelay(1);
  }
}

// To every subscribed peer within one deadline; true if at least one got it.
static bool notifyRaw(int ch, const uint8_t *p, size_t n, uint32_t timeout_ms) {
  uint32_t start = millis();
  bool any = false;
  for (int i = 0; i < MAX_PEERS; i++) any |= notifyOne(i, ch, p, n, start, timeout_ms, ch == CH_VIDEO);
  return any;
}

static void sendText(int ch, const Text &t, uint32_t timeout_ms) {
  size_t room = ble_mtu() - 3;
  if (ch == CH_STATUS && t.len > room) return;  // If the MTU shrank, wait for the next complete status.
  if (!notifyRaw(ch, (const uint8_t *)t.s, t.len < room ? t.len : room, timeout_ms) && ch == CH_REPLY &&
      anySubscribed(CH_REPLY)) {
    replyDrops++;
    BLE_LOG("reply dropped: %.*s\n", (int)t.len, t.s);
  }
}

// A plain link that is neither the app (it encrypts within a second) nor a CLI session: a stranger holding a slot.
// Not within the pairing window: the app's first link stays plain while iOS shows its pairing dialog.
static void dropIdlePlainLinks() {
  if (ble_pair_window_open()) return;
  for (int i = 0; i < MAX_PEERS; i++) {
    int h = peers[i];
    if (h >= 0 && !encrypted(h) && !cli_known(i) && millis() - connAt[i] > PLAIN_GRACE_MS) {
      BLE_LOG("conn %d: plain and idle for %lu s, dropped\n", h, PLAIN_GRACE_MS / 1000);
      connAt[i] = millis();  // once
      server->disconnect(h);
    }
  }
}

static void txTask(void *) {
  static Text t;
  for (;;) {
    if (xQueueReceive(replyQueue, &t, pdMS_TO_TICKS(20)) == pdTRUE) {
      if (t.dest == FROM_CLI) cli_send_ctrl('r', t.s, t.len, REPLY_TIMEOUT_MS);
      else sendText(CH_REPLY, t, REPLY_TIMEOUT_MS);
      ctrlPending--;
    }
    xSemaphoreTake(statusLock, portMAX_DELAY);
    bool due = statusDirty, cliDue = cliStatusDirty;
    if (due) t = statusText;
    statusDirty = false;
    xSemaphoreGive(statusLock);
    if (due) {
      sendText(CH_STATUS, t, STATUS_TIMEOUT_MS);
      ctrlPending--;
    }
    if (cliDue) {
      xSemaphoreTake(statusLock, portMAX_DELAY);
      String sending(std::move(cliStatus));
      cliStatusDirty = false;
      xSemaphoreGive(statusLock);
      cli_send_ctrl('s', sending.c_str(), sending.length(), STATUS_TIMEOUT_MS);
      ctrlPending--;
    }
    dropIdlePlainLinks();
    advertise();  // with nobody connected, the identities take turns
  }
}

static void toText(Text &t, const String &s) {
  t.len = s.length() < TEXT_MAX ? s.length() : TEXT_MAX;
  memcpy(t.s, s.c_str(), t.len);
}

static NimBLEAdvertisementData appAdv, cliAdv;
#ifdef HID_TRANSPORT_BLE
static NimBLEAdvertisementData appScan, cliScan;
#endif
static SemaphoreHandle_t advLock;
static AdvId advNow = ADV_NONE;

// The identity a link came in on: our own address on it is the CLI's random one, or the public one.
static bool viaCli(int h) {
  ble_gap_conn_desc d;
  return h >= 0 && ble_gap_conn_find(h, &d) == 0 && d.our_ota_addr.type == BLE_ADDR_RANDOM;
}

static AdvId wantedAdv() {
  if (peerCount() >= MAX_PEERS) return ADV_NONE;
  bool app = false, cli = false;
  for (int i = 0; i < MAX_PEERS; i++)
    if (peers[i] >= 0) (viaCli(peers[i]) ? cli : app) = true;
  if (app && cli) return ADV_NONE;
  if (app) return ADV_CLI;  // the CLI still learns the app holds the board (owner app, busy)
  if (cli) return ADV_APP;  // the app can always come and take over
  return millis() % ADV_CYCLE_MS < ADV_CLI_MS ? ADV_CLI : ADV_APP;
}

// Brings advertising to the identity wanted now; a connection ends it, so this also restarts it.
static void advertise() {
  xSemaphoreTake(advLock, portMAX_DELAY);
  AdvId want = wantedAdv();
  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  bool active = adv->isAdvertising();
  if (!active || want != advNow) {
    if (active) adv->stop();
    advNow = ADV_NONE;
    if (want != ADV_NONE && NimBLEDevice::setOwnAddrType(want == ADV_CLI ? BLE_OWN_ADDR_RANDOM : BLE_OWN_ADDR_PUBLIC) &&
        adv->setAdvertisementData(want == ADV_CLI ? cliAdv : appAdv) &&
#ifdef HID_TRANSPORT_BLE
        adv->setScanResponseData(want == ADV_CLI ? cliScan : appScan) &&
#endif
        adv->start())
      advNow = want;
  }
  xSemaphoreGive(advLock);
}

static void setUpAdvertising(const std::string &name) {
  for (auto *d : {&appAdv, &cliAdv}) d->setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  appAdv.setCompleteServices(NimBLEUUID(UUID("0000")));
#ifdef HID_TRANSPORT_BLE
  // Advertise HID on the stable app identity; keep the CLI on its own random address.
  appAdv.addServiceUUID(NimBLEUUID(uint16_t(0x1812)));
  appAdv.addServiceUUID(NimBLEUUID(uint16_t(0x180f)));
  appAdv.setAppearance(0x03c2);
#endif
  cliAdv.setCompleteServices(NimBLEUUID(UUID("0010")));
#ifdef HID_TRANSPORT_BLE
  // iOS lists devices by name; keep the board's four-digit suffix for CLI selection.
  appScan.setName(name);
  cliScan.setName("CLI " + name);
#else
  NimBLEAdvertisementData scan;
  scan.setName(name);
  NimBLEDevice::getAdvertising()->setScanResponseData(scan);
#endif
  uint8_t a[6];
  esp_fill_random(a, sizeof a);
  a[5] |= 0xC0;  // random static: top two bits set (NimBLE addresses are little-endian)
  if (!NimBLEDevice::setOwnAddr(a)) board_log("ble: no random address for the CLI");
}

// Queue storage in PSRAM (the two below hold ~7 KB); only the control block stays in internal RAM.
static QueueHandle_t psramQueue(UBaseType_t n, UBaseType_t size) {
  StaticQueue_t *q = (StaticQueue_t *)heap_caps_malloc(sizeof(StaticQueue_t), MALLOC_CAP_INTERNAL);
  uint8_t *buf = (uint8_t *)heap_caps_malloc(n * size, MALLOC_CAP_SPIRAM);
  if (q && buf) return xQueueCreateStatic(n, size, buf, q);
  free(q);
  free(buf);
  return xQueueCreate(n, size);
}

void ble_begin(const String &name) {
  cmdQueue = psramQueue(6, sizeof(Command));
  replyQueue = psramQueue(8, sizeof(Text));
  statusLock = xSemaphoreCreateMutex();
  NimBLEDevice::init(name.c_str());
  NimBLEDevice::setMTU(517);
  NimBLEDevice::setPower(9);  // dBm: retain link margin during setup, including a board powered by a Mac.
  NimBLEDevice::setDefaultPhy(BLE_GAP_LE_PHY_1M_MASK, BLE_GAP_LE_PHY_1M_MASK);
  NimBLEDevice::setSecurityAuth(true, false, true);  // bonding, Just Works, LE Secure Connections
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setSecurityInitKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setSecurityRespKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
#if DEBUG_SERIAL
  NimBLEDevice::setCustomGapHandler(onGap);
#endif

  for (int i = 0; i < NimBLEDevice::getNumBonds() && knownCount < 8; i++) known[knownCount++] = NimBLEDevice::getBondedAddress(i);

  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCb());
  NimBLEService *svc = server->createService(UUID("0000"));
  NimBLECharacteristic *cmd = svc->createCharacteristic(UUID("0001"), NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR |
                                                                                   NIMBLE_PROPERTY::WRITE_ENC);
  chars[CH_REPLY] = svc->createCharacteristic(UUID("0002"), NIMBLE_PROPERTY::NOTIFY);
  chars[CH_STATUS] = svc->createCharacteristic(UUID("0003"), NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ |
                                                                    NIMBLE_PROPERTY::READ_ENC);
  chars[CH_VIDEO] = svc->createCharacteristic(UUID("0004"), NIMBLE_PROPERTY::NOTIFY);
  netChar = svc->createCharacteristic(UUID("0005"), NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE |
                                                        NIMBLE_PROPERTY::READ_ENC | NIMBLE_PROPERTY::WRITE_ENC);
  NimBLEService *cliSvc = server->createService(UUID("0010"));
  cliIn = cliSvc->createCharacteristic(UUID("0011"), NIMBLE_PROPERTY::WRITE, CMD_MAX + 64);
  // The same frames as write commands (no ATT response to wait for), for frames that fit the MTU: a CLI waiting
  // on each write's response stalled behind video and timed out (2026-11-06).
  cliInNR = cliSvc->createCharacteristic(UUID("0013"), NIMBLE_PROPERTY::WRITE_NR, CMD_MAX + 64);
  chars[CH_CLI] = cliSvc->createCharacteristic(UUID("0012"), NIMBLE_PROPERTY::NOTIFY);
  cliIn->setCallbacks(&charCb);
  cliInNR->setCallbacks(&charCb);
  cmd->setCallbacks(&charCb);
  netChar->setCallbacks(&charCb);
  for (auto *c : chars) c->setCallbacks(&charCb);
#ifdef HID_TRANSPORT_BLE
  ble_hid_begin(server);
#endif
  server->start();

  advLock = xSemaphoreCreateMutex();
  setUpAdvertising(name.c_str());
  advertise();
  xTaskCreatePinnedToCore(txTask, "ble_tx", 3072, NULL, 3, NULL, 1);
  ctrlMax = ble_hs_hci_avail_pkts;
  board_log("ble: %s, msys %d x %d (%d free), acl rx %d, controller acl tx %u, mtu %d, coc %d x %d\n",
                NimBLEDevice::getVersion(), os_msys_count(), MYNEWT_VAL(MSYS_1_BLOCK_SIZE), os_msys_num_free(),
                MYNEWT_VAL(BLE_TRANSPORT_ACL_FROM_LL_COUNT), ctrlMax, ble_att_preferred_mtu(),
                MYNEWT_VAL(BLE_L2CAP_COC_MAX_NUM), MYNEWT_VAL(BLE_L2CAP_COC_MPS));
}

bool ble_connected() { return peerCount() > 0; }

bool ble_app_connected() {
  for (int i = 0; i < MAX_PEERS; i++)
    if (appLink(peers[i])) return true;
  return false;
}

bool ble_app_active() { return appSeenMs && millis() - appSeenMs < APP_IDLE_MS && ble_app_connected(); }

void ble_push_cmd(char origin, const char *line, size_t n) {
  Command cmd{};
  cmd.origin = origin;
#ifdef HID_TRANSPORT_BLE
  cmd.hidSession = ble_hid_session();
#endif
  if (!n) return;
  memcpy(cmd.line, line, n < sizeof(cmd.line) - 1 ? n : sizeof(cmd.line) - 1);
  lastCmdMs = millis();
  xQueueSend(cmdQueue, &cmd, 0);  // full queue: the sender times out and retries
}

bool ble_pop_cmd(String &line, char &origin, uint32_t wait_ms) {
  Command cmd;
  if (xQueueReceive(cmdQueue, &cmd, pdMS_TO_TICKS(wait_ms)) != pdTRUE) return false;
#ifdef HID_TRANSPORT_BLE
  if (!ble_hid_command_begin(cmd.hidSession)) return false;
#endif
  origin = cmd.origin;
  line = cmd.line;
  return true;
}

void ble_reply(const String &line, char dest) {
  if (dest == FROM_CLI ? cli_slot() < 0 : !anySubscribed(CH_REPLY)) return;
  Text t;
  t.dest = dest;
  toText(t, line);
  ctrlPending++;
  if (xQueueSend(replyQueue, &t, pdMS_TO_TICKS(200)) != pdTRUE) {  // 8 replies stuck: the link is gone
    ctrlPending--;
    replyDrops++;
  }
}

void ble_cli_status(String full, String compact) {
  int slot = cli_slot();
  if (slot < 0) return;
  const size_t room = cli_ctrl_room(cli_mtu());
  String &s = full.length() <= room ? full : compact;
  if (!s.length() || s.length() > room) return;
  xSemaphoreTake(statusLock, portMAX_DELAY);
  cliStatus = std::move(s);
  if (!cliStatusDirty) ctrlPending++;
  cliStatusDirty = true;
  xSemaphoreGive(statusLock);
}

void ble_status(const String &json) {
#ifndef HID_TRANSPORT_BLE
  chars[CH_STATUS]->setValue((const uint8_t *)json.c_str(), json.length());  // also served on read
#endif
  xSemaphoreTake(statusLock, portMAX_DELAY);
  toText(statusText, json);
  if (!anySubscribed(CH_STATUS)) { xSemaphoreGive(statusLock); return; }
  if (!statusDirty) ctrlPending++;
  statusDirty = true;
  xSemaphoreGive(statusLock);
}

size_t ble_video_room() { return anySubscribed(CH_VIDEO) ? ble_mtu() - 3 - 3 : 0; }

bool ble_video_send(const uint8_t *p, size_t n) {
  if (!notifyRaw(CH_VIDEO, p, n, VIDEO_TIMEOUT_MS)) {
    drops++;
    return false;
  }
  uint32_t now = millis();
  winBytes += n;
  if (now - winStart >= 1000) {
    kbps = winBytes * 8 / (now - winStart);
    winBytes = 0;
    winStart = now;
  }
  return true;
}

uint32_t ble_kbps() { return millis() - winStart > 2000 ? 0 : kbps; }
uint32_t ble_drops() { return drops; }
uint32_t ble_reply_drops() { return replyDrops; }
int ble_peers() { return peerCount(); }

uint16_t ble_mtu() {  // the smallest app peer's, so one notify fits every one of them (the CLI has its own)
  uint16_t mtu = 0;
  for (int i = 0; i < MAX_PEERS; i++) {
    int h = peers[i];
    uint16_t m = appLink(h) ? server->getPeerMTU(h) : 0;
    if (m && (!mtu || m < mtu)) mtu = m;
  }
  return mtu ? mtu : 23;
}

uint8_t ble_phy() {
  uint8_t tx = 1, rx = 1;
  int h = peers[0] >= 0 ? peers[0] : peers[1];
  if (h >= 0) ble_gap_read_le_phy(h, &tx, &rx);
  return tx == BLE_GAP_LE_PHY_2M ? 2 : 1;
}

void ble_unpair() {
  for (int i = 0; i < 100 && ctrlPending > 0; i++) vTaskDelay(pdMS_TO_TICKS(10));  // let the `ok` go out
#ifdef HID_TRANSPORT_BLE
  for (auto &phone : trustedPhone) phone = -1;
#endif
  NimBLEDevice::deleteAllBonds();  // unpairs each bond (also drops it from the controller's resolving list)
  ble_store_clear();               // and any CCCD/peer records left in NVS
  cli_forget_all();                // and paired computers
  knownCount = 0;                  // forgotten phones are strangers now; a new pairing window opens
  pairOpened = millis();
  bool any = false;
  for (int i = 0; i < MAX_PEERS; i++)
    if (peers[i] >= 0) { server->disconnect(peers[i]); any = true; }  // onDisconnect restarts advertising
  if (!any) advertise();
}

// Hooks for cli_link.cpp.
bool ble_pair_window_open() { return millis() - pairOpened < PAIR_WINDOW_MS; }

uint16_t ble_cli_mtu(int slot) {
  int h = slot >= 0 && slot < MAX_PEERS ? peers[slot] : -1;
  uint16_t m = h >= 0 ? server->getPeerMTU(h) : 0;
  return m ? m : 23;
}

bool ble_cli_subscribed(int slot) { return slot >= 0 && slot < MAX_PEERS && peers[slot] >= 0 && subscribed[slot][CH_CLI]; }

bool ble_cli_notify(int slot, const uint8_t *p, size_t n, bool video, uint32_t timeout_ms) {
  if (slot < 0 || slot >= MAX_PEERS || n > ble_cli_mtu(slot) - 3u) return false;
  bool ok = notifyOne(slot, CH_CLI, p, n, millis(), timeout_ms, video);
  if (video && ok) {
    uint32_t now = millis();
    winBytes += n;
    if (now - winStart >= 1000) {
      kbps = winBytes * 8 / (now - winStart);
      winBytes = 0;
      winStart = now;
    }
  }
  return ok;
}

void ble_cli_drop(int slot) {
  int h = slot >= 0 && slot < MAX_PEERS ? peers[slot] : -1;
  if (h >= 0) server->disconnect(h);
}

void ble_cli_push_cmd(const char *line, size_t n) { ble_push_cmd(FROM_CLI, line, n); }
