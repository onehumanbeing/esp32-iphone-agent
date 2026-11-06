#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// A pointer move cut into reports of one speed. iOS accelerates the pointer by report speed, so a move whose
// reports change speed (x and y capped apart: (10,10) then (0,10), then a small remainder) went a different
// distance than calibration's diagonal moves (2026-11-06). Every report here is the same vector, the rounding
// carried so the sum is exact.
typedef struct {
  long dx, dy, n, i;
} pace_t;

enum { PACE_VERSION = 3 };  // answered by "pace"; 1: x and y capped apart; 2: one speed; 3: + "move dx dy speed"

void pace_start(pace_t *p, long dx, long dy, int step);
int pace_next(pace_t *p, int *sx, int *sy);  // 0 when the move is done

#ifdef __cplusplus
}
#endif
