#include "sw_power.h"
#if !defined(ARDUINO) || defined(M5_STOPWATCH)  // only the StopWatch image carries it
#include <math.h>

static const float FAST = 0.35f, SLOW = 0.03f;  // per sample: ~0.1 s and ~1 s
static const float RAISE_COS = 0.82f;           // the fast gravity 35 degrees or more off the slow one: a turn
static const uint32_t RAISE_GAP_MS = 1500;      // one raise per this

void swp_init(sw_power *p, uint32_t now) {
  *p = (sw_power){0};
  p->active_at = now;
}

void swp_active(sw_power *p, uint32_t now) { p->active_at = now; }

bool swp_motion(sw_power *p, float ax, float ay, float az, uint32_t now) {
  float a[3] = {ax, ay, az}, m = sqrtf(ax * ax + ay * ay + az * az);
  if (m < 0.5f || m > 1.6f) return false;  // free fall or a shake: no gravity to read
  if (!p->primed) {
    for (int i = 0; i < 3; i++) p->fast[i] = p->slow[i] = a[i] / m;
    p->primed = true;
    return false;
  }
  float dot = 0, nf = 0, ns = 0;
  for (int i = 0; i < 3; i++) {
    p->fast[i] += FAST * (a[i] / m - p->fast[i]);
    p->slow[i] += SLOW * (a[i] / m - p->slow[i]);
    dot += p->fast[i] * p->slow[i], nf += p->fast[i] * p->fast[i], ns += p->slow[i] * p->slow[i];
  }
  if (dot / sqrtf(nf * ns) > RAISE_COS || now - p->raised_at < RAISE_GAP_MS) return false;
  p->raised_at = now;
  for (int i = 0; i < 3; i++) p->slow[i] = p->fast[i];  // the new way up is the rest from here
  p->active_at = now;
  return true;
}

int swp_battery(sw_power *p, int level, bool charging) {
  if (level < 0 || level > 100) return 0;
  if (p->warned && level >= p->warned + 3) p->warned = level < SWP_LOW ? SWP_LOW : 0;  // charged back up: again later
  int under = level < SWP_EMPTY ? SWP_EMPTY : level < SWP_LOW ? SWP_LOW : 0;
  if (charging || !under || (p->warned && under >= p->warned)) return 0;
  return p->warned = under;
}

int swp_level(const sw_power *p, uint32_t now, bool keep_on) {
  if (keep_on) return SWP_ON;
  uint32_t idle = now - p->active_at;
  return idle >= SWP_OFF_MS ? SWP_OFF : idle >= SWP_DIM_MS ? SWP_DIM : SWP_ON;
}
#endif
