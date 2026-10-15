#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDShared.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <mach/mach.h>
int main(int argc, char **argv) {
  int set = argc == 4 && strcmp(argv[1], "--set") == 0;
  if(argc != 1 && !set) return 2;
  if(set && ((strcmp(argv[2], "0") && strcmp(argv[2], "2")) || (strcmp(argv[3], "0") && strcmp(argv[3], "2")))) return 2;
  io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOHIDSystem"));
  io_connect_t connection=0;
  kern_return_t kr=service?IOServiceOpen(service,mach_task_self(),kIOHIDParamConnectType,&connection):KERN_FAILURE;
  if(service) IOObjectRelease(service);
  printf("{\"open_return\":%u",kr);
  if(kr) {puts("}");return 1;}
  CFStringRef keys[]={CFSTR("TrackpadFourFingerPinchGesture"),CFSTR("TrackpadFiveFingerPinchGesture")};
  const char *names[]={"TrackpadFourFingerPinchGesture","TrackpadFiveFingerPinchGesture"};
  int failed=0;
  for(int i=0;i<2;i++) {
    CFTypeRef value=NULL;
    int before=-1,after=-1,target=set && !strcmp(argv[2+i],"2")?2:0;
    kr=IOHIDCopyCFTypeParameter(connection,keys[i],&value);
    if(!kr && value && CFGetTypeID(value)==CFNumberGetTypeID()) CFNumberGetValue(value,kCFNumberIntType,&before);
    if(value) CFRelease(value);value=NULL;
    kern_return_t written=0;
    if(set) {CFNumberRef number=CFNumberCreate(NULL,kCFNumberIntType,&target);written=IOHIDSetCFTypeParameter(connection,keys[i],number);CFRelease(number);}
    kr=IOHIDCopyCFTypeParameter(connection,keys[i],&value);
    if(!kr && value && CFGetTypeID(value)==CFNumberGetTypeID()) CFNumberGetValue(value,kCFNumberIntType,&after);
    if(value) CFRelease(value);
    printf(",\"%s\":{\"before\":%d,\"write_return\":%u,\"after\":%d}",names[i],before,written,after);
    if(kr || written || (set && after!=target)) failed=1;
  }
  IOServiceClose(connection);puts("}");return failed;
}
