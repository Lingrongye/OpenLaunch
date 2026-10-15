// Regression harness includes the real implementation; no production test API.
#include "../../Sources/CTouch/TouchAdapter.c"
#include <assert.h>
#include <stdio.h>
static void send(size_t count, double radius, double timestamp) {
 RawTouch touches[4]={0};
 for(size_t i=0;i<count;i++) {
  double angle=(double)i*1.5707963267948966;
  // Mirrored from a captured macOS 27 five-finger frame: fingerID can collide
  // while pathIndex identifies each simultaneous contact uniquely.
  touches[i].state=4;touches[i].pathIndex=100+(int)i;touches[i].fingerID=7;
  touches[i].normalizedVector.position.x=(float)(0.5+cos(angle)*radius);
  touches[i].normalizedVector.position.y=(float)(0.5+sin(angle)*radius);
 }
 frame(CFArrayGetValueAtIndex(devices,0),touches,count,timestamp,0);
}
int main(void) {
 const void *fake=CFSTR("test-device");
 devices=CFArrayCreate(NULL,&fake,1,&kCFTypeArrayCallBacks);
 selectedIndex=0;running=1;
 OLTouch points[16];size_t count=0;double timestamp=0;
 send(4,0.3,1);assert(OLTouchRead(points,16,&count,&timestamp)==1 && timestamp==1);
 for(size_t i=0;i<4;i++) assert(points[i].id==100+(int)i);
 // Main is busy: fingers lift, next gesture begins before its next read.
 send(0,0,1.1);send(4,0.3,1.2);
 int result=OLTouchRead(points,16,&count,&timestamp);
 assert(result==6 && count==0 && timestamp==1.1); // reset then queued frame
 result=OLTouchRead(points,16,&count,&timestamp);
 printf("queued result=%d count=%zu timestamp=%.1f\n",result,count,timestamp);fflush(stdout);
 assert(result==1 && count==4 && timestamp==1.2);
 puts("ordered frames preserve release boundary before next gesture");
 return 0;
}
