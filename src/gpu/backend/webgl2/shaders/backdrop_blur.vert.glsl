#version 300 es
precision highp float;
precision highp int;

layout(location = 0) in vec4 a_source;
layout(location = 1) in vec4 a_bounds;
layout(location = 2) in vec2 a_tap;

out vec2 v_uv;
out vec2 v_half_pixel;
out vec4 v_bounds;

void main() {
    uint vid = uint(gl_VertexID);
    vec2 uv = vec2(vid == 1u ? 2.0 : 0.0, vid == 2u ? 2.0 : 0.0);
    gl_Position = vec4(uv.x * 2.0 - 1.0, uv.y * 2.0 - 1.0, 0.0, 1.0);
    v_uv = a_source.xy + uv * a_source.zw;
    v_half_pixel = a_tap;
    v_bounds = a_bounds;
}
