#include "ima_adpcm.h"
#if !defined(ARDUINO) || defined(M5_STOPWATCH)  // only the StopWatch image carries it

static const int8_t INDEX[16] = {-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8};
static const int16_t STEP[89] = {
    7,     8,     9,     10,    11,    12,    13,    14,    16,    17,    19,    21,    23,    25,    28,
    31,    34,    37,    41,    45,    50,    55,    60,    66,    73,    80,    88,    97,    107,   118,
    130,   143,   157,   173,   190,   209,   230,   253,   279,   307,   337,   371,   408,   449,   494,
    544,   598,   658,   724,   796,   876,   963,   1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
    2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,  5894,  6484,  7132,  7845,  8630,
    9493,  10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767};

static int step(ima_state *s, int code) {  // the decoder's update, shared by both sides
  int st = STEP[s->index], diff = st >> 3;
  if (code & 4) diff += st;
  if (code & 2) diff += st >> 1;
  if (code & 1) diff += st >> 2;
  int p = s->pred + (code & 8 ? -diff : diff);
  s->pred = (int16_t)(p > 32767 ? 32767 : p < -32768 ? -32768 : p);
  int i = s->index + INDEX[code];
  s->index = (uint8_t)(i < 0 ? 0 : i > 88 ? 88 : i);
  return s->pred;
}

static int code(ima_state *s, int sample) {
  int st = STEP[s->index], diff = sample - s->pred, c = 0;
  if (diff < 0) c = 8, diff = -diff;
  if (diff >= st) c |= 4, diff -= st;
  st >>= 1;
  if (diff >= st) c |= 2, diff -= st;
  st >>= 1;
  if (diff >= st) c |= 1;
  step(s, c);
  return c;
}

size_t ima_encode(ima_state *s, const int16_t *pcm, size_t n, uint8_t *out) {
  if (s->index > 88) s->index = 88;
  for (size_t i = 0; i + 1 < n; i += 2) out[i / 2] = (uint8_t)(code(s, pcm[i]) | code(s, pcm[i + 1]) << 4);
  return n / 2;
}

void ima_decode(ima_state *s, const uint8_t *in, size_t bytes, int16_t *out) {
  if (s->index > 88) s->index = 88;
  for (size_t i = 0; i < bytes; i++) {
    out[2 * i] = (int16_t)step(s, in[i] & 15);
    out[2 * i + 1] = (int16_t)step(s, in[i] >> 4);
  }
}
#endif
