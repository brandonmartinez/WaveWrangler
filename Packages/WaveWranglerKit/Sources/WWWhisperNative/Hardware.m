#import "WWWhisperNative.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int32_t ww_whisper_metal_available(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        const BOOL supported = device && [device supportsFamily:MTLGPUFamilyApple7];
        [device release];
        return supported ? 1 : 0;
    }
}
