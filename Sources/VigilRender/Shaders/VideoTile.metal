#include <metal_stdlib>
using namespace metal;

struct TileVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct TileUniforms {
    float4 crop;              // origin.xy, size.xy in normalized source coordinates
    float4 color;             // brightness, contrast, saturation, reserved
    float4 overlayColor;
    uint overlayCount;
};

vertex TileVertexOut videoTileVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        {-1.0, -1.0}, {1.0, -1.0}, {-1.0, 1.0},
        {-1.0, 1.0}, {1.0, -1.0}, {1.0, 1.0},
    };
    constexpr float2 coordinates[] = {
        {0.0, 1.0}, {1.0, 1.0}, {0.0, 0.0},
        {0.0, 0.0}, {1.0, 1.0}, {1.0, 0.0},
    };
    return {float4(positions[vertexID], 0.0, 1.0), coordinates[vertexID]};
}

fragment float4 videoTileFragment(
    TileVertexOut input [[stage_in]],
    texture2d<float> picture [[texture(0)]],
    constant TileUniforms &uniforms [[buffer(0)]],
    constant float4 *overlays [[buffer(1)]])
{
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uniforms.crop.xy + input.uv * uniforms.crop.zw;
    float4 pixel = picture.sample(linearSampler, uv);

    float3 color = (pixel.rgb - 0.5) * uniforms.color.y + 0.5 + uniforms.color.x;
    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luminance), color, uniforms.color.z);

    float border = 0.0;
    for (uint index = 0; index < min(uniforms.overlayCount, 16u); ++index) {
        float4 rect = overlays[index];
        float2 local = input.uv - rect.xy;
        bool inside = all(local >= 0.0) && all(local <= rect.zw);
        float2 edge = min(local, rect.zw - local);
        border = max(border, inside && min(edge.x, edge.y) < 0.004 ? 1.0 : 0.0);
    }
    return mix(float4(color, pixel.a), uniforms.overlayColor, border * uniforms.overlayColor.a);
}
