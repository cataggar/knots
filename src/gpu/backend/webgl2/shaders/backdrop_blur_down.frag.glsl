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
    vec4 sum = sampleClamped(v_uv, b) * 4.0;
    sum = sum + sampleClamped(v_uv + vec2(-d.x, -d.y), b);
    sum = sum + sampleClamped(v_uv + vec2(d.x, -d.y), b);
    sum = sum + sampleClamped(v_uv + vec2(-d.x, d.y), b);
    sum = sum + sampleClamped(v_uv + vec2(d.x, d.y), b);
    frag_color = sum * (1.0 / 8.0);
}
