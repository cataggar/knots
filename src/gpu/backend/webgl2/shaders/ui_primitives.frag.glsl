#version 300 es
precision highp float;
precision highp int;

const uint MAX_CLIP_DEPTH = 32u;
const uint MAX_CLIP_NODES = 256u;

uniform sampler2D g1_b0;

layout(std140) uniform g2_b0 {
    uvec4 clip_nodes_raw[MAX_CLIP_NODES * 3u];
};

in vec4 v_color;
in vec2 v_uv;
in vec4 v_corner_radius;
in vec2 v_half_size;
in vec4 v_border_width;
in vec4 v_border_color;
in float v_prim_type;
in vec2 v_world_pos;
in float v_clip_node;

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
    float r = cornerRadius(p, normalizedRadii(radii, half_size * 2.0));
    vec2 q = abs(p) - half_size + r;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

vec4 innerRadii(vec4 radii, vec4 width) {
    return max(radii - vec4(
        max(width.x, width.w),
        max(width.x, width.y),
        max(width.z, width.y),
        max(width.z, width.w)
    ), vec4(0.0));
}

float clipAlpha(vec2 world_pos, float clip_node) {
    uint idx = uint(clip_node + 0.5);
    float alpha = 1.0;
    for (uint i = 0u; i < MAX_CLIP_DEPTH && idx != 0u && idx < MAX_CLIP_NODES; i = i + 1u) {
        uint base = idx * 3u;
        vec4 rect = uintBitsToFloat(clip_nodes_raw[base]);
        vec4 radii = uintBitsToFloat(clip_nodes_raw[base + 1u]);
        vec2 half_size = rect.zw * 0.5;
        vec2 center = rect.xy + half_size;
        float d = sdRoundedBox(world_pos - center, half_size, radii);
        alpha = alpha * (1.0 - smoothstep(-0.5, 0.5, d));
        idx = clip_nodes_raw[base + 2u].x;
    }
    if (idx != 0u) {
        return 0.0;
    }
    return alpha;
}

vec4 shadeLinear() {
    vec4 sampled = texture(g1_b0, v_uv);

    if (v_prim_type < 0.5) {
        float d = sdRoundedBox(v_uv, v_half_size, v_corner_radius);
        float fill_alpha = 1.0 - smoothstep(-0.5, 0.5, d);

        vec4 width = max(v_border_width, vec4(0.0));
        float max_width = max(max(width.x, width.y), max(width.z, width.w));
        float border_alpha = 0.0;
        if (max_width > 0.0) {
            vec2 inner_half_size = max(
                v_half_size - vec2(width.w + width.y, width.x + width.z) * 0.5,
                vec2(0.0)
            );
            vec2 inner_center = vec2(
                (width.w - width.y) * 0.5,
                (width.x - width.z) * 0.5
            );
            float inner_d = sdRoundedBox(v_uv - inner_center, inner_half_size, innerRadii(v_corner_radius, width));
            float inner_alpha = 1.0 - smoothstep(-0.5, 0.5, inner_d);
            border_alpha = fill_alpha * (1.0 - inner_alpha);
        }

        vec4 col = mix(v_color, v_border_color, border_alpha);
        float clip_alpha = clipAlpha(v_world_pos, v_clip_node);
        return vec4(col.rgb, col.a * fill_alpha * clip_alpha);
    } else if (v_prim_type < 1.5) {
        float coverage = sampled.r;
        float clip_alpha = clipAlpha(v_world_pos, v_clip_node);
        return vec4(v_color.rgb, v_color.a * coverage * clip_alpha);
    } else if (v_prim_type < 2.5) {
        vec4 col = vec4(sampled.rgb * v_color.rgb, sampled.a * v_color.a);
        return vec4(col.rgb, col.a * clipAlpha(v_world_pos, v_clip_node));
    } else if (v_prim_type < 3.5) {
        return vec4(v_color.rgb, v_color.a * clipAlpha(v_world_pos, v_clip_node));
    } else {
        vec4 col = vec4(sampled.rgb * v_color.rgb, v_color.a);
        return vec4(col.rgb, col.a * clipAlpha(v_world_pos, v_clip_node));
    }
}

vec3 linearToSrgb(vec3 c) {
    bvec3 cutoff = lessThanEqual(c, vec3(0.0031308));
    vec3 lo = 12.92 * c;
    vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, vec3(cutoff));
}

void main() {
    vec4 c = shadeLinear();
#ifdef SRGB_ENCODE
    frag_color = vec4(linearToSrgb(c.rgb), c.a);
#else
    frag_color = c;
#endif
}
