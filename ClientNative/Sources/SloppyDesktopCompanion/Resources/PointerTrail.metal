#include <metal_stdlib>
using namespace metal;

struct PointerVertex {
    float2 position;
    float2 uv;
    float opacity;
    float core;
    float kind;
    float padding;
};
struct PointerRaster {
    float4 position [[position]];
    float2 uv;
    float opacity;
    float core;
    float kind;
};
vertex PointerRaster pointerTrailVertex(uint id [[vertex_id]],
                                       const device PointerVertex *vertices [[buffer(0)]],
                                       constant float2 &resolution [[buffer(1)]]) {
    PointerVertex v = vertices[id];
    PointerRaster out;
    out.position = float4(v.position.x / resolution.x * 2.0 - 1.0,
                          1.0 - v.position.y / resolution.y * 2.0, 0.0, 1.0);
    out.uv = v.uv; out.opacity = v.opacity; out.core = v.core; out.kind = v.kind;
    return out;
}
fragment float4 pointerTrailFragment(PointerRaster in [[stage_in]]) {
    float alpha;
    if (in.kind > 0.5) {
        float radius = length(in.uv);
        if (radius > 1.0) discard_fragment();
        if (in.kind > 1.5) {
            float distance = radius * 32.0;
            float body = exp(-pow(max(0.0, distance - in.core), 2.0) / 9.0);
            float bloom = exp(-distance * distance / 420.0);
            alpha = in.opacity * (body * 0.76 + bloom * 0.22);
        } else {
            alpha = exp(-dot(in.uv, in.uv) * 4.2) * (1.0 - smoothstep(0.75, 1.0, radius)) * in.opacity;
        }
    } else {
        float distance = abs(in.uv.x) * 32.0;
        float body = exp(-pow(max(0.0, distance - in.core), 2.0) / 9.0);
        float bloom = exp(-distance * distance / 420.0);
        alpha = in.opacity * (body * 0.76 + bloom * 0.22) * (1.0 - smoothstep(0.88, 1.0, abs(in.uv.x)));
    }
    alpha = clamp(alpha, 0.0, 0.94);
    float3 blue = float3(0.145, 0.533, 1.0);
    return float4(blue * alpha, alpha);
}
