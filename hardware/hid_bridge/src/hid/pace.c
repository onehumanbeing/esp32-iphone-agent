#include "pace.h"

#include <math.h>

void pace_start(pace_t *p, long dx, long dy, int step) {
  double len = hypot((double)dx, (double)dy);
  p->dx = dx;
  p->dy = dy;
  p->i = 0;
  p->n = len > 0 ? (long)ceil(len / step) : 0;
}

static long upto(long total, long i, long n) { return lround((double)total * i / n); }

int pace_next(pace_t *p, int *sx, int *sy) {
  if (p->i >= p->n) return 0;
  long i = p->i++;
  *sx = (int)(upto(p->dx, i + 1, p->n) - upto(p->dx, i, p->n));
  *sy = (int)(upto(p->dy, i + 1, p->n) - upto(p->dy, i, p->n));
  return 1;
}
