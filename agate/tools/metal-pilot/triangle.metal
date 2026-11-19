#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position [[attribute(0)]];
};

vertex float4 vs(Vertex input [[stage_in]])
{
    return float4(input.position, 0, 1);
}

fragment float4 fs()
{
    return float4(1, 0, 0, 1);
}
