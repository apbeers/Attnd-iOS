// duo_hinge.m — fold / unfold a booted iPhone Duo simulator (CI screenshots only; not part of the app).
//
// Xcode 27.x has no simctl / devicectl / XCTest API for the hinge: the only control is the hidden
// hinge slider in Device Hub (hold Option), and the Duo simulator boots folded, on its cover display.
// This tool runs INSIDE the simulator and posts the event that slider sends:
//
//   vendor-defined HID event, usage page 0xFF61, usage 0x5B, whose data is a binary-serialized
//   (IOCFSerialize) dictionary {provider, source = "hinge-slider-control", type = "range", value = degrees}
//   (orientation: source = "orientation-picker-control", type = "enum", value = "portrait" | ...)
//
// and confirms the new angle through CoreMotion's CMAngleManager (what UIKit's hinge APIs read).
// The protocol is undocumented private SPI, as described and verified on Xcode 27.1 / 27.2 by the
// MIT-licensed github.com/artemnovichkov/hinge; this is a minimal re-implementation of its helper.
// It may break with any Xcode or runtime update: screenshots.sh treats a failure as "skip the iPhone
// Duo screenshots" (or fails when DUO_REQUIRED=1), and checks the app's window size independently.
//
// Build (on the Mac, for the simulator):
//   xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -O2 -fobjc-arc \
//     -o build/duo-hinge scripts/ci/duo_hinge.m -framework IOKit -framework CoreFoundation \
//     -framework Foundation -framework CoreMotion && codesign -f -s - build/duo-hinge
// Run:
//   xcrun simctl spawn <udid> build/duo-hinge set <0-180> [confirm-seconds]   (180 = flat / unfolded)
//   xcrun simctl spawn <udid> build/duo-hinge orient portrait
//   xcrun simctl spawn <udid> build/duo-hinge get

#import <Foundation/Foundation.h>

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

// IOKit SPI (exported by the simulator runtime's IOKit).
extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t usagePage, uint32_t usage, uint32_t version, const uint8_t *data, CFIndex length, uint32_t options);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef allocator, int type,
    CFDictionaryRef properties);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
extern CFDataRef IOCFSerialize(CFTypeRef object, CFOptionFlags options);

enum {
    kUsagePage = 0xFF61,
    kUsage = 0x5B,
    kClientTypeSimple = 4,
    kSerializeBinary = 1,
};

// CoreMotion SPI.
@interface CMAngle : NSObject
- (float)angleDegrees;
- (float)mechanicalAngleDegrees;
@end

@interface CMAngleManager : NSObject
+ (BOOL)isAvailable;
- (void)startAngleUpdatesToQueue:(NSOperationQueue *)queue handler:(void (^)(CMAngle *angle))handler;
- (void)stopAngleUpdates;
@end

static void sendEvent(IOHIDEventSystemClientRef client, CFStringRef source, CFStringRef type, CFTypeRef value) {
    const void *keys[] = {CFSTR("provider"), CFSTR("source"), CFSTR("type"), CFSTR("value")};
    const void *values[] = {CFSTR("com.apple.Virtualization.VirtualMachines"), source, type, value};
    CFDictionaryRef payload = CFDictionaryCreate(NULL, keys, values, 4,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef data = IOCFSerialize(payload, kSerializeBinary);
    if (data) {
        IOHIDEventRef event = IOHIDEventCreateVendorDefinedEvent(NULL, mach_absolute_time(), kUsagePage, kUsage, 0,
            CFDataGetBytePtr(data), CFDataGetLength(data), 0);
        if (event) {
            IOHIDEventSystemClientDispatchEvent(client, event);
            CFRelease(event);
        }
        CFRelease(data);
    }
    CFRelease(payload);
}

static void sendAngle(IOHIDEventSystemClientRef client, double degrees) {
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberDoubleType, &degrees);
    sendEvent(client, CFSTR("hinge-slider-control"), CFSTR("range"), value);
    CFRelease(value);
}

// From iOS 27.3 `angleDegrees` settles a few degrees off; `mechanicalAngleDegrees` is the commanded angle.
static double commandedDegrees(CMAngle *angle) {
    if ([angle respondsToSelector:@selector(mechanicalAngleDegrees)]) return [angle mechanicalAngleDegrees];
    return [angle angleDegrees];
}

// Starts angle updates, runs `send`, and waits until `accept` takes an update or `timeout` passes.
// Returns 1 accepted, 0 timed out, -1 no hinge. CoreMotion delivers the current angle right away.
static int observeAngles(double timeout, void (^send)(void), BOOL (^accept)(CMAngle *angle)) {
    Class managerClass = NSClassFromString(@"CMAngleManager");
    if (!managerClass || ![managerClass isAvailable]) {
        fprintf(stderr, "duo-hinge: this simulator reports no hinge\n");
        return -1;
    }
    CMAngleManager *manager = [[managerClass alloc] init];
    __block BOOL accepted = NO;
    [manager startAngleUpdatesToQueue:[NSOperationQueue new] handler:^(CMAngle *angle) {
        if (!accepted && accept(angle)) accepted = YES;
    }];
    if (send) send();
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    while (!accepted && CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }
    [manager stopAngleUpdates];
    return accepted ? 1 : 0;
}

static int usage(void) {
    fprintf(stderr, "usage: duo-hinge set <degrees 0-180> [confirm-seconds]\n"
                    "       duo-hinge orient <portrait|landscape-left|landscape-right|pud>\n"
                    "       duo-hinge get\n");
    return 64;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) return usage();

        if (strcmp(argv[1], "get") == 0 && argc == 2) {
            __block double current = 0;
            int result = observeAngles(2, nil, ^BOOL(CMAngle *angle) {
                current = [angle angleDegrees];
                return YES;
            });
            if (result != 1) return 1;
            printf("%.1f\n", current);
            return 0;
        }

        IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateWithType(NULL, kClientTypeSimple, NULL);
        if (!client) {
            fprintf(stderr, "duo-hinge: cannot create a HID event system client\n");
            return 1;
        }

        if (strcmp(argv[1], "set") == 0 && (argc == 3 || argc == 4)) {
            double target = fmin(fmax(atof(argv[2]), 0), 180);
            double timeout = argc == 4 ? atof(argv[3]) : 0;
            if (timeout <= 0) {
                sendAngle(client, target);
            } else {
                int result = observeAngles(timeout, ^{ sendAngle(client, target); }, ^BOOL(CMAngle *angle) {
                    return fabs(commandedDegrees(angle) - target) <= 0.5;
                });
                if (result == 0) fprintf(stderr, "duo-hinge: the hinge did not reach %.0f degrees in %.0f s\n", target, timeout);
                if (result != 1) return 1;
            }
            printf("duo-hinge: hinge at %.0f degrees\n", target);
        } else if (strcmp(argv[1], "orient") == 0 && argc == 3) {
            CFStringRef value = CFStringCreateWithCString(NULL, argv[2], kCFStringEncodingUTF8);
            sendEvent(client, CFSTR("orientation-picker-control"), CFSTR("enum"), value);
            CFRelease(value);
            printf("duo-hinge: orientation %s\n", argv[2]);
        } else {
            return usage();
        }
        // Let the event leave before the process (and its HID client) goes away.
        usleep(20000);
    }
    return 0;
}
