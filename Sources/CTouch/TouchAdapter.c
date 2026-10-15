#include "CTouch.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <math.h>
#include <string.h>
#include <stdbool.h>
#include <time.h>
// Field offsets derived from the documented reverse-engineered ABI at
// https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h
// This is a private Apple API and may change on any OS update.
typedef struct { float x,y; } OLRawPoint;
typedef struct { OLRawPoint position,velocity; } Vector;
typedef struct {
 int32_t frame; double timestamp; int32_t pathIndex; uint32_t state;
 int32_t fingerID,handID; Vector normalizedVector; float zTotal;
 int32_t field9; float angle,majorAxis,minorAxis; Vector absoluteVector;
 int32_t field14,field15; float zDensity;
} RawTouch;
typedef void (*FrameCallback)(CFTypeRef,RawTouch*,size_t,double,size_t);
static void *framework;
static CFArrayRef devices;
static CFArrayRef (*createList)(void);
static void (*registerFrame)(CFTypeRef,FrameCallback);
static void (*unregisterFrame)(CFTypeRef,FrameCallback);
static int32_t (*startDevice)(CFTypeRef,int);
static int32_t (*stopDevice)(CFTypeRef);
static bool (*deviceIsBuiltIn)(CFTypeRef);
static int32_t (*sensorDimensions)(CFTypeRef,int*,int*);
static int selectedIndex=-1,selectedBuiltIn=-1,selectedWidth,selectedHeight;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
#define OL_TOUCH_FRAME_CAPACITY 1024
typedef struct { OLTouch points[16]; size_t count; double timestamp; int reset; } TouchFrame;
static TouchFrame touchFrames[OL_TOUCH_FRAME_CAPACITY];
static size_t touchHead,touchCount;
static uint64_t touchDropped;
static int touchDroppedPendingReset;
static int activeTouchCount,running,fault,deviceCount,supported;
static const char *status = "not started";
#define OL_CAPTURE_FRAME_CAPACITY 512
#define OL_CAPTURE_POINT_CAPACITY 16
// BSS storage is never written by callbacks unless explicitly enabled. There is
// no allocation, file I/O or extra dispatch in the raw capture path.
typedef struct {
 OLCapturePoint points[OL_CAPTURE_POINT_CAPACITY];
 size_t count,originalCount;
 double timestamp;
 uint64_t frameNumber;
} CaptureFrame;
static CaptureFrame captureFrames[OL_CAPTURE_FRAME_CAPACITY];
static size_t captureHead,captureCount;
static uint64_t captureDropped;
static bool captureEnabled;
void OLCaptureStart(void) {
 pthread_mutex_lock(&lock);
 memset(captureFrames,0,sizeof(captureFrames));
 captureHead=0;captureCount=0;captureDropped=0;captureEnabled=true;
 pthread_mutex_unlock(&lock);
}
void OLCaptureStop(void) {
 pthread_mutex_lock(&lock);captureEnabled=false;pthread_mutex_unlock(&lock);
}
uint64_t OLCaptureDropped(void) {
 pthread_mutex_lock(&lock);uint64_t result=captureDropped;pthread_mutex_unlock(&lock);return result;
}
int OLCaptureRead(OLCapturePoint *points,size_t capacity,size_t *count,double *timestamp,uint64_t *frameNumber,size_t *originalCount) {
 if(!count||!timestamp||!frameNumber||!originalCount) return -1;
 pthread_mutex_lock(&lock);
 if(!captureCount) {pthread_mutex_unlock(&lock);return 0;}
 CaptureFrame *entry=&captureFrames[captureHead];
 if(capacity<entry->count || (!points && entry->count)) {pthread_mutex_unlock(&lock);return -1;}
 if(entry->count) memcpy(points,entry->points,entry->count*sizeof(OLCapturePoint));
 *count=entry->count;*timestamp=entry->timestamp;*frameNumber=entry->frameNumber;*originalCount=entry->originalCount;
 memset(entry,0,sizeof(*entry));
 captureHead=(captureHead+1)%OL_CAPTURE_FRAME_CAPACITY;captureCount--;
 pthread_mutex_unlock(&lock);return 1;
}
// Caller holds lock and has already matched the currently selected device.
static void captureRawFrame(const RawTouch *touches,size_t count,double timestamp,size_t number) {
 if(!captureEnabled) return;
 if(captureCount==OL_CAPTURE_FRAME_CAPACITY) {
  captureHead=(captureHead+1)%OL_CAPTURE_FRAME_CAPACITY;captureCount--;captureDropped++;
 }
 size_t index=(captureHead+captureCount)%OL_CAPTURE_FRAME_CAPACITY;
 CaptureFrame *entry=&captureFrames[index];
 entry->count=touches?(count<OL_CAPTURE_POINT_CAPACITY?count:OL_CAPTURE_POINT_CAPACITY):0;
 entry->originalCount=count;entry->timestamp=timestamp;entry->frameNumber=(uint64_t)number;
 for(size_t i=0;i<entry->count;i++) {
  const RawTouch *point=&touches[i];
  entry->points[i]=(OLCapturePoint){point->pathIndex,point->fingerID,point->handID,point->state,
   point->normalizedVector.position.x,point->normalizedVector.position.y};
 }
 captureCount++;
}
static OLTouchFrameHandler frameHandler;
static void *frameContext;
void OLTouchSetFrameHandler(OLTouchFrameHandler handler, void *context) {
 pthread_mutex_lock(&lock);
 frameHandler=handler;frameContext=context;
 if(handler && (touchCount || fault)) handler(context);
 pthread_mutex_unlock(&lock);
}
static void setStatus(const char *message) {pthread_mutex_lock(&lock);status=message;pthread_mutex_unlock(&lock);}
static void frame(CFTypeRef device,RawTouch *touches,size_t count,double timestamp,size_t number) {
 OLTouch points[16]; size_t n=0;
 int invalid=count>16 || (!touches && count>0) || !isfinite(timestamp);
 for(size_t i=0; !invalid && i<count; i++) {
  RawTouch t=touches[i];
  if(t.state>7) {invalid=1;break;}
  if(t.state!=3 && t.state!=4) continue;
  double x=t.normalizedVector.position.x,y=t.normalizedVector.position.y;
  if(!isfinite(x)||!isfinite(y)||x<0||x>1||y<0||y>1) {invalid=1;break;}
  // Real macOS 27 callback captures show fingerID collisions between distinct
  // simultaneous paths. pathIndex remains unique and stable across adjacent
  // five-contact frames, so use that as the frame-local contact identity.
  for(size_t j=0;j<n;j++) if(points[j].id==t.pathIndex) invalid=1;
  points[n++]=(OLTouch){t.pathIndex,x,y};
 }
 pthread_mutex_lock(&lock);
 // Start a single surface: concurrent devices must never mix finger identities.
 if(running && devices && selectedIndex>=0 && device==CFArrayGetValueAtIndex(devices,selectedIndex)) {
  captureRawFrame(touches,count,timestamp,number);
  if(!fault) {
   if(invalid) {fault=1;status="malformed private touch frame; disabled";}
   else if(n>0 || activeTouchCount>0) {
    if(touchCount==OL_TOUCH_FRAME_CAPACITY) {
     touchDropped+=touchCount;touchHead=0;touchCount=0;touchDroppedPendingReset=1;
    }
    size_t index=(touchHead+touchCount)%OL_TOUCH_FRAME_CAPACITY;
    TouchFrame *entry=&touchFrames[index];memset(entry,0,sizeof(*entry));
    if(n) memcpy(entry->points,points,n*sizeof(OLTouch));
    entry->count=n;entry->timestamp=timestamp;entry->reset=(n==0)||touchDroppedPendingReset;touchDroppedPendingReset=0;touchCount++;
    activeTouchCount=(int)n;
   }
   // Invoke while locked: clearing the handler waits for this short wakeup call.
   // The receiver must never synchronously read the frame from inside the handler.
   if(frameHandler) frameHandler(frameContext);
  }
 }
 pthread_mutex_unlock(&lock);
}
static int load(void) {
 if(framework) return supported;
 framework=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_LOCAL|RTLD_NOW);
 if(!framework) {setStatus("private framework unavailable");return 0;}
 createList=dlsym(framework,"MTDeviceCreateList");
 registerFrame=dlsym(framework,"MTRegisterContactFrameCallback");
 unregisterFrame=dlsym(framework,"MTUnregisterContactFrameCallback");
 startDevice=dlsym(framework,"MTDeviceStart"); stopDevice=dlsym(framework,"MTDeviceStop");
 deviceIsBuiltIn=dlsym(framework,"MTDeviceIsBuiltIn");
 sensorDimensions=dlsym(framework,"MTDeviceGetSensorSurfaceDimensions");
 supported=createList&&registerFrame&&unregisterFrame&&startDevice&&stopDevice;
 if(!supported) setStatus("private ABI symbols unavailable");
 return supported;
}
int OLTouchStart(void) {
 OLTouchStop(); if(!load()) return 0;
 devices=createList(); deviceCount=devices?(int)CFArrayGetCount(devices):0;
 selectedIndex=-1;selectedBuiltIn=-1;selectedWidth=0;selectedHeight=0;
 if(!deviceCount) {setStatus("no multitouch device");return 0;}
 // Prefer an explicitly reported built-in surface. When metadata is absent,
 // fall back to the first enumerated device and report the selection as unknown.
 selectedIndex=0;
 if(deviceIsBuiltIn) {
  for(int i=0;i<deviceCount;i++) if(deviceIsBuiltIn(CFArrayGetValueAtIndex(devices,i))) {selectedIndex=i;break;}
 }
 CFTypeRef device=CFArrayGetValueAtIndex(devices,selectedIndex);
 if(deviceIsBuiltIn) selectedBuiltIn=deviceIsBuiltIn(device)?1:0;
 if(sensorDimensions && (sensorDimensions(device,&selectedWidth,&selectedHeight)!=0 || selectedWidth<=0 || selectedHeight<=0)) {
  selectedWidth=0;selectedHeight=0;
 }
 pthread_mutex_lock(&lock);running=1;fault=0;touchHead=0;touchCount=0;touchDropped=0;touchDroppedPendingReset=0;activeTouchCount=0;memset(touchFrames,0,sizeof(touchFrames));pthread_mutex_unlock(&lock);
 registerFrame(device,frame);
 if(startDevice(device,0)!=0) {OLTouchStop();setStatus("device start failed");return 0;}
 setStatus("private adapter running; live pinch unverified"); return 1;
}
void OLTouchStop(void) {
 pthread_mutex_lock(&lock);running=0;captureEnabled=false;touchHead=0;touchCount=0;touchDroppedPendingReset=0;activeTouchCount=0;frameHandler=NULL;frameContext=NULL;pthread_mutex_unlock(&lock);
 if(devices) {
  if(selectedIndex>=0 && selectedIndex<deviceCount && unregisterFrame && stopDevice) {
   CFTypeRef device=CFArrayGetValueAtIndex(devices,selectedIndex);
   unregisterFrame(device,frame);stopDevice(device);
  }
  CFRelease(devices);devices=NULL;
 }
}
int OLTouchDeviceCount(void) {return deviceCount;}
uint64_t OLTouchDroppedFrames(void) {pthread_mutex_lock(&lock);uint64_t value=touchDropped;pthread_mutex_unlock(&lock);return value;}
int OLTouchSelectedDeviceIndex(void) {return selectedIndex;}
int OLTouchSelectedIsBuiltIn(void) {return selectedBuiltIn;}
int OLTouchSelectedDimensions(int *width,int *height) {
 if(!width||!height||selectedWidth<=0||selectedHeight<=0) return 0;
 *width=selectedWidth;*height=selectedHeight;return 1;
}
int OLTouchIsSupported(void) {return load();}
const char *OLTouchStatus(void) {pthread_mutex_lock(&lock);const char *s=status;pthread_mutex_unlock(&lock);return s;}
int OLTouchRead(OLTouch *points,size_t capacity,size_t *count,double *timestamp) {
 if(!points||!count||!timestamp) return -1;
 pthread_mutex_lock(&lock);
 int result=fault?-1:0;
 if(!fault && touchCount) {
  TouchFrame *entry=&touchFrames[touchHead];
  if(capacity<entry->count || (!points && entry->count)) result=-1;
  else {
   if(entry->count) memcpy(points,entry->points,entry->count*sizeof(OLTouch));
   *count=entry->count;*timestamp=entry->timestamp;
   result=(entry->count?1:0)|(entry->reset?2:0);
   memset(entry,0,sizeof(*entry));touchHead=(touchHead+1)%OL_TOUCH_FRAME_CAPACITY;touchCount--;
   if(touchCount) result|=4; // more ordered touch frames remain to be drained
  }
 }
 pthread_mutex_unlock(&lock);return result;
}
