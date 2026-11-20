#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position [[attribute(0)]];
};

struct RasterVertex {
    float4 position [[position]];
};

vertex RasterVertex vs_with_position(Vertex input [[stage_in]])
{
    return {float4(input.position, 0, 1)};
}

vertex RasterVertex vs_generated(uint id [[vertex_id]])
{
    float x = id == 0 ? -0.8f : id == 1 ? 0.8f : 0.0f;
    float y = id < 2 ? -0.8f : 0.8f;
    return {float4(x, y, 0, 1)};
}

fragment float4 fs()
{
    return float4(1, 0, 0, 1);
}

kernel void write_sentinel(device uint *output [[buffer(0)]])
{
    output[0] = 0xc0ffee42u;
}
