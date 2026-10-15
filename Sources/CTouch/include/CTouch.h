#ifndef OPENLAUNCH_CTOUCH_H
#define OPENLAUNCH_CTOUCH_H
#include <stdint.h>
#include <stddef.h>
typedef struct { int32_t id; double x, y; } OLTouch;
// Private, unsupported MultitouchSupport ABI; isolated and dynamically loaded.
typedef void (*OLTouchFrameHandler)(void *context);
// Handler must return immediately. It only wakes a persistent coalescing source.
// Clearing is synchronous with in-flight callbacks, so context can then be released.
void OLTouchSetFrameHandler(OLTouchFrameHandler handler, void *context);
int OLTouchStart(void);
void OLTouchStop(void);
int OLTouchDeviceCount(void);
int OLTouchSelectedDeviceIndex(void);
// -1 unknown, 0 external, 1 built-in. Optional private metadata symbols.
int OLTouchSelectedIsBuiltIn(void);
int OLTouchSelectedDimensions(int *width, int *height);
int OLTouchIsSupported(void);
const char *OLTouchStatus(void);
// Oldest ordered frame from a bounded FIFO; no allocation in the driver callback.
// Result bits: 1 frame with active points, 2 release/reset frame, 4 more queued;
// 0 empty queue, -1 malformed input or insufficient capacity.
int OLTouchRead(OLTouch *points, size_t capacity, size_t *count, double *timestamp);
uint64_t OLTouchDroppedFrames(void);
// Opt-in raw diagnostic capture: 512 callback frames, at most 16 points each.
// Includes hover/release states independently of normal recognition filtering.
typedef struct {
 int32_t pathID, fingerID, handID;
 uint32_t state;
 double x, y;
} OLCapturePoint;
void OLCaptureStart(void);
void OLCaptureStop(void);
// 1 frame consumed, 0 empty, -1 invalid/capacity insufficient (frame retained).
// count is the bounded copy count; originalCount is the untouched callback count.
int OLCaptureRead(OLCapturePoint *points, size_t capacity, size_t *count,
                  double *timestamp, uint64_t *frameNumber, size_t *originalCount);
uint64_t OLCaptureDropped(void);
// Public IOKit parameter API, restricted to four/five-finger Launchpad switches.
int OLSystemPinchGet(int fingers);
int OLSystemPinchSet(int fingers, int value);
#endif
