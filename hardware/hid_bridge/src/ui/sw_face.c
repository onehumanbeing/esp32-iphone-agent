#include "sw_face.h"
#if !defined(ARDUINO) || defined(M5_STOPWATCH)  // only the StopWatch image carries it
#include <math.h>
#include <string.h>
#include "sw_model.h"

// Haptics as vibration, in ms: UIImpactFeedbackGenerator light / medium / rigid / soft, and the selection tick.
enum { BUZZ_LIGHT = 14, BUZZ_MEDIUM = 22, BUZZ_RIGID = 30, BUZZ_SOFT = 10, BUZZ_TICK = 8 };
enum { R_NONE, R_SETTLE, R_GLANCE, R_DIZZY };  // what the app's `reset` task does when it wakes
enum { L_NONE, L_SQUASH_UP, L_LIFT_DOWN, L_WINK_DOWN, L_HOP_UP, L_HOP_DOWN, L_SHAKE_BACK };
static const float PI_F = 3.14159265f;

// SwiftUI's .spring(response:dampingFraction:) with mass 1: stiffness (2π/response)², damping 4π·fraction/response.
static void to(swf_spring *s, float target, float response, float damping) {
  s->to = target;
  s->k = (2 * PI_F / response) * (2 * PI_F / response);
  s->c = 4 * PI_F * damping / response;
}

static void set(swf_spring *s, float v) { s->x = s->to = v, s->v = 0; }  // no animation (a drag follows the finger)

static void step(swf_spring *s, float dt) {
  if (s->k <= 0) return;
  s->v += (-s->k * (s->x - s->to) - s->c * s->v) * dt;  // semi-implicit Euler, stable for dt·ω < 2
  s->x += s->v * dt;
  if (fabsf(s->x - s->to) < 1e-4f && fabsf(s->v) < 1e-3f) s->x = s->to, s->v = 0;
}

static swf_spring *springs(sw_face *f, int *n) {
  *n = 10;
  return &f->sx;  // sx ... look_y are consecutive
}

static void advance(sw_face *f, uint32_t until) {
  int n;
  swf_spring *s = springs(f, &n);
  while ((int32_t)(until - f->now) > 0) {
    uint32_t d = until - f->now > 4 ? 4 : until - f->now;  // 4 ms steps: the stiffest spring (0.09 s) stays stable
    for (int i = 0; i < n; i++) step(&s[i], d / 1000.0f);
    f->now += d;
  }
}

static void later(sw_face *f, uint32_t ms, uint8_t kind, uint8_t arg) {
  for (int i = 0; i < SWF_LATER; i++)
    if (!f->later[i].kind) {
      f->later[i].at = f->now + ms, f->later[i].kind = kind, f->later[i].arg = arg;
      return;
    }
}

static void buzz(sw_face *f, uint8_t ms) {
  if (ms > f->haptic) f->haptic = ms;
}

static void reset(sw_face *f, uint8_t what, uint32_t ms) { f->reset = what, f->reset_at = f->now + ms; }

void swf_init(sw_face *f, float px, uint32_t now) {
  memset(f, 0, sizeof *f);
  f->px = px;
  f->mood = SW_SLEEPING;
  f->override = -1;
  f->now = now;
  int n;
  swf_spring *s = springs(f, &n);
  for (int i = 0; i < n; i++) to(&s[i], 0, 0.3f, 1);
  set(&f->sx, 1), set(&f->sy, 1);
}

static void jump(sw_face *f, int times) {
  for (int i = 0; i < times; i++) later(f, i * 320, L_HOP_UP, 0);
}

void swf_mood(sw_face *f, int mood, bool busy, float look_x, float look_y, uint32_t now) {
  swf_tick(f, now);
  f->busy = busy;
  to(&f->look_x, look_x, 0.3f, 1), to(&f->look_y, look_y, 0.3f, 1);  // the island eases a new look in 0.3 s
  if (mood == f->mood) return;
  f->mood = (int8_t)mood;
  if (f->override >= 0) return;  // AgentFace(reacts: override == nil)
  if (mood == SW_ACTING) jump(f, 1);
  else if (mood == SW_SUCCESS) jump(f, 2);
  else if (mood == SW_FAILURE) to(&f->shake, 6, 0.12f, 0.2f), later(f, 150, L_SHAKE_BACK, 0);
}

static void settle(sw_face *f, uint32_t ms) { reset(f, R_SETTLE, ms); }

static void squash(sw_face *f, float depth) {
  to(&f->sx, 1 + depth * 0.6f, 0.12f, 0.7f), to(&f->sy, 1 - depth, 0.12f, 0.7f);
  later(f, 120, L_SQUASH_UP, 0);
}

static void dizzy(sw_face *f) {
  f->ntaps = 0;
  buzz(f, BUZZ_RIGID);
  f->override = SW_DIZZY;
  to(&f->tilt, 8, 0.3f, 0.4f);
  f->dizzy_step = 0;
  reset(f, R_DIZZY, 1300);
}

static void tapped(sw_face *f) {
  if (f->busy) {  // glance: look up at the finger for a moment
    buzz(f, BUZZ_TICK);
    f->has_gaze = true, f->gaze_x = 0, f->gaze_y = -0.8f;
    return reset(f, R_GLANCE, 600);
  }
  uint8_t n = 0;  // taps in the last 1.2 s, then this one
  for (int i = 0; i < f->ntaps; i++)
    if (f->now - f->taps[i] < 1200) f->taps[n++] = f->taps[i];
  if (n == 3) memmove(f->taps, f->taps + 1, 2 * sizeof f->taps[0]), n = 2;
  f->taps[n++] = f->now;
  f->ntaps = n;
  if (n >= 3) return dizzy(f);
  if (n == 2 && f->now - f->taps[0] < 350) {  // jump and wink
    buzz(f, BUZZ_MEDIUM);
    f->override = SW_WINK;
    to(&f->lift, -26, 0.22f, 0.6f), to(&f->sx, 0.94f, 0.22f, 0.6f), to(&f->sy, 1.08f, 0.22f, 0.6f);
    later(f, 200, L_WINK_DOWN, 0);
    return settle(f, 800);
  }
  buzz(f, BUZZ_LIGHT);
  f->override = SW_SUCCESS;
  squash(f, 0.18f);
  settle(f, 700);
}

static float clampf(float v, float lo, float hi) { return v < lo ? lo : v > hi ? hi : v; }

void swf_touch(sw_face *f, bool down, int x, int y, int w, int h, uint32_t now) {
  swf_tick(f, now);
  if (down && !f->down) {  // began
    f->down = true, f->dragging = f->petting = false;
    f->down_at = now, f->down_x = (int16_t)x, f->down_y = (int16_t)y;
    f->pet_at = f->busy ? 0 : now + 400;  // held still this long: petting
  }
  if (down) {
    float tx = (x - f->down_x) / f->px, ty = (y - f->down_y) / f->px;  // the translation, in points
    if (sqrtf(tx * tx + ty * ty) > 8 && !f->petting) f->dragging = true, f->pet_at = 0;
    if (f->dragging) {  // follow: the eyes look at the finger, the body leans a little after it (rubber band)
      f->has_gaze = true;
      f->gaze_x = clampf((float)x / (w > 1 ? w : 1) * 2 - 1, -1, 1);
      f->gaze_y = clampf((float)y / (h > 1 ? h : 1) * 2 - 1, -1, 1);
      if (!f->busy) {
        if (f->override < 0) f->override = SW_LISTENING;
        set(&f->lean_x, clampf(tx * 0.18f, -22, 22)), set(&f->lean_y, clampf(ty * 0.18f, -22, 22));
        set(&f->tilt, f->lean_x.x * 0.35f);
      }
    }
    return;
  }
  if (!f->down) return;
  f->down = false;  // ended
  f->pet_at = 0;
  uint32_t held = now - f->down_at;
  if (f->petting || f->dragging) {
    bool was_dragging = f->dragging;
    f->petting = f->dragging = false;
    settle(f, was_dragging ? 0 : 350);
    to(&f->lean_x, 0, 0.45f, 0.55f), to(&f->lean_y, 0, 0.45f, 0.55f), to(&f->tilt, 0, 0.45f, 0.55f);
    to(&f->sx, 1, 0.45f, 0.55f), to(&f->sy, 1, 0.45f, 0.55f);
    if (!f->busy) buzz(f, BUZZ_LIGHT);
    return;
  }
  if (held < 400) tapped(f);
  else settle(f, 0);
}

void swf_dizzy(sw_face *f, uint32_t now) {
  swf_tick(f, now);
  if (!f->busy && f->override != SW_DIZZY) dizzy(f);
}

static void run_later(sw_face *f, uint8_t kind, uint8_t arg) {
  (void)arg;
  switch (kind) {
    case L_SQUASH_UP:
      to(&f->sx, 1, 0.45f, 0.45f), to(&f->sy, 1, 0.45f, 0.45f), to(&f->lift, -8, 0.45f, 0.45f);
      later(f, 150, L_LIFT_DOWN, 0);
      break;
    case L_LIFT_DOWN: to(&f->lift, 0, 0.35f, 0.6f); break;
    case L_WINK_DOWN: to(&f->lift, 0, 0.38f, 0.55f), to(&f->sx, 1, 0.38f, 0.55f), to(&f->sy, 1, 0.38f, 0.55f); break;
    case L_HOP_UP: to(&f->hop, -14, 0.16f, 0.6f), later(f, 140, L_HOP_DOWN, 0); break;
    case L_HOP_DOWN: to(&f->hop, 0, 0.3f, 0.55f); break;
    case L_SHAKE_BACK: to(&f->shake, 0, 0.35f, 0.4f); break;
  }
}

static const float SHAKE_OFF[] = {-10, 9, -6, 4, 0};  // the dizzy face shakes it off

static void run_reset(sw_face *f) {
  uint8_t what = f->reset;
  f->reset = R_NONE;
  switch (what) {
    case R_SETTLE: f->override = -1, f->has_gaze = false; break;
    case R_GLANCE: f->has_gaze = false; break;
    case R_DIZZY:
      if (f->dizzy_step == 0) f->override = SW_IDLE, buzz(f, BUZZ_LIGHT);
      if (f->dizzy_step < 5) {
        float x = SHAKE_OFF[f->dizzy_step++];
        to(&f->tilt, x / 2, 0.09f, 0.4f), to(&f->lean_x, x, 0.09f, 0.4f);
        reset(f, R_DIZZY, 80);
      } else if (f->dizzy_step == 5) {
        f->dizzy_step++;
        set(&f->tilt, 0), set(&f->lean_x, 0), set(&f->lean_y, 0);
        reset(f, R_DIZZY, 300);
      } else {
        f->override = -1;
      }
      break;
  }
}

void swf_tick(sw_face *f, uint32_t now) {
  for (;;) {  // the app's timers in the order they come due, the springs moving in between
    uint32_t at = now;
    int which = -2;  // -1: reset, -3: pet, >= 0: later[i]
    if (f->reset && (int32_t)(f->reset_at - at) <= 0) at = f->reset_at, which = -1;
    if (f->pet_at && (int32_t)(f->pet_at - at) <= 0) at = f->pet_at, which = -3;
    for (int i = 0; i < SWF_LATER; i++)
      if (f->later[i].kind && (int32_t)(f->later[i].at - at) <= 0) at = f->later[i].at, which = i;
    if (which == -2) break;
    if ((int32_t)(at - f->now) > 0) advance(f, at);
    if (which == -1) {
      run_reset(f);
    } else if (which == -3) {
      f->pet_at = 0;
      if (f->down && !f->dragging && !f->busy) {
        if (!f->petting) {  // leans into the finger, eyes close contentedly
          f->petting = true;
          f->reset = R_NONE;
          f->override = SW_CONTENT;
          to(&f->sx, 1.06f, 0.5f, 0.6f), to(&f->sy, 0.95f, 0.5f, 0.6f), to(&f->tilt, 4, 0.5f, 0.6f);
        }
        buzz(f, BUZZ_SOFT);
        f->pet_at = f->now + 650;
      }
    } else {
      uint8_t kind = f->later[which].kind, arg = f->later[which].arg;
      f->later[which].kind = L_NONE;
      run_later(f, kind, arg);
    }
  }
  advance(f, now);
}

void swf_pose_at(const sw_face *f, swf_pose *p) {
  memset(p, 0, sizeof *p);
  float t = f->now / 1000.0f;
  int mood = f->override >= 0 ? f->override : f->mood;
  p->mood = (int8_t)mood;
  p->t = t;
  if (f->has_gaze) {
    p->gaze_x = f->gaze_x, p->gaze_y = f->gaze_y;
  } else if (mood == SW_ACTING) {
    p->gaze_x = f->look_x.x, p->gaze_y = f->look_y.x;
  } else if (mood == SW_LISTENING) {
    p->gaze_y = 0.6f;
  } else if (mood == SW_THINKING) {
    p->gaze_x = sinf(t * 2.4f), p->gaze_y = -0.2f;
  } else if (mood == SW_IDLE) {  // a look around now and then
    float c = fmodf(t, 9);
    p->gaze_x = c > 6 && c < 7 ? -0.7f : c > 7.4f && c < 8.2f ? 0.7f : 0;
  }
  p->blink = 1;
  if (mood == SW_IDLE || mood == SW_LISTENING) {
    float c = fmodf(t, 4.3f);
    if (c < 0.13f) p->blink = fmaxf(0.08f, fabsf(c - 0.065f) / 0.065f);
  }
  p->breathe = mood == SW_IDLE ? 1 + 0.012f * sinf(t * 1.6f) : 1;
  p->float_y = mood == SW_THINKING ? 3 * sinf(t * 2.4f) : 0;
  p->sx = f->sx.x, p->sy = f->sy.x, p->tilt = f->tilt.x;
  p->dx = f->lean_x.x + f->shake.x;
  p->dy = f->lift.x + f->lean_y.x + f->hop.x;
}

uint8_t swf_haptic(sw_face *f) {
  uint8_t ms = f->haptic;
  f->haptic = 0;
  return ms;
}

void swf_poke(sw_face *f, uint32_t now) {  // a button press while idle: the same reaction as a tap
  advance(f, now);
  tapped(f);
}
#endif
