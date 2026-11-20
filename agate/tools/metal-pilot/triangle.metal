#include <metal_stdlib>
using namespace metal;

struct RasterVertex {
    float4 position [[position]];
};

struct ColorVertex {
    float4 position [[position]];
    float4 color [[user(test_color)]];
};

float4 trianglePosition(uint id, float depth)
{
    float x = id == 0 ? -0.8f : id == 1 ? 0.8f : 0.0f;
    float y = id < 2 ? -0.8f : 0.8f;
    return float4(x, y, depth, 1.0f);
}

vertex RasterVertex vs_near(uint id [[vertex_id]])
{
    return {trianglePosition(id, 0.0f)};
}

vertex RasterVertex vs_middle(uint id [[vertex_id]])
{
    return {trianglePosition(id, 0.5f)};
}

vertex ColorVertex vs_color(uint id [[vertex_id]])
{
    return {trianglePosition(id, 0.5f), float4(1, 0, 0, 1)};
}

fragment float4 fs_solid()
{
    return float4(1, 0, 0, 1);
}

fragment float4 fs_color(ColorVertex input [[stage_in]])
{
    return input.color;
}

kernel void write_sentinel(device uint *output [[buffer(0)]])
{
    output[0] = 0xc0ffee42u;
}
