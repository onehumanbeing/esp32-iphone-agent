#ifdef M5_STOPWATCH
// The StopWatch's character, drawn: AgentFace's eyes in every mood, with the soft glow (the pose is sw_face.c's).
#include "stopwatch_draw.h"

struct Xf {
  float cx, cy, a, sx, sy, cs, sn, dx, dy, br;
  void at(float x, float y, float &ox, float &oy) const {
    x *= br, y *= br;
    float X = x * sx, Y = (y - a) * sy;
    ox = cx + dx + X * cs - Y * sn;
    oy = cy + dy + a + X * sn + Y * cs;
  }
  float scale() const { return br * (sx + sy) / 2; }
};

static Xf xf;
static uint16_t ink;        // the eyes' colour
static bool glowOn;         // the soft glow around the eyes (on black only)
bool measuring;            // only find what the face will cover (bx0...), draw nothing
float bx0, by0, bx1, by1;        // what this frame's face covered, for the partial push

static void cover(float x0, float y0, float x1, float y1) {
  bx0 = fminf(bx0, x0), by0 = fminf(by0, y0), bx1 = fmaxf(bx1, x1), by1 = fmaxf(by1, y1);
}

uint16_t scaled(uint16_t c, float k) {  // a colour dimmed toward black
  uint8_t r = (c >> 11) * 255 / 31, g = ((c >> 5) & 63) * 255 / 63, b = (c & 31) * 255 / 31;
  return lgfx::color565(r * k, g * k, b * k);
}

// AgentFace's glow is a shadow of radius 0.05 s: two dim halos, then the shape.
static const float GLOW1 = 0.045f * FACE_S, GLOW2 = 0.022f * FACE_S;

static void capsule(float x, float y, float w, float h, uint16_t c) {
  float ox, oy;
  xf.at(x, y, ox, oy);
  w *= xf.sx * xf.br, h *= xf.sy * xf.br;
  for (int pass = measuring ? 3 : glowOn ? 0 : 2; pass < 3; pass++) {
    float g = pass == 0 ? GLOW1 : pass == 1 ? GLOW2 : 0;
    float ww = w + 2 * g, hh = h + 2 * g;
    uint16_t col = pass == 0 ? scaled(c, 0.10f) : pass == 1 ? scaled(c, 0.24f) : c;
    canvas->fillSmoothRoundRect(lroundf(ox - ww / 2), lroundf(oy - hh / 2), lroundf(ww), lroundf(hh),
                                lroundf(fminf(ww, hh) / 2), col);
  }
  float g = glowOn ? GLOW1 : 0;
  cover(ox - w / 2 - g, oy - h / 2 - g, ox + w / 2 + g, oy + h / 2 + g);
}

// A stroked path with round caps and joins, in face coordinates.
static void stroke(const float *pts, int n, float width, uint16_t c) {
  static float sx[64], sy[64];
  n = n > 64 ? 64 : n;
  for (int i = 0; i < n; i++) xf.at(pts[2 * i], pts[2 * i + 1], sx[i], sy[i]);
  float r = width / 2 * xf.scale();
  for (int pass = measuring ? 3 : glowOn ? 0 : 2; pass < 3; pass++) {
    float g = pass == 0 ? GLOW1 : pass == 1 ? GLOW2 : 0;
    uint16_t col = pass == 0 ? scaled(c, 0.10f) : pass == 1 ? scaled(c, 0.24f) : c;
    for (int i = 0; i + 1 < n; i++) canvas->drawWideLine(sx[i], sy[i], sx[i + 1], sy[i + 1], r + g, col);
  }
  float g = r + (glowOn ? GLOW1 : 0);
  for (int i = 0; i < n; i++) cover(sx[i] - g, sy[i] - g, sx[i] + g, sy[i] + g);
}

static void caret(float x, float y, float w, float h, float width, uint16_t c) {  // "^"
  const float p[] = {x - w / 2, y + h / 2, x, y - h / 2, x + w / 2, y + h / 2};
  stroke(p, 3, width, c);
}

static void smile(float x, float y, float w, float h, float width, uint16_t c) {  // "‿", the quad curve of Smile
  float p[2 * 13];
  for (int i = 0; i <= 12; i++) {
    float t = i / 12.0f, top = y - h / 2, ctl = y + h / 2 * 3;  // control at maxY·2 − minY
    p[2 * i] = x - w / 2 + w * t;
    p[2 * i + 1] = (1 - t) * (1 - t) * top + 2 * (1 - t) * t * ctl + t * t * top;
  }
  stroke(p, 13, width, c);
}

static void spiral(float x, float y, float size, float turn, float width, uint16_t c) {
  float p[2 * 61];
  for (int i = 0; i <= 60; i++) {
    float a = i / 60.0f * 2.6f * 2 * PI + turn, rad = size / 2 * i / 60;
    p[2 * i] = x + rad * cosf(a), p[2 * i + 1] = y + rad * sinf(a);
  }
  stroke(p, 61, width, c);
}

static void cross(float x, float y, float size, float width, uint16_t c) {  // "×"
  const float a[] = {x - size / 2, y - size / 2, x + size / 2, y + size / 2};
  const float b[] = {x + size / 2, y - size / 2, x - size / 2, y + size / 2};
  stroke(a, 2, width, c), stroke(b, 2, width, c);
}

// Where the last full frame put the face: a frame where only the face moved redraws just around it.
FacePlace place;

// The face of AgentFace.moodEyes at (cx, cy), from a pose. crossed: the island's stuck "×" eyes.
void face(const swf_pose &p, int cx, int cy, uint16_t color, bool glow, bool crossed) {
  if (!measuring) place = {true, cx, cy, color, glow, crossed};
  const float s = FACE_S, w = s * 0.14f, h = s * 0.25f, gap = s * 0.37f;
  float tilt = p.tilt * PI / 180;
  xf = {(float)cx, (float)cy, s * 0.62f, p.sx, p.sy, cosf(tilt), sinf(tilt), p.dx * PX, (p.dy + p.float_y) * PX,
        p.breathe};
  ink = color, glowOn = glow;
  const uint16_t c = ink;
  if (crossed) {
    for (int i = -1; i <= 1; i += 2) cross(i * gap / 2, -s * 0.02f, w * 1.5f, s * 0.055f, c);
    return;
  }
  switch (p.mood) {
    case SW_SLEEPING: {
      glowOn = false;
      uint16_t dim = scaled(c, 0.55f);
      for (int i = -1; i <= 1; i += 2) capsule(i * gap / 2, s * 0.05f, w, s * 0.025f, dim);
      float k = fmodf(p.t, 3) / 3, ox, oy;  // the z drifts up and fades
      xf.at(s * 0.24f + k * s * 0.08f, -s * 0.18f - k * s * 0.12f, ox, oy);
      if (!measuring) {
        canvas->setFont(&fonts::FreeSansBold18pt7b);
        canvas->setTextSize(1);
        canvas->setTextColor(scaled(c, 1 - k));
        canvas->drawString("z", ox, oy);
      }
      cover(ox - 20, oy - 24, ox + 20, oy + 24);
      break;
    }
    case SW_SUCCESS:
      for (int i = -1; i <= 1; i += 2) caret(i * (gap + 0.3f * w) / 2, -s * 0.02f, w * 1.3f, h * 0.45f, s * 0.05f, c);
      break;
    case SW_DIZZY:
      for (int i = -1; i <= 1; i += 2) spiral(i * (gap + 0.3f * w) / 2, 0, w * 1.7f, -i * p.t * 9, s * 0.03f, c);
      break;
    case SW_CONTENT:
      for (int i = -1; i <= 1; i += 2) smile(i * gap / 2, s * 0.04f, w * 1.3f, h * 0.28f, s * 0.045f, c);
      break;
    case SW_WINK:
      capsule(-gap / 2 - 0.075f * w, -s * 0.02f, w, h, c);
      caret(gap / 2 - 0.075f * w, -s * 0.02f, w * 1.3f, h * 0.35f, s * 0.05f, c);
      break;
    case SW_FAILURE:  // bottom-aligned, one eye smaller: sad
      capsule(-gap / 2 + 0.1f * w, s * 0.05f, w * 1.1f, h * 0.85f, c);
      capsule(gap / 2 + 0.05f * w, s * 0.05f + 0.15f * h, w * 0.8f, h * 0.55f, c);
      break;
    default: {
      float k = p.mood == SW_LISTENING ? 1.15f : 1;
      float dx = p.gaze_x * s * 0.05f * LOOK_RANGE, dy = p.gaze_y * s * 0.04f * LOOK_RANGE - s * 0.02f;
      for (int i = -1; i <= 1; i += 2) {
        float bob = p.mood == SW_THINKING ? i * s * 0.02f * sinf(p.t * 2.4f) : 0;
        capsule(i * (gap - w + w * k) / 2 + dx, dy + bob, w * k, h * k * p.blink, c);
      }
    }
  }
}

// What is on screen besides the face's motion; a change redraws everything.
#endif
