#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "viva_gpu_uapi.h"

/* The iOS SDK ships the IOKit library without these discovery declarations. */
extern CFMutableDictionaryRef IOServiceMatching(const char *className);
extern mach_port_t IOServiceGetMatchingService(mach_port_t primaryPort, CFDictionaryRef matching);
extern kern_return_t IOObjectRelease(mach_port_t object);
extern kern_return_t IOServiceOpen(mach_port_t service, task_t task, uint32_t type, mach_port_t *connection);
extern kern_return_t IOServiceClose(mach_port_t connection);
extern kern_return_t IOConnectCallStructMethod(mach_port_t connection, uint32_t selector,
    const void *input, size_t inputSize, void *output, size_t *outputSize);

@protocol AgateMetalDeviceFactory
- (id<MTLDevice>)initWithAcceleratorPort:(mach_port_t)port;
@end

static int consoleFD;

static int fail(NSString *detail)
{
    dprintf(consoleFD, "AGATE METAL: FAIL %s\n", detail.UTF8String);
    return 1;
}

static void timedOut(int signalNumber)
{
    (void)signalNumber;
    const char message[] = "AGATE METAL: FAIL last stage timed out\n";
    (void)write(consoleFD, message, sizeof(message) - 1);
    _exit(124);
}

static mach_port_t waitForGPU(void)
{
    for (unsigned second = 0; second < 180; second++) {
        mach_port_t service = IOServiceGetMatchingService(MACH_PORT_NULL,
            IOServiceMatching(VGPU_SERVICE_CLASS));
        if (service != MACH_PORT_NULL) {
            return service;
        }
        sleep(1);
    }
    return MACH_PORT_NULL;
}

static BOOL checkGPUConnection(mach_port_t service)
{
    mach_port_t connection = MACH_PORT_NULL;
    dprintf(consoleFD, "AGATE METAL: opening G77 IOKit connection\n");
    kern_return_t status = IOServiceOpen(service, mach_task_self(), VGPU_CLIENT_TYPE, &connection);
    if (status != KERN_SUCCESS) {
        dprintf(consoleFD, "AGATE METAL: FAIL IOServiceOpen returned %#x\n", status);
        return NO;
    }
    dprintf(consoleFD, "AGATE METAL: reading G77 driver version\n");
    struct vgpu_version input = {}, version = {};
    size_t length = sizeof(version);
    status = IOConnectCallStructMethod(connection, VGPU_SEL_GET_VERSION,
        &input, sizeof(input), &version, &length);
    const BOOL valid = status == KERN_SUCCESS && length == sizeof(version) &&
        version.major == VGPU_UAPI_MAJOR && version.gpu_id == 0x90800011;
    dprintf(consoleFD, "AGATE METAL: %s G77 version %#x, ABI %u.%u, status %#x\n",
        valid ? "verified" : "FAIL", version.gpu_id, version.major, version.minor, status);
    dprintf(consoleFD, "AGATE METAL: closing diagnostic IOKit connection\n");
    kern_return_t closeStatus = IOServiceClose(connection);
    if (closeStatus != KERN_SUCCESS) {
        dprintf(consoleFD, "AGATE METAL: FAIL IOServiceClose returned %#x\n", closeStatus);
        return NO;
    }
    return valid;
}

static int render(id<MTLDevice> device)
{
    NSError *error = nil;
    NSString *shader = @"#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "vertex float4 vs(uint id [[vertex_id]]) {\n"
        "  const float2 positions[3] = { float2(-0.8,-0.8), float2(0.8,-0.8), float2(0,0.8) };\n"
        "  return float4(positions[id], 0, 1);\n"
        "}\n"
        "fragment float4 fs() { return float4(1, 0, 0, 1); }\n";
    dprintf(consoleFD, "AGATE METAL: compiling the shader\n");
    id<MTLLibrary> library = [device newLibraryWithSource:shader options:nil error:&error];
    if (!library) {
        return fail(error.localizedDescription ?: @"MSL compilation");
    }

    MTLRenderPipelineDescriptor *options = [MTLRenderPipelineDescriptor new];
    options.vertexFunction = [library newFunctionWithName:@"vs"];
    options.fragmentFunction = [library newFunctionWithName:@"fs"];
    options.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    dprintf(consoleFD, "AGATE METAL: creating the render pipeline\n");
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:options error:&error];
    if (!pipeline) {
        return fail(error.localizedDescription ?: @"render pipeline");
    }

    MTLTextureDescriptor *textureOptions = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    textureOptions.storageMode = MTLStorageModeShared;
    textureOptions.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [device newTextureWithDescriptor:textureOptions];
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    if (!target || !commands) {
        return fail(@"texture or command buffer allocation");
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        return fail(@"render encoder");
    }
    [encoder setRenderPipelineState:pipeline];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    dispatch_semaphore_t completion = dispatch_semaphore_create(0);
    [commands addCompletedHandler:^(__unused id<MTLCommandBuffer> buffer) {
        dispatch_semaphore_signal(completion);
    }];
    dprintf(consoleFD, "AGATE METAL: submitting the off-screen render\n");
    [commands commit];
    if (dispatch_semaphore_wait(completion, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC))) {
        return fail(@"render completion timed out");
    }
    if (commands.status != MTLCommandBufferStatusCompleted) {
        return fail(commands.error.localizedDescription ?: @"GPU command buffer failed");
    }
    uint8_t center[4] = {}, corner[4] = {};
    [target getBytes:center bytesPerRow:4 fromRegion:MTLRegionMake2D(8, 8, 1, 1) mipmapLevel:0];
    [target getBytes:corner bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    const uint8_t red[] = {255, 0, 0, 255}, blue[] = {0, 0, 255, 255};
    BOOL passed = memcmp(center, red, sizeof(red)) == 0 && memcmp(corner, blue, sizeof(blue)) == 0;
    dprintf(consoleFD, "AGATE METAL: %s pixel readback, center=(%u,%u,%u,%u) corner=(%u,%u,%u,%u)\n",
        passed ? "PASS" : "FAIL", center[0], center[1], center[2], center[3],
        corner[0], corner[1], corner[2], corner[3]);
    return passed ? 0 : 1;
}

int main(void)
{
    @autoreleasepool {
        consoleFD = open("/dev/console", O_WRONLY | O_NOCTTY | O_CLOEXEC);
        if (consoleFD < 0) {
            consoleFD = STDERR_FILENO;
        }
        dprintf(consoleFD, "AGATE METAL: waiting for the G77 test accelerator\n");
        mach_port_t service = waitForGPU();
        if (service == MACH_PORT_NULL) {
            return fail(@"accelerator unavailable after 180 seconds");
        }
        signal(SIGALRM, timedOut);
        alarm(60);
        BOOL connected = checkGPUConnection(service);
        IOObjectRelease(service);
        if (!connected) {
            return 1;
        }
        setenv("VMG_NO_AIR_CACHE", "1", 1);
        setenv("VMG_NO_SHM_STATS", "1", 1);
        setenv("VMG_DRIVER", "panfrost", 1);
        setenv("VGPU_BACKEND", "iokit", 1);
        setenv("VGPU_NO_TRAP", "1", 1);
        setenv("TSMTL_LOG", "1", 1);
        NSBundle *bundle = [NSBundle bundleWithPath:@"/Developer/VivaMTLDriver.bundle"];
        NSError *error = nil;
        dprintf(consoleFD, "AGATE METAL: loading the plug-in\n");
        if (![bundle loadAndReturnError:&error]) {
            return fail(error.localizedDescription ?: @"could not load the RAM-volume bundle");
        }
        dprintf(consoleFD, "AGATE METAL: initializing VMDevice\n");
        alarm(60);
        Class deviceClass = [bundle classNamed:@"VMDevice"];
        id<AgateMetalDeviceFactory> factory = (id)[deviceClass alloc];
        id<MTLDevice> device = (id)[factory initWithAcceleratorPort:MACH_PORT_NULL];
        if (!device) {
            return fail(@"the RAM-volume plug-in could not open the G77");
        }
        dprintf(consoleFD, "AGATE METAL: device %s\n", device.name.UTF8String);
        alarm(60);
        return render(device);
    }
}
