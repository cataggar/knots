#version 450

layout(set = 0, binding = 0) uniform Viewport {
    vec2 size;
} viewport;

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;
layout(location = 3) in float in_corner_radius;
layout(location = 4) in vec2 in_half_size;
layout(location = 5) in float in_border_width;
layout(location = 6) in vec4 in_border_color;
layout(location = 7) in float in_prim_type;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out float out_corner_radius;
layout(location = 3) out vec2 out_half_size;
layout(location = 4) out float out_border_width;
layout(location = 5) out vec4 out_border_color;
layout(location = 6) out float out_prim_type;

void main() {
    vec2 ndc = (in_pos / viewport.size) * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, ndc.y, 0.0, 1.0);

    out_color = in_color;
    out_uv = in_uv;
    out_corner_radius = in_corner_radius;
    out_half_size = in_half_size;
    out_border_width = in_border_width;
    out_border_color = in_border_color;
    out_prim_type = in_prim_type;
}
