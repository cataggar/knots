#version 300 es
precision highp float;
precision highp int;

layout(std140) uniform g0_b0 {
    vec2 viewport_size;
};

layout(location = 0) in vec4 a_rect;
layout(location = 1) in vec4 a_corner_radius;
layout(location = 2) in vec4 a_sample_map;
layout(location = 3) in vec4 a_params;
layout(location = 4) in vec4 a_optics;

out vec2 v_local;
out vec2 v_half_size;
out vec4 v_corner_radius;
out vec2 v_sample_uv;
out vec2 v_world_pos;
out vec4 v_params;
out vec2 v_uv_per_logical;
out vec4 v_optics;

void main() {
    const vec2 corners[4] = vec2[4](
        vec2(0.0, 0.0),
        vec2(1.0, 0.0),
        vec2(1.0, 1.0),
        vec2(0.0, 1.0)
    );
    vec2 corner = corners[gl_VertexID];
    vec2 world = a_rect.xy + a_rect.zw * corner;
    vec2 ndc = (world / viewport_size) * 2.0 - 1.0;

    gl_Position = vec4(ndc.x, ndc.y, 0.0, 1.0);
    v_half_size = a_rect.zw * 0.5;
    v_local = world - a_rect.xy - v_half_size;
    v_corner_radius = a_corner_radius;
    v_sample_uv = (world - a_sample_map.xy) * a_sample_map.zw;
    v_world_pos = world;
    v_params = a_params;
    v_uv_per_logical = a_sample_map.zw;
    v_optics = a_optics;
}
