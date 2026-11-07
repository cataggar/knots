#version 300 es
precision highp float;
precision highp int;

const uint MAX_CLIP_DEPTH = 32u;
const uint MAX_CLIP_NODES = 256u;
const float GLASS_IOR = 1.5;

uniform sampler2D g1_b0;

layout(std140) uniform g2_b0 {
    uvec4 clip_nodes_raw[MAX_CLIP_NODES * 3u];
};

in vec2 v_local;
in vec2 v_half_size;
in vec4 v_corner_radius;
in vec2 v_sample_uv;
in vec2 v_world_pos;
in vec4 v_params;
in vec2 v_uv_per_logical;
in vec4 v_optics;

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

float refractionProfile(float x) {
    float u = 1.0 - clamp(x, 0.0, 1.0);
    float run = u * u * u;
    float rise = pow(max(1.0 - u * u * u * u, 1e-6), 0.75);
    float inv = inversesqrt(run * run + rise * rise);
    float sin_in = run * inv;
    float cos_in = rise * inv;
    float sin_out = sin_in / GLASS_IOR;
    float cos_out = sqrt(1.0 - sin_out * sin_out);
    float shift = (sin_in * cos_out - cos_in * sin_out) / max(cos_in * cos_out + sin_in * sin_out, 1e-4);
    return shift / sqrt(GLASS_IOR * GLASS_IOR - 1.0);
}

vec3 glassTap(vec2 uv) {
    return texture(g1_b0, uv).rgb;
}

void main() {
    float d = sdRoundedBox(v_local, v_half_size, v_corner_radius);
    float coverage = 1.0 - smoothstep(-0.5, 0.5, d);

    vec2 e = vec2(0.5, 0.0);
    vec2 gradient = vec2(
        sdRoundedBox(v_local + e.xy, v_half_size, v_corner_radius) - sdRoundedBox(v_local - e.xy, v_half_size, v_corner_radius),
        sdRoundedBox(v_local + e.yx, v_half_size, v_corner_radius) - sdRoundedBox(v_local - e.yx, v_half_size, v_corner_radius)
    );
    vec2 normal = gradient / max(length(gradient), 1e-5);

    float bezel = v_optics.y;
    float x = (bezel > 0.0) ? (-d / max(bezel, 1e-5)) : 1.0;
    vec2 shift = normal * (v_optics.x * refractionProfile(x)) * v_uv_per_logical;
    float spread = v_optics.z;
    vec3 color = vec3(
        glassTap(v_sample_uv - shift * (1.0 + spread)).r,
        glassTap(v_sample_uv - shift).g,
        glassTap(v_sample_uv - shift * (1.0 - spread)).b
    );

    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luma), color, v_params.x);

    float rim = 1.0 - clamp(x, 0.0, 1.0);
    float facing = abs(dot(normal, vec2(-0.70710678, -0.70710678)));
    float highlight = clamp(v_optics.w * rim * rim * rim * (0.3 + 0.7 * facing), 0.0, 1.0);
    color = color + (vec3(1.0) - color) * highlight;

    frag_color = vec4(color, coverage * clipAlpha(v_world_pos, v_params.y));
}
