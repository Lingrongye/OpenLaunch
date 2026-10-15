#include "CTouch.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDShared.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
static CFStringRef pinchKey(int fingers) {
 if(fingers==4) return CFSTR("TrackpadFourFingerPinchGesture");
 if(fingers==5) return CFSTR("TrackpadFiveFingerPinchGesture");
 return NULL;
}
static io_connect_t openParameters(void) {
 io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOHIDSystem"));
 io_connect_t connection=0;
 if(!service) return 0;
 kern_return_t result=IOServiceOpen(service,mach_task_self(),kIOHIDParamConnectType,&connection);
 IOObjectRelease(service);return result==KERN_SUCCESS?connection:0;
}
int OLSystemPinchGet(int fingers) {
 CFStringRef key=pinchKey(fingers);if(!key) return -1;
 io_connect_t connection=openParameters();if(!connection) return -1;
 CFTypeRef value=NULL;int result=-1;
 if(IOHIDCopyCFTypeParameter(connection,key,&value)==KERN_SUCCESS && value && CFGetTypeID(value)==CFNumberGetTypeID()) CFNumberGetValue(value,kCFNumberIntType,&result);
 if(value) CFRelease(value);IOServiceClose(connection);return result;
}
int OLSystemPinchSet(int fingers,int value) {
 CFStringRef key=pinchKey(fingers);if(!key || (value!=0 && value!=2)) return -1;
 io_connect_t connection=openParameters();if(!connection) return -1;
 CFNumberRef number=CFNumberCreate(NULL,kCFNumberIntType,&value);
 kern_return_t result=IOHIDSetCFTypeParameter(connection,key,number);
 CFRelease(number);IOServiceClose(connection);
 return result==KERN_SUCCESS && OLSystemPinchGet(fingers)==value?0:-1;
}
