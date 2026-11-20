#include <metal_stdlib>
using namespace metal;

struct VertexInput {
    float2 xy [[attribute(0)]];
};

struct VertexPosition {
    float4 position [[position]];
};

struct VertexColor {
    float4 position [[position]];
    float4 color [[user(test_color)]];
};

float2 triangleXY(uint id)
{
    float x = id == 0 ? -0.8f : id == 1 ? 0.8f : 0.0f;
    float y = id < 2 ? -0.8f : 0.8f;
    return float2(x, y);
}

vertex VertexPosition vs_near(uint id [[vertex_id]])
{
    return {float4(triangleXY(id), 0.0f, 1.0f)};
}

vertex VertexPosition vs_middle(uint id [[vertex_id]])
{
    return {float4(triangleXY(id), 0.5f, 1.0f)};
}

vertex VertexColor vs_color(uint id [[vertex_id]])
{
    return {float4(triangleXY(id), 0.5f, 1.0f), float4(1, 0, 0, 1)};
}

vertex VertexPosition vs_buffer(VertexInput input [[stage_in]])
{
    return {float4(input.xy, 0.5f, 1.0f)};
}

fragment float4 fs_solid()
{
    return float4(1, 0, 0, 1);
}

fragment float4 fs_color(VertexColor input [[stage_in]])
{
    return input.color;
}

fragment float4 fs_texture(texture2d<float> source [[texture(0)]])
{
    constexpr sampler point(coord::normalized, filter::nearest, address::clamp_to_edge);
    return source.sample(point, float2(0.5f));
}

kernel void write_sentinel(device uint *output [[buffer(0)]])
{
    output[0] = 0xc0ffee42u;
}

kernel void fill_buffer(device uint *output [[buffer(0)]], uint index [[thread_position_in_grid]])
{
    output[index] = 0x12345678u ^ (index * 257u);
}

kernel void write_texture(texture2d<float, access::write> target [[texture(0)]],
                          uint2 index [[thread_position_in_grid]])
{
    target.write(((index.x ^ index.y) & 1u) ? float4(1, 0, 0, 1) : float4(0, 0, 1, 1), index);
}
