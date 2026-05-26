#version 450

layout(constant_id = 0) const bool apply_srgb_encode = false;

layout(set = 1, binding = 0) uniform texture2D atlas;
layout(set = 1, binding = 1) uniform sampler atlas_sampler;

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_corner_radius;
layout(location = 3) in vec2 in_half_size;
layout(location = 4) in float in_border_width;
layout(location = 5) in vec4 in_border_color;
layout(location = 6) in float in_prim_type;

layout(location = 0) out vec4 frag_color;

vec4 normalizedRadii(vec4 radii, vec2 size) {
    vec4 r = max(radii, vec4(0.0));
    float scale = 1.0;
    if (r.x + r.y > size.x && r.x + r.y > 0.0) {
        scale = min(scale, size.x / (r.x + r.y));
    }
    if (r.y + r.z > size.y && r.y + r.z > 0.0) {
        scale = min(scale, size.y / (r.y + r.z));
    }
    if (r.z + r.w > size.x && r.z + r.w > 0.0) {
        scale = min(scale, size.x / (r.z + r.w));
    }
    if (r.w + r.x > size.y && r.w + r.x > 0.0) {
        scale = min(scale, size.y / (r.w + r.x));
    }
    return r * scale;
}

float cornerRadius(vec2 p, vec4 radii) {
    if (p.y < 0.0) {
        if (p.x < 0.0) {
            return radii.x;
        }
        return radii.y;
    }
    if (p.x >= 0.0) {
        return radii.z;
    }
    return radii.w;
}

float sdRoundedBox(vec2 p, vec2 half_size, vec4 radii) {
    float radius = cornerRadius(p, normalizedRadii(radii, half_size * 2.0));
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
    vec4 sampled = texture(sampler2D(atlas, atlas_sampler), in_uv);
    vec4 col;
    if (in_prim_type < 0.5) {
        float d = sdRoundedBox(in_uv, in_half_size, in_corner_radius);

        float fill_alpha = 1.0 - smoothstep(-0.5, 0.5, d);

        float border_d = abs(d) - in_border_width;
        float border_alpha = 1.0 - smoothstep(-0.5, 0.5, border_d);

        vec4 mixed = mix(in_color, in_border_color, border_alpha * fill_alpha);
        col = vec4(mixed.rgb, mixed.a * fill_alpha);
    } else if (in_prim_type < 1.5) {
        float coverage = sampled.r;
        col = vec4(in_color.rgb, in_color.a * coverage);
    } else if (in_prim_type < 2.5) {
        col = vec4(sampled.rgb * in_color.rgb, in_color.a);
    } else {
        col = in_color;
    }

    if (apply_srgb_encode) {
        frag_color = vec4(linearToSrgb(col.rgb), col.a);
    } else {
        frag_color = col;
    }
}
