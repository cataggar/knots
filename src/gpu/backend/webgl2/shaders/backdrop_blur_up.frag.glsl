#version 300 es
precision highp float;
precision highp int;

uniform sampler2D g1_b0;

layout(location = 0) in vec4 a_uv_clamp;
layout(location = 1) in vec2 a_texel_step;

in vec2 v_uv;

layout(location = 0) out vec4 frag_color;

vec4 sampleClamped(vec2 uv, vec4 bounds) {
    return texture(g1_b0, clamp(uv, bounds.xy, bounds.zw));
}

void main() {
    vec2 d = a_texel_step;
    vec4 b = a_uv_clamp;
    vec4 sum = vec4(0.0);
    sum = sum + sampleClamped(v_uv + vec2(-d.x * 2.0, 0.0), b);
    sum = sum + sampleClamped(v_uv + vec2(d.x * 2.0, 0.0), b);
    sum = sum + sampleClamped(v_uv + vec2(0.0, -d.y * 2.0), b);
    sum = sum + sampleClamped(v_uv + vec2(0.0, d.y * 2.0), b);
    sum = sum + sampleClamped(v_uv + vec2(-d.x, -d.y), b) * 2.0;
    sum = sum + sampleClamped(v_uv + vec2(d.x, -d.y), b) * 2.0;
    sum = sum + sampleClamped(v_uv + vec2(-d.x, d.y), b) * 2.0;
    sum = sum + sampleClamped(v_uv + vec2(d.x, d.y), b) * 2.0;
    frag_color = sum * (1.0 / 12.0);
}
