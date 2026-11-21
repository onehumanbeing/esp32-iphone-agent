#pragma once
// The StopWatch's screen power, without the hardware: on while something happens, dim after SWP_DIM_MS and off after
// SWP_OFF_MS of nothing (no run), back on with a press, a touch, an app event or the wrist raised (the IMU's gravity
// turning). Pure C, host tested.
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { SWP_ON, SWP_DIM, SWP_OFF };
enum {
  SWP_DIM_MS = 20000,  // nothing happening this long (no run): dim (Henry 2026-11-21)
  SWP_OFF_MS = 60000,  // ... and this long: the screen goes off
};

typedef struct {
  uint32_t active_at;
  float fast[3], slow[3];  // gravity, smoothed fast and slow (g)
  bool primed;
  uint32_t raised_at;
  int warned;  // the battery threshold last warned at (0: none)
} sw_power;

void swp_init(sw_power *p, uint32_t now);
void swp_active(sw_power *p, uint32_t now);  // a press, touch, app event: on from now
// One accelerometer sample (g, about every 33 ms). True: the wrist turned the screen up (and it counts as active).
bool swp_motion(sw_power *p, float ax, float ay, float az, uint32_t now);
enum { SWP_LOW = 15, SWP_EMPTY = 5 };  // battery %: a warning when it falls under each (not while charging)
int swp_battery(sw_power *p, int level, bool charging);  // the threshold just crossed, or 0
int swp_level(const sw_power *p, uint32_t now, bool keep_on);  // keep_on: a run, help, voice: always SWP_ON

#ifdef __cplusplus
}
#endif
