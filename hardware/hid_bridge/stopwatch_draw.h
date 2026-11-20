// M5Stack StopWatch: the character's drawing (stopwatch_draw.cpp), shared with the screen task (stopwatch_ui.cpp).
#pragma once
#ifdef M5_STOPWATCH
#include <M5Unified.h>
#include "src/ui/sw_face.h"
#include "src/ui/sw_model.h"

extern M5Canvas *canvas;  // the whole screen, in PSRAM
static const float FACE_S = 330;       // the face's size `s` in AgentFace, in pixels
static const float PX = FACE_S / 128;  // pixels per app point: the Home face is 128 points wide
static const float LOOK_RANGE = 1.6f;  // how far the eyes travel (Home 1, the tiny island 2.4)

extern bool measuring;               // only find what the face will cover (bx0...), draw nothing
extern float bx0, by0, bx1, by1;     // what this frame's face covered, for the partial push
struct FacePlace {
  bool on;
  int cx, cy;
  uint16_t color;
  bool glow, crossed;
};
extern FacePlace place;  // where the last face went, to redraw only it

uint16_t scaled(uint16_t c, float k);  // a colour dimmed toward black
void face(const swf_pose &p, int cx, int cy, uint16_t color, bool glow, bool crossed = false);
#endif
