#version 450

layout(constant_id = 0) const bool apply_srgb_encode = false;

layout(set = 1, binding = 0) uniform sampler2D atlas;

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in float in_corner_radius;
layout(location = 3) in vec2 in_half_size;
layout(location = 4) in float in_border_width;
layout(location = 5) in vec4 in_border_color;
layout(location = 6) in float in_prim_type;

layout(location = 0) out vec4 frag_color;

float sdRoundedBox(vec2 p, vec2 half_size, float radius) {
    vec2 q = abs(p) - half_size + radius;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

vec3 linearToSrgb(vec3 c) {
    bvec3 cutoff = lessThanEqual(c, vec3(0.0031308));
    vec3 lo = 12.92 * c;
    vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, vec3(cutoff));
}

void main() {
    vec4 col;
    if (in_prim_type < 0.5) {
        float d = sdRoundedBox(in_uv, in_half_size, in_corner_radius);

        float fill_alpha = 1.0 - smoothstep(-0.5, 0.5, d);

        float border_d = abs(d) - in_border_width;
        float border_alpha = 1.0 - smoothstep(-0.5, 0.5, border_d);

        vec4 mixed = mix(in_color, in_border_color, border_alpha * fill_alpha);
        col = vec4(mixed.rgb, mixed.a * fill_alpha);
    } else if (in_prim_type < 1.5) {
        float coverage = texture(atlas, in_uv).r;
        col = vec4(in_color.rgb, in_color.a * coverage);
    } else {
        vec4 sampled = texture(atlas, in_uv);
        col = vec4(sampled.rgb * in_color.rgb, in_color.a);
    }

    if (apply_srgb_encode) {
        frag_color = vec4(linearToSrgb(col.rgb), col.a);
    } else {
        frag_color = col;
    }
}
