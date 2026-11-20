#ifdef HID_DUAL
#include "hid_mode.h"
#include <Preferences.h>

static bool bleMode, changed;

void hid_mode_load() {
  Preferences p;
  p.begin("hid", false);
  bleMode = p.getBool("ble", false);  // a board that never chose: USB, as the standard firmware
  changed = p.getBool("changed", false);
  if (changed) p.putBool("changed", false);
  p.end();
}

bool hid_ble() { return bleMode; }
bool hid_mode_changed() { return changed; }

bool hid_mode_save(bool ble) {
  Preferences p;
  if (!p.begin("hid", false)) return false;
  bool ok = p.putBool("ble", ble) == 1;
  if (ok && ble != bleMode) p.putBool("changed", true);
  p.end();
  return ok;
}
#endif
