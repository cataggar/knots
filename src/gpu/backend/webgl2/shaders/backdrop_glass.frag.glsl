#version 300 es
precision highp float;
precision highp int;

const uint MAX_CLIP_DEPTH = 32u;
const uint MAX_CLIP_NODES = 256u;

struct ClipNode {
    vec4 rect;
    vec4 radii;
    uvec4 parent_pad;
};

uniform sampler2D g1_b0;

layout(std140) uniform g2_b0 {
    ClipNode clip_nodes[MAX_CLIP_NODES];
};

in vec2 v_world_pos;
in vec2 v_local_pos;
in vec2 v_half_size;
in vec4 v_radii;
in vec4 v_border_width;
in vec4 v_tint_color;
in vec4 v_border_color;
in vec4 v_uv_Transform;
in vec4 v_uv_clamp;
in vec4 v_optics;
in vec4 v_highlight;

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

float sdSquircleBox(vec2 p, vec2 half_size, vec4 radii, float exponent) {
    float r = cornerRadius(p, normalizedRadii(radii, half_size * 2.0));
    vec2 q = abs(p) - half_size + r;
    vec2 outside = max(q, vec2(0.0));
    float n = max(exponent, 2.0);
    float corner_len = pow(pow(outside.x, n) + pow(outside.y, n), 1.0 / n);
    return corner_len + min(max(q.x, q.y), 0.0) - r;
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
        ClipNode node = clip_nodes[idx];
        vec2 half_size = node.rect.zw * 0.5;
        vec2 center = node.rect.xy + half_size;
        float d = sdRoundedBox(world_pos - center, half_size, node.radii);
        alpha = alpha * (1.0 - smoothstep(-0.5, 0.5, d));
        idx = node.parent_pad.x;
    }
    if (idx != 0u) {
        return 0.0;
    }
    return alpha;
}

vec4 sampleClamped(vec2 uv, vec4 bounds) {
    return texture(g1_b0, clamp(uv, bounds.xy, bounds.zw));
}

vec2 squircleGrad(vec2 p, vec2 half_size, vec4 radii, float exponent) {
    float eps = 0.75;
    float dx = sdSquircleBox(p + vec2(eps, 0.0), half_size, radii, exponent) -
               sdSquircleBox(p - vec2(eps, 0.0), half_size, radii, exponent);
    float dy = sdSquircleBox(p + vec2(0.0, eps), half_size, radii, exponent) -
               sdSquircleBox(p - vec2(0.0, eps), half_size, radii, exponent);
    vec2 g = vec2(dx, dy);
    float len = length(g);
    if (len > 1.0e-4) {
        return g / len;
    }
    return vec2(0.0, -1.0);
}

vec3 adjustSaturation(vec3 c, float saturation) {
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return max(mix(vec3(luma), c, saturation), vec3(0.0));
}

void main() {
    float corner_exp = v_highlight.y;
    float d = sdSquircleBox(v_local_pos, v_half_size, v_radii, corner_exp);
    float fill_alpha = 1.0 - smoothstep(-0.5, 0.5, d);
    float clip_alpha = clipAlpha(v_world_pos, v_highlight.z);
    float mask = fill_alpha * clip_alpha;
    if (mask <= 0.0001) {
        frag_color = vec4(0.0);
        return;
    }

    vec2 grad = squircleGrad(v_local_pos, v_half_size, v_radii, corner_exp);
    float depth = max(v_optics.y, 1.0);
    float inward = clamp(-d / depth, 0.0, 1.0);
    float bevel = pow(1.0 - inward, 2.2);
    float sin_theta = clamp(bevel * 0.88, 0.0, 0.96);
    float cos_theta = sqrt(max(1.0 - sin_theta * sin_theta, 0.04));

    float ior = max(v_optics.x, 1.0);
    float eta_g = 1.0 / ior;
    float disp = v_optics.z * 0.06;
    float eta_r = 1.0 / max(ior - disp, 1.0);
    float eta_b = 1.0 / (ior + disp);

    float k_r = max(1.0 - eta_r * eta_r * (1.0 - cos_theta * cos_theta), 0.0);
    float k_g = max(1.0 - eta_g * eta_g * (1.0 - cos_theta * cos_theta), 0.0);
    float k_b = max(1.0 - eta_b * eta_b * (1.0 - cos_theta * cos_theta), 0.0);

    float shift_r = (sin_theta / cos_theta - (eta_r * sin_theta) / sqrt(max(k_r, 0.01))) * depth;
    float shift_g = (sin_theta / cos_theta - (eta_g * sin_theta) / sqrt(max(k_g, 0.01))) * depth;
    float shift_b = (sin_theta / cos_theta - (eta_b * sin_theta) / sqrt(max(k_b, 0.01))) * depth;

    vec2 base_uv = v_world_pos * v_uv_Transform.xy + v_uv_Transform.zw;
    vec2 uv_r = base_uv - grad * shift_r * v_uv_Transform.xy;
    vec2 uv_g = base_uv - grad * shift_g * v_uv_Transform.xy;
    vec2 uv_b = base_uv - grad * shift_b * v_uv_Transform.xy;

    vec4 sample_g = sampleClamped(uv_g, v_uv_clamp);
    float r = sampleClamped(uv_r, v_uv_clamp).r;
    float b = sampleClamped(uv_b, v_uv_clamp).b;
    vec3 refracted = adjustSaturation(vec3(r, sample_g.g, b), v_optics.w);

    vec3 tinted = mix(refracted, v_tint_color.rgb, v_tint_color.a);

    vec2 light_dir = normalize(vec2(-0.55, -0.83));
    float spec_align = max(dot(grad, light_dir), 0.0);
    float fresnel = pow(1.0 - cos_theta, 3.0);
    float rim = bevel * (0.35 + 0.65 * pow(spec_align, 2.5)) + fresnel * 0.45;
    vec3 lit = tinted + vec3(rim * v_highlight.x);

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
        float inner_d = sdSquircleBox(
            v_local_pos - inner_center,
            inner_half_size,
            innerRadii(v_radii, width),
            corner_exp
        );
        float inner_alpha = 1.0 - smoothstep(-0.5, 0.5, inner_d);
        border_alpha = fill_alpha * (1.0 - inner_alpha);
    }

    vec3 border_mix = mix(lit, v_border_color.rgb, border_alpha * v_border_color.a);
    frag_color = vec4(border_mix * mask, mask);
}
