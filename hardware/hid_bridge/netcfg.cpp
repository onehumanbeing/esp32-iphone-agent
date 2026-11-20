// Board settings in NVS and the Wi-Fi link, see netcfg.h.
#include "netcfg.h"
#include <WiFi.h>
#include <Preferences.h>
#include <esp_mac.h>
#include <esp_random.h>
#include <esp_netif.h>
#include <esp_coexist.h>
#include <esp_wifi.h>
#include "wifi_video.h"
#include "src/net/lan_lock.h"
#include "src/airplay/airplay.h"
#include "logbuf.h"

#if STA_FROM_SECRETS
#if __has_include("secrets.h")
#include "secrets.h"  // WIFI_SSID, WIFI_PASS (git-ignored)
#include "logbuf.h"
#define BOOT_STA 1
#else
#warning "STA_FROM_SECRETS set but secrets.h is missing: booting as SoftAP"
#endif
#endif

static Preferences prefs;
static String apSsid, apPass, staSsid, staPass, mode;  // mode: "ap" | "sta"
static String pending;
static SemaphoreHandle_t pendingLock = xSemaphoreCreateMutex();
// Joining a home network without a restart: AirPlay is advertised again once it is up (airplay_readvertise).
static uint32_t changedAt = 0;
static bool readvertise = false;
// STA retries back off: a tight reconnect loop starves BLE, which shares the radio.
static uint32_t retryAt = 0, retryGap = 5000;

String board_suffix() {
  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_BT);
  char s[5];
  snprintf(s, sizeof s, "%02X%02X", mac[4], mac[5]);
  return s;
}

static String randomPass() {
  const char *abc = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";  // no look-alikes
  String p;
  for (int i = 0; i < 12; i++) p += abc[esp_random() % strlen(abc)];
  return p;
}

// Value of a string field in a flat JSON object ("" if absent). Handles \" and \\ escapes.
static String jsonStr(const String &j, const char *key) {
  int k = j.indexOf(String("\"") + key + "\"");
  if (k < 0) return "";
  int c = j.indexOf(':', k);
  int q = c < 0 ? -1 : j.indexOf('"', c);
  if (q < 0) return "";
  String v;
  for (int i = q + 1; i < (int)j.length() && j[i] != '"'; i++) v += j[i] == '\\' && i + 1 < (int)j.length() ? j[++i] : j[i];
  return v;
}

static String jsonEsc(const String &s) {
  String o;
  for (char ch : s) {
    if (ch == '"' || ch == '\\') o += '\\';
    o += ch;
  }
  return o;
}

// DHCP replies without a router or DNS server: the phone then keeps cellular as its internet
// route and uses the hotspot only for 192.168.4.x (AirPlay to the board).
static void noDefaultRoute() {
  esp_netif_t *ap = WiFi.AP.netif();
  if (!ap) return;
  uint8_t off = 0;
  esp_netif_dhcps_stop(ap);
  esp_netif_dhcps_option(ap, ESP_NETIF_OP_SET, ESP_NETIF_ROUTER_SOLICITATION_ADDRESS, &off, sizeof(off));
  esp_netif_dhcps_option(ap, ESP_NETIF_OP_SET, ESP_NETIF_DOMAIN_NAME_SERVER, &off, sizeof(off));
  esp_netif_dhcps_start(ap);
}

static void startWifi() {
  WiFi.disconnect(true);
  WiFi.softAPdisconnect(true);
  WiFi.setHostname("iphone-agent");
  if (mode == "off") {  // diagnostics: BLE alone on the radio
    WiFi.mode(WIFI_OFF);
  } else if (mode == "sta") {
    WiFi.mode(WIFI_STA);  // keep modem sleep on: required while BLE shares the radio
    WiFi.setAutoReconnect(false);
    retryGap = 5000;
    retryAt = millis() + retryGap;
    // The core rejects open networks by default. Set both ways: once lowered for an open network, a network with
    // a password afterwards would also have been joined by an open look-alike with its name.
    WiFi.setMinSecurity(staPass.isEmpty() ? WIFI_AUTH_OPEN : WIFI_AUTH_WPA2_PSK);
    WiFi.begin(staSsid.c_str(), staPass.c_str());
  } else {
    WiFi.mode(WIFI_AP);
    WiFi.softAP(apSsid.c_str(), apPass.c_str(), 6, 0, 4);
    // The phone is centimetres away and powers the board: low TX power cuts the current peaks that made the
    // phone drop its USB power (the board then came back with reset reason "power-on").
    WiFi.setTxPower(WIFI_POWER_5dBm);
#if AP_TUNE  // A/B knob (flash.sh --ap-tune): a 20 MHz channel and fewer beacons leave BLE more airtime
    WiFi.softAPbandwidth(WIFI_BW_HT20);
    wifi_config_t c;
    if (esp_wifi_get_config(WIFI_IF_AP, &c) == ESP_OK) {
      c.ap.beacon_interval = 300;
      esp_wifi_set_config(WIFI_IF_AP, &c);
    }
#endif
    noDefaultRoute();
  }
}

#if DEBUG_SERIAL
static void logWifi(arduino_event_id_t e, arduino_event_info_t info) {
  if (e == ARDUINO_EVENT_WIFI_STA_DISCONNECTED) board_log("wifi: disconnected, reason %d", info.wifi_sta_disconnected.reason);
  if (e == ARDUINO_EVENT_WIFI_STA_GOT_IP) board_log("wifi: got ip %s", WiFi.localIP().toString().c_str());
}
#endif

void net_begin() {
#if DEBUG_SERIAL
  WiFi.onEvent(logWifi);
#endif
  prefs.begin("agent", false);
  apSsid = prefs.getString("ap_ssid", "");
  apPass = prefs.getString("ap_pass", "");
  if (apSsid.isEmpty() || apPass.length() < 8) {
    apSsid = "ESP32Agent-" + board_suffix();
    apPass = randomPass();
    prefs.putString("ap_ssid", apSsid);
    prefs.putString("ap_pass", apPass);
  }
  mode = prefs.getString("mode", "ap");
  staSsid = prefs.getString("sta_ssid", "");
  staPass = prefs.getString("sta_pass", "");
#ifdef BOOT_STA
  mode = "sta";  // build-time test mode, not stored
  staSsid = WIFI_SSID;
  staPass = WIFI_PASS;
#endif
  if (mode == "sta" && staSsid.isEmpty()) mode = "ap";
  lan_set_station(mode == "sta");
  lan_set_owner(mode == "sta" ? prefs.getUInt("lan_owner", 0) : 0);
  startWifi();
  bool coexSet = net_coex("balance");
  wifi_ps_type_t ps = WIFI_PS_NONE;
  esp_wifi_get_ps(&ps);
  // Wi-Fi and BLE share one radio: what it is told at boot (esp_coex_preference_set is deprecated in IDF 5 and
  // may do nothing; the `diag` lines show what the radio share does to the video).
  board_log("radio: coex %s (%s), coex lib %s, wifi ps %d", net_coex_mode(), coexSet ? "set" : "refused",
            esp_coex_version_get(), (int)ps);
}

void net_radio(int *channel, int *rssi) {
  uint8_t primary = 0;
  wifi_second_chan_t second;
  *channel = esp_wifi_get_channel(&primary, &second) == ESP_OK ? primary : 0;
  *rssi = 0;
  wifi_mode_t m = WIFI_MODE_NULL;
  if (esp_wifi_get_mode(&m) != ESP_OK) return;
  if (m & WIFI_MODE_STA) {
    wifi_ap_record_t ap;
    if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) *rssi = ap.rssi;
  } else if (m & WIFI_MODE_AP) {
    static wifi_sta_list_t list;  // only the status task asks
    if (esp_wifi_ap_get_sta_list(&list) == ESP_OK && list.num > 0) *rssi = list.sta[0].rssi;
  }
}

static const char *coexNames[] = {"wifi", "bt", "balance"};  // esp_coex_prefer_t order
static int coexPref = ESP_COEX_PREFER_BALANCE;

bool net_coex(const String &pref) {
  for (int i = 0; i < 3; i++)
    if (pref == coexNames[i] && esp_coex_preference_set((esp_coex_prefer_t)i) == ESP_OK) {
      coexPref = i;
      return true;
    }
  return false;
}

const char *net_coex_mode() { return coexNames[coexPref]; }

void net_request(const String &json) {
  xSemaphoreTake(pendingLock, portMAX_DELAY);
  pending = json;
  xSemaphoreGive(pendingLock);
}

static void retrySta() {
  if (mode != "sta") return;
  if (WiFi.status() == WL_CONNECTED) {
    retryGap = 5000;
    return;
  }
  if ((int32_t)(millis() - retryAt) < 0) return;
  WiFi.disconnect();
  WiFi.begin(staSsid.c_str(), staPass.c_str());
  retryGap = min<uint32_t>(retryGap * 2, 60000);
  retryAt = millis() + retryGap;
}

void net_poll() {
  retrySta();
  // a station is up once it has an address
  if (readvertise && net_up() && millis() - changedAt > 1500) {
    readvertise = false;
    airplay_readvertise();
  }
  xSemaphoreTake(pendingLock, portMAX_DELAY);
  String j = pending;
  pending = "";
  xSemaphoreGive(pendingLock);
  if (j.isEmpty()) return;
  String m = jsonStr(j, "mode");
  String wasMode = mode, wasSsid = staSsid;
  if (m == "ap" || m == "off") {
    mode = m;
  } else if (m == "sta" && jsonStr(j, "ssid").length()) {
    mode = "sta";
    staSsid = jsonStr(j, "ssid");
    staPass = jsonStr(j, "pass");
    prefs.putString("sta_ssid", staSsid);
    prefs.putString("sta_pass", staPass);
  } else {
    return;  // malformed write: keep the current link
  }
  prefs.putString("mode", mode);
  // Another network (or none): the owner was this phone's address on the old one.
  if (mode != wasMode || staSsid != wasSsid) net_set_owner(0);
  lan_set_station(mode == "sta");
  // Back to the hotspot from a home network: restart, the hotspot as at every boot. Without one no phone found the
  // receiver on it (iPhone 15, 2026-11-17): the mDNS responder announced on the hotspot's interface did not answer,
  // and starting it over right after softAP() crashed the board. The app waits for the board and joins its
  // hotspot after a restart anyway; the stored mode applies at boot.
  if (mode == "ap" && wasMode == "sta") {
    board_log("net: back to the hotspot; restarting");
    delay(300);  // the status and log lines out first
    ESP.restart();
  }
  startWifi();
  changedAt = millis();
  readvertise = mode == "sta";
}

bool net_set_owner(uint32_t ip) {
  if (mode != "sta") ip = 0;
  if (lan_owner() == ip) return false;
  lan_set_owner(ip);
  prefs.putUInt("lan_owner", ip);
  return true;
}

String net_json(bool vtok) {
  bool sta = mode == "sta";
  String j = String("{\"mode\":\"") + mode + "\",\"ssid\":\"" + jsonEsc(sta ? staSsid : apSsid) + "\",\"pass\":\"" +
             jsonEsc(sta ? staPass : apPass) + "\",\"ip\":\"" + net_ip() + "\"";
  return j + (vtok ? ",\"vtok\":\"" + wv_token() + "\"}" : "}");
}

const char *net_mode() {
  if (mode == "sta") return WiFi.status() == WL_CONNECTED ? "sta" : "none";
  return "ap";
}

String net_ip() { return mode == "sta" ? WiFi.localIP().toString() : WiFi.softAPIP().toString(); }
int net_peers() { return mode == "sta" ? WiFi.status() == WL_CONNECTED : WiFi.softAPgetStationNum(); }
bool net_up() { return mode == "sta" ? WiFi.status() == WL_CONNECTED : true; }

uint16_t cfg_width() { return prefs.getUShort("w", 480); }
uint16_t cfg_height() { return prefs.getUShort("h", 1040); }
uint8_t cfg_fps() { return prefs.getUChar("fps", 5); }

void cfg_set_res(uint16_t w, uint16_t h) {
  prefs.putUShort("w", w);
  prefs.putUShort("h", h);
}

void cfg_set_fps(uint8_t fps) { prefs.putUChar("fps", fps); }

void cfg_ed25519_seed(uint8_t seed[32]) {
  if (prefs.getBytes("ed_seed", seed, 32) == 32) return;
  esp_fill_random(seed, 32);
  prefs.putBytes("ed_seed", seed, 32);
}
