#version 300 es
precision highp float;
precision highp int;

uniform sampler2D g1_b0;

in vec2 v_uv;
in vec2 v_half_pixel;
in vec4 v_bounds;

layout(location = 0) out vec4 frag_color;

vec4 tap(vec2 uv, vec4 bounds) {
    return texture(g1_b0, clamp(uv, bounds.xy, bounds.zw));
}

void main() {
    vec2 hp = v_half_pixel;
    vec4 b = v_bounds;
    vec4 sum = vec4(0.0);
    sum += tap(v_uv + vec2(-hp.x * 2.0, 0.0), b);
    sum += tap(v_uv + vec2(hp.x * 2.0, 0.0), b);
    sum += tap(v_uv + vec2(0.0, -hp.y * 2.0), b);
    sum += tap(v_uv + vec2(0.0, hp.y * 2.0), b);
    sum += tap(v_uv + vec2(-hp.x, -hp.y), b) * 2.0;
    sum += tap(v_uv + vec2(hp.x, -hp.y), b) * 2.0;
    sum += tap(v_uv + vec2(-hp.x, hp.y), b) * 2.0;
    sum += tap(v_uv + vec2(hp.x, hp.y), b) * 2.0;
    frag_color = sum * (1.0 / 12.0);
}
