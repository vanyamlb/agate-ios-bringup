#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if !AGATE_MATRIX_HOST
#include "viva_gpu_uapi.h"
extern CFMutableDictionaryRef IOServiceMatching(const char *);
extern mach_port_t IOServiceGetMatchingService(mach_port_t, CFDictionaryRef);
extern kern_return_t IOObjectRelease(mach_port_t);
extern kern_return_t IORegistryEntryGetRegistryEntryID(mach_port_t, uint64_t *);
@protocol AgateMetalDeviceFactory
- (id<MTLDevice>)initWithAcceleratorPort:(mach_port_t)port;
@end
#endif

extern char **environ;

enum { side = 16, width = side * 4, bufferWords = 32 };
enum { surfaceStride = 256 };
enum { pass = 0, mismatch = 1, unavailable = 2, timeout = 3, workerError = 4, resultCount };
typedef enum {
    sentinel, bufferFill, imageFill, blit, clear, sample, blend, isa, noBounds,
    cpuCopy, singleRender, singleBlit, kernelWait, readCPUBuffer, readCPUImage,
    sampleCPUImage, computeChain, privateRenderRead, draw, runtimeCompile, surfaceWrite, surfaceRender
} Operation;
typedef struct {
    Operation operation;
    unsigned vertex;
    unsigned format;
    BOOL clamp;
    BOOL depth;
    BOOL query;
} Test;

static NSString *const vertexFunctions[] = {@"vs_near", @"vs_middle", @"vs_color", @"vs_buffer"};
static const char *const vertexNames[] = {"near", "middle", "varying", "buffer"};
static const MTLPixelFormat formats[] = {MTLPixelFormatRGBA8Unorm, MTLPixelFormatBGRA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB};
static const char *const formatNames[] = {"rgba8", "bgra8", "srgb"};
static const char *const operationNames[] = {
    "sentinel", "buffer-fill", "texture-write", "blit", "clear-only", "texture-sample", "additive-blend",
    "direct-isa", "no-draw-bounds", "cpu-texture-copy", "single-submit-draw", "single-submit-blit",
    "kernel-wait-draw", "read-cpu-buffer", "read-cpu-texture", "sample-cpu-texture",
    "gpu-write-read-texture", "private-render-compute-read", "render", "runtime-compile",
    "iosurface-compute-write", "iosurface-render"
};
static const Test finalCases[] = {
    {.operation = runtimeCompile},
    {.operation = surfaceWrite, .format = 1},
    {.operation = surfaceRender, .vertex = 1, .format = 1, .query = YES},
};
enum { vertexCount = sizeof(vertexFunctions) / sizeof(*vertexFunctions),
       formatCount = sizeof(formats) / sizeof(*formats),
       drawCaseEnd = draw + vertexCount * formatCount * 2 * 2 * 2,
       testCount = drawCaseEnd + sizeof(finalCases) / sizeof(*finalCases) };
static const char *const resultNames[] = {"pass", "mismatch", "unavailable", "timeout", "worker-error"};
static const uint8_t red[4] = {255, 0, 0, 255};
static const uint8_t blue[4] = {0, 0, 255, 255};
static const uint8_t magenta[4] = {255, 0, 255, 255};
static unsigned caseNumber;
static int logFD;

static Test testAt(unsigned index)
{
    if (index >= drawCaseEnd) {
        return finalCases[index - drawCaseEnd];
    }
    if (index < draw) {
        return (Test){.operation = index, .vertex = 1,
            .query = index == isa || index == noBounds || index == singleRender || index == kernelWait};
    }
    unsigned value = index - draw;
    return (Test){
        .operation = draw, .vertex = (value / 8) % vertexCount, .format = value / (8 * vertexCount),
        .clamp = (value & 4) != 0, .depth = (value & 2) != 0, .query = (value & 1) != 0
    };
}

static int reportUnavailable(NSString *what, NSError *error)
{
    dprintf(logFD, "AGATE MATRIX error case=%03u item=%s detail=%.92s\n", caseNumber,
        what.UTF8String, error.localizedDescription.UTF8String ?: "-");
    return unavailable;
}

static int complete(id<MTLCommandBuffer> commands)
{
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [commands addCompletedHandler:^(__unused id<MTLCommandBuffer> buffer) {
        dispatch_semaphore_signal(finished);
    }];
    [commands commit];
    if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
        return timeout;
    }
    if (commands.status != MTLCommandBufferStatusCompleted) {
        dprintf(logFD, "AGATE MATRIX error case=%03u item=command status=%ld detail=%.92s\n",
            caseNumber, (long)commands.status, commands.error.localizedDescription.UTF8String ?: "-");
        return workerError;
    }
    return pass;
}

static id<MTLTexture> newTexture(id<MTLDevice> device, MTLPixelFormat format,
                                NSUInteger dimension, MTLStorageMode storage, MTLTextureUsage usage)
{
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
        width:dimension height:dimension mipmapped:NO];
    descriptor.storageMode = storage;
    descriptor.usage = usage;
    return [device newTextureWithDescriptor:descriptor];
}

static id<MTLTexture> newSurfaceTexture(id<MTLDevice> device, MTLPixelFormat format,
    MTLTextureUsage usage, id *backing)
{
    NSDictionary *properties = @{
        (__bridge NSString *)kIOSurfaceWidth: @(side),
        (__bridge NSString *)kIOSurfaceHeight: @(side),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @4,
        (__bridge NSString *)kIOSurfaceBytesPerRow: @(surfaceStride),
        (__bridge NSString *)kIOSurfaceAllocSize: @(side * surfaceStride),
        (__bridge NSString *)kIOSurfacePixelFormat: @(0x42475241u),
    };
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!surface) {
        return nil;
    }
    *backing = CFBridgingRelease(surface);
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
        width:side height:side mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = usage;
    return [device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
}

static void makePattern(uint8_t pixels[side][side][4])
{
    for (unsigned y = 0; y < side; ++y) {
        for (unsigned x = 0; x < side; ++x) {
            memcpy(pixels[y][x], ((x ^ y) & 1) ? red : blue, 4);
        }
    }
}

static int reportPixels(uint8_t pixels[side][side][4], Test test, uint64_t visible)
{
    unsigned reds = 0, blues = 0, purples = 0, pattern = 0;
    for (unsigned y = 0; y < side; ++y) {
        for (unsigned x = 0; x < side; ++x) {
            uint8_t *pixel = pixels[y][x];
            if (test.format == 1) {
                uint8_t b = pixel[0];
                pixel[0] = pixel[2];
                pixel[2] = b;
            }
            reds += memcmp(pixel, red, 4) == 0;
            blues += memcmp(pixel, blue, 4) == 0;
            purples += memcmp(pixel, magenta, 4) == 0;
            pattern += memcmp(pixel, ((x ^ y) & 1) ? red : blue, 4) == 0;
        }
    }
    BOOL valid;
    switch (test.operation) {
        case clear: valid = blues == side * side; break;
        case imageFill:
        case surfaceWrite:
        case blit:
        case cpuCopy:
        case singleBlit:
        case readCPUImage:
        case sampleCPUImage:
        case computeChain: valid = pattern == side * side; break;
        default: {
            BOOL blended = test.operation == blend;
            const uint8_t *expected = blended ? magenta : red;
            unsigned painted = blended ? purples : reds;
            valid = painted > 0 && painted + blues == side * side &&
                memcmp(pixels[side / 2][side / 2], expected, 4) == 0 && memcmp(pixels[0][0], blue, 4) == 0;
        }
    }
    const char *queryResult = !test.query ? "off" : visible == UINT64_MAX ? "missing" : "counted";
    dprintf(logFD, "AGATE MATRIX pixels case=%03u r=%u b=%u m=%u checker=%u visibility=%s samples=%llu\n",
        caseNumber, reds, blues, purples, pattern, queryResult,
        (unsigned long long)(test.query && visible != UINT64_MAX ? visible : 0));
    return valid && (!test.query || (visible != UINT64_MAX && visible > 0)) ? pass : mismatch;
}

static int inspectPixels(id<MTLTexture> target, Test test, uint64_t visible)
{
    uint8_t pixels[side][side][4] = {};
    [target getBytes:pixels bytesPerRow:width fromRegion:MTLRegionMake2D(0, 0, side, side) mipmapLevel:0];
    return reportPixels(pixels, test, visible);
}

static int inspectSurfacePixels(IOSurfaceRef shared, Test test, uint64_t visible)
{
    kern_return_t status = IOSurfaceLock(shared, kIOSurfaceLockReadOnly, NULL);
    if (status != KERN_SUCCESS) {
        dprintf(logFD, "AGATE MATRIX error case=%03u item=IOSurfaceLock status=%#x\n",
            caseNumber, (unsigned)status);
        return unavailable;
    }
    uint8_t pixels[side][side][4];
    const uint8_t *source = IOSurfaceGetBaseAddress(shared);
    const size_t stride = IOSurfaceGetBytesPerRow(shared);
    const BOOL mapped = source != NULL && stride >= width &&
        IOSurfaceGetAllocSize(shared) / side >= stride;
    if (mapped) {
        for (unsigned y = 0; y < side; ++y) {
            memcpy(pixels[y], source + y * stride, width);
        }
    }
    status = IOSurfaceUnlock(shared, kIOSurfaceLockReadOnly, NULL);
    if (status != KERN_SUCCESS || !mapped) {
        return reportUnavailable(@"IOSurface mapping or unlock", nil);
    }
    return reportPixels(pixels, test, visible);
}

static int copyPattern(id<MTLDevice> device, id<MTLCommandBuffer> commands, Test test)
{
    id<MTLTexture> input = newTexture(device, formats[0], side, MTLStorageModeShared, MTLTextureUsageShaderRead);
    id<MTLTexture> target = newTexture(device, formats[0], side, MTLStorageModeShared, MTLTextureUsageShaderRead);
    id<MTLBlitCommandEncoder> encoder = [commands blitCommandEncoder];
    if (!input || !target || !encoder) {
        return reportUnavailable(@"blit allocation", nil);
    }
    uint8_t pixels[side][side][4];
    makePattern(pixels);
    [input replaceRegion:MTLRegionMake2D(0, 0, side, side) mipmapLevel:0 withBytes:pixels bytesPerRow:width];
    MTLOrigin corner = MTLOriginMake(0, 0, 0);
    [encoder copyFromTexture:input sourceSlice:0 sourceLevel:0 sourceOrigin:corner sourceSize:MTLSizeMake(side, side, 1)
        toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:corner];
    [encoder endEncoding];
    int result = complete(commands);
    return result == pass ? inspectPixels(target, test, 0) : result;
}

static id<MTLComputeCommandEncoder> computeEncoder(id<MTLDevice> device, id<MTLLibrary> library,
    id<MTLCommandBuffer> commands, NSString *name)
{
    id<MTLFunction> shader = [library newFunctionWithName:name];
    NSError *error = nil;
    id<MTLComputePipelineState> pipeline = shader ? [device newComputePipelineStateWithFunction:shader error:&error] : nil;
    id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
    if (!pipeline || !encoder) {
        reportUnavailable(name, error);
        return nil;
    }
    [encoder setComputePipelineState:pipeline];
    return encoder;
}

static void imageThreads(id<MTLComputeCommandEncoder> encoder)
{
    [encoder dispatchThreadgroups:MTLSizeMake(2, 2, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
}

static int inspectImageThroughCompute(id<MTLDevice> device, id<MTLLibrary> library,
    id<MTLCommandBuffer> commands, id<MTLTexture> image, Test test)
{
    NSString *function = test.operation == sampleCPUImage ? @"sample_texture" : @"read_texture";
    id<MTLComputeCommandEncoder> encoder = computeEncoder(device, library, commands, function);
    id<MTLBuffer> output = [device newBufferWithLength:side * width options:MTLResourceStorageModeShared];
    uint8_t (*pixels)[side][4] = output.contents;
    if (!encoder || !pixels) {
        return reportUnavailable(@"compute readback", nil);
    }
    memset(pixels, 0xa5, side * width);
    [encoder setTexture:image atIndex:0];
    [encoder setBuffer:output offset:0 atIndex:0];
    imageThreads(encoder);
    [encoder endEncoding];
    int result = complete(commands);
    return result == pass ? reportPixels(pixels, test, UINT64_MAX) : result;
}

static int verifyTextureInput(id<MTLDevice> device, id<MTLLibrary> library, id<MTLCommandBuffer> commands, Test test)
{
    BOOL generated = test.operation == computeChain;
    MTLTextureUsage usage = MTLTextureUsageShaderRead | (generated ? MTLTextureUsageShaderWrite : 0);
    id<MTLTexture> image = newTexture(device, formats[0], side, MTLStorageModeShared, usage);
    if (!image) {
        return reportUnavailable(@"source texture", nil);
    }
    if (generated) {
        id<MTLComputeCommandEncoder> encoder = computeEncoder(device, library, commands, @"write_texture");
        if (!encoder) {
            return unavailable;
        }
        [encoder setTexture:image atIndex:0];
        imageThreads(encoder);
        [encoder endEncoding];
    } else {
        uint8_t pixels[side][side][4];
        makePattern(pixels);
        [image replaceRegion:MTLRegionMake2D(0, 0, side, side) mipmapLevel:0 withBytes:pixels bytesPerRow:width];
    }
    return inspectImageThroughCompute(device, library, commands, image, test);
}

static int runCompute(id<MTLDevice> device, id<MTLLibrary> library, id<MTLCommandBuffer> commands, Test test)
{
    BOOL image = test.operation == imageFill || test.operation == surfaceWrite;
    BOOL single = test.operation == sentinel || test.operation == runtimeCompile;
    BOOL cpuInput = test.operation == readCPUBuffer;
    NSString *function = image ? @"write_texture" : single ? @"write_sentinel" : cpuInput ? @"verify_buffer" : @"fill_buffer";
    id<MTLComputeCommandEncoder> encoder = computeEncoder(device, library, commands, function);
    if (!encoder) {
        return unavailable;
    }
    if (image) {
        id surface = nil;
        id<MTLTexture> target = test.operation == surfaceWrite ?
            newSurfaceTexture(device, formats[test.format], MTLTextureUsageShaderWrite, &surface) :
            newTexture(device, formats[0], side, MTLStorageModeShared, MTLTextureUsageShaderWrite);
        if (!target) {
            return reportUnavailable(test.operation == surfaceWrite ?
                (surface ? @"compute IOSurface import" : @"compute IOSurface allocation") : @"compute texture", nil);
        }
        [encoder setTexture:target atIndex:0];
        imageThreads(encoder);
        [encoder endEncoding];
        int result = complete(commands);
        if (result != pass) {
            return result;
        }
        return surface ? inspectSurfacePixels((__bridge IOSurfaceRef)surface, test, 0) : inspectPixels(target, test, 0);
    }
    unsigned count = single ? 1 : bufferWords;
    id<MTLBuffer> output = [device newBufferWithLength:count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    uint32_t *words = output.contents;
    if (!words) {
        return reportUnavailable(@"compute buffer", nil);
    }
    memset(words, 0xa5, count * sizeof(*words));
    if (cpuInput) {
        uint32_t pattern[bufferWords];
        for (unsigned index = 0; index < bufferWords; ++index) {
            pattern[index] = 0x12345678u ^ (index * 257u);
        }
        id<MTLBuffer> input = [device newBufferWithBytes:pattern length:sizeof(pattern) options:MTLResourceStorageModeShared];
        if (!input) {
            return reportUnavailable(@"CPU input buffer", nil);
        }
        [encoder setBuffer:input offset:0 atIndex:0];
    }
    [encoder setBuffer:output offset:0 atIndex:cpuInput ? 1 : 0];
    [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(count, 1, 1)];
    [encoder endEncoding];
    int result = complete(commands);
    if (result != pass) {
        return result;
    }
    unsigned matches = 0;
    for (unsigned index = 0; index < count; ++index) {
        uint32_t expected = single ? 0xc0ffee42u : 0x12345678u ^ (index * 257u);
        if (cpuInput) {
            expected ^= 0xfeedbeefu;
        }
        matches += words[index] == expected;
    }
    dprintf(logFD, "AGATE MATRIX buffer case=%03u matches=%u/%u first=%#x\n",
        caseNumber, matches, count, words[0]);
    return matches == count ? pass : mismatch;
}

static int runDraw(id<MTLDevice> device, id<MTLLibrary> library, id<MTLCommandBuffer> commands, Test test)
{
    MTLPixelFormat format = formats[test.format];
    BOOL computeRead = test.operation == privateRenderRead;
    BOOL imported = test.operation == surfaceRender;
    MTLStorageMode storage = computeRead ? MTLStorageModePrivate : MTLStorageModeShared;
    MTLTextureUsage usage = MTLTextureUsageRenderTarget | (computeRead ? MTLTextureUsageShaderRead : 0);
    id surface = nil;
    id<MTLTexture> target = imported ? newSurfaceTexture(device, format, usage, &surface) :
        newTexture(device, format, side, storage, usage);
    if (!target && imported) {
        return reportUnavailable(surface ? @"render IOSurface import" : @"render IOSurface allocation", nil);
    }
    MTLRenderPassDescriptor *renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
    renderPass.colorAttachments[0].texture = target;
    renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
    renderPass.colorAttachments[0].loadAction = MTLLoadActionClear;
    renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLBuffer> visibility = nil;
    uint64_t *samples = NULL;
    if (test.query) {
        visibility = [device newBufferWithLength:sizeof(uint64_t) options:MTLResourceStorageModeShared];
        samples = visibility.contents;
        if (!samples) {
            return reportUnavailable(@"visibility buffer", nil);
        }
        *samples = UINT64_MAX;
        renderPass.visibilityResultBuffer = visibility;
    }
    id<MTLDepthStencilState> depthState = nil;
    if (test.depth) {
        renderPass.depthAttachment.texture = newTexture(device, MTLPixelFormatDepth32Float, side,
            MTLStorageModePrivate, MTLTextureUsageRenderTarget);
        renderPass.depthAttachment.loadAction = MTLLoadActionClear;
        renderPass.depthAttachment.storeAction = MTLStoreActionDontCare;
        renderPass.depthAttachment.clearDepth = 1.0;
        MTLDepthStencilDescriptor *depth = [MTLDepthStencilDescriptor new];
        depth.depthCompareFunction = MTLCompareFunctionLess;
        depth.depthWriteEnabled = YES;
        depthState = [device newDepthStencilStateWithDescriptor:depth];
        if (!renderPass.depthAttachment.texture || !depthState) {
            return reportUnavailable(@"depth attachment", nil);
        }
    }
    if (!target) {
        return reportUnavailable(@"color target", nil);
    }
    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:renderPass];
    if (!encoder) {
        return reportUnavailable(@"render encoder", nil);
    }
    if (test.operation == clear) {
        [encoder endEncoding];
        int result = complete(commands);
        return result == pass ? inspectPixels(target, test, 0) : result;
    }

    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.colorAttachments[0].pixelFormat = format;
    if (test.depth) {
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    }
    NSString *fragment = test.operation == sample ? @"fs_texture" : test.vertex == 2 ? @"fs_color" : @"fs_solid";
    descriptor.vertexFunction = [library newFunctionWithName:vertexFunctions[test.vertex]];
    descriptor.fragmentFunction = [library newFunctionWithName:fragment];
    if (test.operation == blend) {
        descriptor.colorAttachments[0].blendingEnabled = YES;
        descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
    }
    if (test.vertex == 3) {
        const float xy[][2] = {{-0.8f, -0.8f}, {0.8f, -0.8f}, {0.0f, 0.8f}};
        id<MTLBuffer> input = [device newBufferWithBytes:xy length:sizeof(xy) options:MTLResourceStorageModeShared];
        if (!input) {
            return reportUnavailable(@"vertex input buffer", nil);
        }
        MTLVertexDescriptor *layout = [MTLVertexDescriptor vertexDescriptor];
        layout.attributes[0].format = MTLVertexFormatFloat2;
        layout.layouts[0].stride = sizeof(xy[0]);
        descriptor.vertexDescriptor = layout;
        [encoder setVertexBuffer:input offset:0 atIndex:0];
    }
    if (test.operation == sample) {
        id<MTLTexture> source = newTexture(device, formats[0], 1, MTLStorageModeShared, MTLTextureUsageShaderRead);
        if (!source) {
            return reportUnavailable(@"sample source texture", nil);
        }
        [source replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:red bytesPerRow:4];
        [encoder setFragmentTexture:source atIndex:0];
    }
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = descriptor.vertexFunction && descriptor.fragmentFunction ?
        [device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
    if (!pipeline) {
        return reportUnavailable(@"render pipeline", error);
    }
    [encoder setRenderPipelineState:pipeline];
    [encoder setViewport:(MTLViewport){0, 0, side, side, 0, 1}];
    [encoder setScissorRect:(MTLScissorRect){0, 0, side, side}];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setDepthClipMode:test.clamp ? MTLDepthClipModeClamp : MTLDepthClipModeClip];
    if (depthState) {
        [encoder setDepthStencilState:depthState];
    }
    if (test.query) {
        [encoder setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    if (computeRead) {
        return inspectImageThroughCompute(device, library, commands, target, test);
    }
    int result = complete(commands);
    if (result != pass) {
        return result;
    }
    const uint64_t visible = samples ? *samples : UINT64_MAX;
    return surface ? inspectSurfacePixels((__bridge IOSurfaceRef)surface, test, visible) : inspectPixels(target, test, visible);
}

static id<MTLLibrary> newRuntimeLibrary(id<MTLDevice> device, NSError **error)
{
    mach_port_t bootstrap = MACH_PORT_NULL;
    kern_return_t status = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bootstrap);
    BOOL hasBootstrap = status == KERN_SUCCESS && MACH_PORT_VALID(bootstrap);
    dprintf(logFD, "AGATE MATRIX compiler case=%03u bootstrap=%s mach_status=%d\n",
        caseNumber, hasBootstrap ? "present" : "missing", status);
    if (hasBootstrap) {
        mach_port_deallocate(mach_task_self(), bootstrap);
    }

    NSString *source = @"#include <metal_stdlib>\n"
        "kernel void write_sentinel(device uint *out [[buffer(0)]]) { out[0] = 0xc0ffee42u; }";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:error];
    NSError *failure = library ? nil : *error;
    dprintf(logFD, "AGATE MATRIX compiler case=%03u library=%s domain=%s code=%ld\n",
        caseNumber, library ? "ready" : "failed", failure.domain.UTF8String ?: "-", (long)failure.code);
    return library;
}

#if !AGATE_MATRIX_HOST
static id<MTLDevice> newSystemG77(void)
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        dprintf(logFD, "AGATE MATRIX device case=%03u system=missing\n", caseNumber);
        return nil;
    }

    uint64_t registryID = 0;
    mach_port_t service = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching(VGPU_SERVICE_CLASS));
    if (service != MACH_PORT_NULL) {
        if (IORegistryEntryGetRegistryEntryID(service, &registryID) != KERN_SUCCESS) {
            registryID = 0;
        }
        IOObjectRelease(service);
    }
    BOOL matches = registryID != 0 && device.registryID == registryID;
    /* xnu82: the system device is the G77 but reports another registry entry than the accelerator service
     * (the plug-in's own choice); log both and accept the G77 by name. */
    dprintf(logFD, "AGATE MATRIX device case=%03u system=%.60s registry-match=%s device-id=%#llx service-id=%#llx\n",
        caseNumber, device.name.UTF8String ?: "-", matches ? "yes" : "no", (unsigned long long)device.registryID,
        (unsigned long long)registryID);
    return [device.name hasPrefix:@"Mali-G77 MC9"] ? device : nil;
}
#endif

static int runCase(Test test, BOOL systemDevice)
{
    NSError *error = nil;
#if AGATE_MATRIX_HOST
    (void)systemDevice;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
#else
    if (!systemDevice) {
        setenv("VMG_NO_AIR_CACHE", "1", 1);
        setenv("VMG_NO_SHM_STATS", "1", 1);
        setenv("VMG_DRIVER", "panfrost", 1);
        setenv("VGPU_BACKEND", "iokit", 1);
        setenv("VGPU_NO_TRAP", "1", 1);
    }
    if (test.operation == isa) {
        setenv("VMG_ISA", "1", 1);
        setenv("VMG_ISA_STRICT", "1", 1);
    }
    if (test.operation == noBounds) {
        setenv("VMG_NO_DRAW_BOUNDS", "1", 1);
    }
    if (test.operation == cpuCopy) {
        setenv("VMG_CPU_TEXTURE_COPY", "1", 1);
    }
    if (test.operation == singleRender || test.operation == singleBlit) {
        setenv("VGPU_NO_SUBMIT_BATCH", "1", 1);
    }
    if (test.operation == kernelWait) {
        setenv("VGPU_NO_LOCAL_WAIT", "1", 1);
    }
    id<MTLDevice> device;
    if (systemDevice) {
        device = newSystemG77();
    } else {
        NSBundle *bundle = [NSBundle bundleWithPath:@"/Developer/VivaMTLDriver.bundle"];
        if (![bundle loadAndReturnError:&error]) {
            return reportUnavailable(@"G77 Metal plug-in", error);
        }
        id<AgateMetalDeviceFactory> factory = (id)[[bundle classNamed:@"VMDevice"] alloc];
        device = (id)[factory initWithAcceleratorPort:MACH_PORT_NULL];
    }
#endif
    if (!device) {
        return reportUnavailable(systemDevice ? @"system G77 Metal device" : @"Metal device", nil);
    }
    id<MTLLibrary> library;
    if (test.operation == runtimeCompile) {
        library = newRuntimeLibrary(device, &error);
    } else {
#if AGATE_MATRIX_HOST
        const char *path = getenv("AGATE_MATRIX_SHADER");
        if (!path) {
            return reportUnavailable(@"AGATE_MATRIX_SHADER", nil);
        }
        NSString *source = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:&error];
        library = source ? [device newLibraryWithSource:source options:nil error:&error] : nil;
#else
        NSURL *url = systemDevice ?
            [NSBundle.mainBundle.executableURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"triangle.metallib"] :
            [NSURL fileURLWithPath:@"/Developer/triangle.metallib"];
        if (!url) {
            return reportUnavailable(@"location of triangle.metallib", nil);
        }
        library = [device newLibraryWithURL:url error:&error];
#endif
    }
    if (!library) {
        return reportUnavailable(test.operation == runtimeCompile ? @"runtime shader library" : @"Metal library", error);
    }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    if (!commands) {
        return reportUnavailable(@"command buffer", nil);
    }
    commands.label = @(operationNames[test.operation]);
    switch (test.operation) {
        case sentinel:
        case runtimeCompile:
        case bufferFill:
        case imageFill:
        case surfaceWrite:
        case readCPUBuffer:
            return runCompute(device, library, commands, test);
        case blit:
        case cpuCopy:
        case singleBlit:
            return copyPattern(device, commands, test);
        case readCPUImage:
        case sampleCPUImage:
        case computeChain:
            return verifyTextureInput(device, library, commands, test);
        default:
            return runDraw(device, library, commands, test);
    }
}

static BOOL systemSuite;

static int runWorker(const char *binary, unsigned index)
{
    char number[16];
    snprintf(number, sizeof(number), "%u", index);
    char *pilotArgv[] = {(char *)binary, "--case", number, NULL};
    char *systemArgv[] = {(char *)binary, "--system-device", "--case", number, NULL};
    char **argv = systemSuite ? systemArgv : pilotArgv;
    pid_t pid;
    if (posix_spawn(&pid, binary, NULL, NULL, argv, environ) != 0) {
        return workerError;
    }
    const uint64_t deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 10 * NSEC_PER_SEC;
    int status;
    while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline) {
        pid_t observed = waitpid(pid, &status, WNOHANG);
        if (observed == pid) {
            return WIFEXITED(status) && WEXITSTATUS(status) < resultCount ? WEXITSTATUS(status) : workerError;
        }
        if (observed < 0 && errno != EINTR) {
            return workerError;
        }
        usleep(20000);
    }
    kill(pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return timeout;
}

int main(int argc, char **argv)
{
    BOOL systemDevice = argc == 4 && strcmp(argv[1], "--system-device") == 0;
    int caseArg = systemDevice ? 2 : 1;
#if AGATE_MATRIX_HOST
    logFD = STDOUT_FILENO;
    const char *worker = argv[0];
#else
    logFD = systemDevice ? STDOUT_FILENO : open("/dev/null", O_WRONLY | O_CLOEXEC);
    if (logFD < 0) {
        logFD = STDERR_FILENO;
    }
    /* agategpu=6: the RAM volume is a read-only union mount over /System/Library/Extensions, the driver is found
     * by Metal itself (MetalPluginName) and every case runs on MTLCreateSystemDefaultDevice(). */
    systemSuite = argc == 2 && strcmp(argv[1], "--system-suite") == 0;
    const char *worker = systemSuite ? "/System/Library/Extensions/metal-smoke" : "/Developer/metal-smoke";
#endif
    if (argc == caseArg + 2 && strcmp(argv[caseArg], "--case") == 0) {
        char *end;
        const char *number = argv[caseArg + 1];
        unsigned long index = strtoul(number, &end, 10);
        if (*end || end == number || index >= testCount) {
            return workerError;
        }
        caseNumber = (unsigned)index;
        @autoreleasepool {
            return runCase(testAt(caseNumber), systemDevice);
        }
    }
    if (argc != 1 && !systemSuite) {
        return workerError;
    }
    dprintf(logFD, "AGATE MATRIX start tests=%u\n", testCount);
    if (systemSuite) {
        /* no shader cache or statistics files on the iOS volume */
        setenv("VMG_NO_AIR_CACHE", "1", 1);
        setenv("VMG_NO_SHM_STATS", "1", 1);
        dprintf(logFD, "AGATE MATRIX mode=system-device worker=%s\n", worker);
    }
#if !AGATE_MATRIX_HOST
    mach_port_t gpu = MACH_PORT_NULL;
    for (unsigned second = 0; second < 180 && gpu == MACH_PORT_NULL; ++second) {
        gpu = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching(VGPU_SERVICE_CLASS));
        if (gpu == MACH_PORT_NULL) {
            sleep(1);
        }
    }
    if (gpu == MACH_PORT_NULL) {
        dprintf(logFD, "AGATE MATRIX abort GPU unavailable\n");
        return unavailable;
    }
    IOObjectRelease(gpu);
#endif

    unsigned results[resultCount] = {};
    for (unsigned index = 0; index < testCount; ++index) {
        Test description = testAt(index);
        dprintf(logFD, "AGATE MATRIX case=%03u op=%s vertex=%s format=%s clamp=%d depth=%d query=%d\n", index,
            operationNames[description.operation], vertexNames[description.vertex], formatNames[description.format],
            description.clamp, description.depth, description.query);
        int result = runWorker(worker, index);
        ++results[result];
        dprintf(logFD, "AGATE MATRIX result case=%03u status=%s\n", index, resultNames[result]);
    }
#if !AGATE_MATRIX_HOST
    sync();
#endif
    dprintf(logFD, "AGATE MATRIX end tests=%u pass=%u mismatch=%u unavailable=%u timeout=%u worker_error=%u\n",
        testCount, results[pass], results[mismatch], results[unavailable], results[timeout], results[workerError]);
    return results[pass] == testCount ? pass : mismatch;
}
