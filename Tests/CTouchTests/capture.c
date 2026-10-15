// Exercise the real callback and bounded capture implementation in one TU.
#include "../../Sources/CTouch/TouchAdapter.c"
#include <assert.h>
#include <stdio.h>
static void sendRaw(uint64_t number, size_t count) {
 RawTouch points[20]={0};
 for(size_t i=0;i<count && i<20;i++) {
  points[i].state=(uint32_t)(i%8);points[i].pathIndex=100+(int)i;
  points[i].fingerID=200+(int)i;points[i].handID=3;
  points[i].normalizedVector.position.x=(float)(0.1+i*0.01);
  points[i].normalizedVector.position.y=(float)(0.2+i*0.01);
 }
 frame(CFArrayGetValueAtIndex(devices,0),points,count,(double)number/100,number);
}
int main(void) {
 const void *fake=CFSTR("capture-test-device");
 devices=CFArrayCreate(NULL,&fake,1,&kCFTypeArrayCallBacks);
 selectedIndex=0;running=1;
 OLCapturePoint points[16];size_t count=99,original=99;double time=0;uint64_t number=0;
 sendRaw(1,8);
 assert(OLCaptureRead(points,16,&count,&time,&number,&original)==0); // off by default
 OLCaptureStart();sendRaw(2,8);sendRaw(3,0);
 assert(OLCaptureRead(points,4,&count,&time,&number,&original)==-1); // retry intact
 assert(OLCaptureRead(points,16,&count,&time,&number,&original)==1);
 assert(count==8 && original==8 && number==2 && time==0.02);
 for(size_t i=0;i<8;i++) {
  assert(points[i].state==i && points[i].pathID==100+(int)i);
  assert(points[i].fingerID==200+(int)i && points[i].handID==3);
  assert(fabs(points[i].x-(0.1+i*0.01))<1e-6);
 }
 assert(OLCaptureRead(points,16,&count,&time,&number,&original)==1);
 assert(count==0 && original==0 && number==3);
 assert(OLCaptureRead(points,16,&count,&time,&number,&original)==0);
 // Capture continues after the normal adapter rejects malformed (>16) contacts.
 sendRaw(4,20);sendRaw(5,8);
 assert(OLCaptureRead(points,16,&count,&time,&number,&original)==1);
 assert(count==16 && original==20 && number==4);
 assert(OLCaptureRead(points,16,&count,&time,&number,&original)==1 && number==5);
 OLCaptureStop();sendRaw(6,8);
 assert(OLCaptureRead(points,16,&count,&time,&number,&original)==0);
 OLCaptureStart();
 for(uint64_t i=0;i<515;i++) sendRaw(1000+i,8);
 assert(OLCaptureDropped()==3);
 OLCaptureStop();sendRaw(9999,8);
 for(uint64_t i=0;i<512;i++) {
  assert(OLCaptureRead(points,16,&count,&time,&number,&original)==1);
  assert(number==1003+i);
 }
 assert(OLCaptureRead(points,16,&count,&time,&number,&original)==0);
 OLCaptureStart();sendRaw(7,8);OLCaptureStart();
 assert(OLCaptureDropped()==0);
 assert(OLCaptureRead(points,16,&count,&time,&number,&original)==0);
 sendRaw(8,8);OLTouchStop();
 assert(OLCaptureRead(points,16,&count,&time,&number,&original)==1 && number==8);
 assert(OLCaptureRead(points,16,&count,&time,&number,&original)==0);
 puts("raw capture: states, order, capacity, overflow, stop/drain, restart passed");
 return 0;
}
