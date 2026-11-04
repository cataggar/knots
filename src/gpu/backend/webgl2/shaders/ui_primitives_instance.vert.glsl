#version 300 es
precision highp float;
precision highp int;

layout(std140) uniform g0_b0 {
    vec2 viewport_size;
};

layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_size;
layout(location = 2) in vec2 a_uv0;
layout(location = 3) in vec2 a_uv1;
layout(location = 4) in vec4 a_color;
layout(location = 5) in vec4 a_border_color;
layout(location = 6) in vec4 a_corner_radius;
layout(location = 7) in vec4 a_border_width;
layout(location = 8) in float a_prim_type;
layout(location = 9) in float a_clip_node;

out vec4 v_color;
out vec2 v_uv;
out vec4 v_corner_radius;
out vec2 v_half_size;
out vec4 v_border_width;
out vec4 v_border_color;
out float v_prim_type;
out vec2 v_world_pos;
out float v_clip_node;

void main() {
    const vec2 corners[4] = vec2[4](
        vec2(0.0, 0.0),
        vec2(1.0, 0.0),
        vec2(1.0, 1.0),
        vec2(0.0, 1.0)
    );
    vec2 corner = corners[gl_VertexID];
    vec2 world = a_pos + a_size * corner;
    vec2 ndc = (world / viewport_size) * 2.0 - 1.0;

    gl_Position = vec4(ndc.x, ndc.y, 0.0, 1.0);
    v_color = a_color;
    v_border_color = a_border_color;
    v_corner_radius = a_corner_radius;
    v_border_width = a_border_width;
    v_prim_type = a_prim_type;
    v_world_pos = world;
    v_clip_node = a_clip_node;

    if (a_prim_type < 0.5) {
        v_half_size = a_size * 0.5;
        v_uv = a_size * (corner - vec2(0.5, 0.5));
    } else {
        v_half_size = vec2(0.0, 0.0);
        v_uv = mix(a_uv0, a_uv1, corner);
    }
}
