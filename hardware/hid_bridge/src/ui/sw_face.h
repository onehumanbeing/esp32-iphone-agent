#pragma once
// The app's character on the StopWatch: a port of ios/Shared/AgentFace.swift (per-mood eyes, blink, breathing,
// looking around, hop / shake on a mood change) and ios/IPhoneAgent/UI/PokeableFace.swift (tap happy, double tap
// wink, 3 quick taps dizzy, long press petting, drag: the eyes follow the finger and the body leans after it).
// SwiftUI springs become damped springs with the same response and damping. Pure C, host tested in
// hardware/tests; stopwatch_ui.cpp feeds the touch and draws the pose. Lengths are app points (the Home face).
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  float x, v, to, k, c;  // value, velocity, target, stiffness, damping (mass 1)
} swf_spring;

enum { SWF_LATER = 6 };  // the app's after(...) follow-ups that may wait at once

typedef struct {
  float px;  // screen pixels per app point
  int8_t mood;
  bool busy;  // a run: a poke only gets a glance
  int8_t override;  // a poke's mood, -1: none
  bool has_gaze;
  float gaze_x, gaze_y;  // -1...1, the finger (or a glance)
  bool down, dragging, petting;
  uint32_t down_at;
  int16_t down_x, down_y;
  uint32_t taps[3];
  uint8_t ntaps;
  uint8_t reset;  // the app's single `reset` task: what it does at reset_at (0: none)
  uint32_t reset_at;
  uint8_t dizzy_step;
  uint32_t pet_at;  // the long press turns into petting then (0: none); while petting, the next soft buzz
  struct { uint32_t at; uint8_t kind, arg; } later[SWF_LATER];
  swf_spring sx, sy, lift, lean_x, lean_y, tilt, hop, shake, look_x, look_y;
  uint8_t haptic;  // ms of a buzz the app's haptics would play now (0: none), taken by swf_haptic
  uint32_t now;
} sw_face;

typedef struct {
  int8_t mood;            // what to draw (a poke's or the real one)
  float gaze_x, gaze_y;   // -1...1, where the open eyes look
  float sx, sy, tilt;     // squish (anchored at the bottom) and tilt in degrees around the bottom
  float dx, dy;           // body offset: lean, lift, hop, shake
  float blink;            // 1 open ... 0.08 closed (idle, listening)
  float breathe, float_y; // idle breathing scale, thinking float
  float t;                // seconds, for spirals, dots and the sleeping z
} swf_pose;

void swf_init(sw_face *f, float px, uint32_t now);
// The real mood (the app's), and whether a run is on; a change reacts as the app does (acting hop, success two
// hops, failure shake) unless a poke is showing. look: the app's lookX / lookY (where the pointer goes).
void swf_mood(sw_face *f, int mood, bool busy, float look_x, float look_y, uint32_t now);
// The finger: called every frame with whether it is down and where (screen pixels; w, h: the screen).
void swf_touch(sw_face *f, bool down, int x, int y, int w, int h, uint32_t now);
void swf_dizzy(sw_face *f, uint32_t now);  // a shake while idle: as three quick taps
void swf_tick(sw_face *f, uint32_t now);   // springs and the app's timers, up to now
void swf_pose_at(const sw_face *f, swf_pose *p);
uint8_t swf_haptic(sw_face *f);            // the pending buzz in ms, then 0

#ifdef __cplusplus
}
#endif
