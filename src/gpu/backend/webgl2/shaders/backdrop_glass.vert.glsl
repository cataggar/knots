#version 300 es
precision highp float;
precision highp int;

layout(std140) uniform g0_b0 {
    vec2 viewport_size;
};

layout(location = 0) in vec4 a_bounds;
layout(location = 1) in vec4 a_radii;
layout(location = 2) in vec4 a_border_width;
layout(location = 3) in vec4 a_tint_color;
layout(location = 4) in vec4 a_border_color;
layout(location = 5) in vec4 a_uv_Transform;
layout(location = 6) in vec4 a_uv_clamp;
layout(location = 7) in vec4 a_optics;
layout(location = 8) in vec4 a_highlight;

out vec2 v_world_pos;
out vec2 v_local_pos;
out vec2 v_half_size;
out vec4 v_radii;
out vec4 v_border_width;
out vec4 v_tint_color;
out vec4 v_border_color;
out vec4 v_uv_Transform;
out vec4 v_uv_clamp;
out vec4 v_optics;
out vec4 v_highlight;

void main() {
    const vec2 corners[4] = vec2[4](
        vec2(0.0, 0.0),
        vec2(1.0, 0.0),
        vec2(1.0, 1.0),
        vec2(0.0, 1.0)
    );
    vec2 corner = corners[gl_VertexID];
    vec2 size = a_bounds.zw;
    vec2 world = a_bounds.xy + size * corner;
    vec2 ndc = (world / viewport_size) * 2.0 - 1.0;

    gl_Position = vec4(ndc.x, ndc.y, 0.0, 1.0);
    v_world_pos = world;
    v_half_size = size * 0.5;
    v_local_pos = size * (corner - vec2(0.5, 0.5));
    v_radii = a_radii;
    v_border_width = a_border_width;
    v_tint_color = a_tint_color;
    v_border_color = a_border_color;
    v_uv_Transform = a_uv_Transform;
    v_uv_clamp = a_uv_clamp;
    v_optics = a_optics;
    v_highlight = a_highlight;
}
