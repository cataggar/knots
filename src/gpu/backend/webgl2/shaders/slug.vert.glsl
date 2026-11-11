#version 300 es
precision highp float;
precision highp int;
precision highp usampler2D;

const uint LOG_STORAGE_TEXTURE_WIDTH = 10u;
const uint STORAGE_TEXTURE_MASK = (1u << LOG_STORAGE_TEXTURE_WIDTH) - 1u;

layout(std140) uniform g0_b0 {
    vec4 mvp_row0;
    vec4 mvp_row1;
    vec4 mvp_row2;
    vec4 mvp_row3;
    vec4 viewport;
} u;

uniform highp usampler2D g1_b0;

layout(location = 0) in vec2 a_origin;
layout(location = 1) in float a_size;
layout(location = 2) in uint a_slot;
layout(location = 3) in vec4 a_col;
layout(location = 4) in float a_clip_node;

out vec4 v_color;
out vec2 v_texcoord;
flat out vec4 v_banding;
flat out uvec4 v_glyph;
flat out vec4 v_quant;
out vec2 v_world_pos;
out float v_clip_node;

uint fetch_table_word(uint word_idx) {
    ivec2 coord = ivec2(
        int(word_idx & STORAGE_TEXTURE_MASK),
        int(word_idx >> LOG_STORAGE_TEXTURE_WIDTH)
    );
    return texelFetch(g1_b0, coord, 0).r;
}

vec4 slug_dilate(
    vec4 pos,
    vec4 tex,
    vec4 jac,
    vec4 m0,
    vec4 m1,
    vec4 m3,
    vec2 dim
) {
    vec2 n = normalize(pos.zw);
    float s = dot(m3.xy, pos.xy) + m3.w;
    float t = dot(m3.xy, n);

    float u_ = (s * dot(m0.xy, n) - t * (dot(m0.xy, pos.xy) + m0.w)) * dim.x;
    float v_ = (s * dot(m1.xy, n) - t * (dot(m1.xy, pos.xy) + m1.w)) * dim.y;

    float s2 = s * s;
    float st = s * t;
    float uv = u_ * u_ + v_ * v_;
    float denom = max(uv - st * st, 1.0e-12);
    vec2 d = pos.zw * (s2 * (st + sqrt(uv)) / denom);

    vec2 vpos = pos.xy + d;
    vec2 vtex = vec2(tex.x + dot(d, jac.xy), tex.y + dot(d, jac.zw));
    return vec4(vpos, vtex);
}

void main() {
    uint index = uint(gl_VertexID);
    bool right = (index == 1u) || (index == 2u);
    bool bottom = (index == 2u) || (index == 3u);

    uint base = a_slot * 12u;
    vec4 entry_bounds = vec4(
        uintBitsToFloat(fetch_table_word(base + 0u)),
        uintBitsToFloat(fetch_table_word(base + 1u)),
        uintBitsToFloat(fetch_table_word(base + 2u)),
        uintBitsToFloat(fetch_table_word(base + 3u))
    );
    vec4 entry_band = vec4(
        uintBitsToFloat(fetch_table_word(base + 4u)),
        uintBitsToFloat(fetch_table_word(base + 5u)),
        uintBitsToFloat(fetch_table_word(base + 6u)),
        uintBitsToFloat(fetch_table_word(base + 7u))
    );
    uint entry_blob = fetch_table_word(base + 8u);
    uint entry_points = fetch_table_word(base + 9u);
    uint entry_band_max = fetch_table_word(base + 10u);

    vec2 em = vec2(right ? entry_bounds.z : entry_bounds.x, bottom ? entry_bounds.y : entry_bounds.w);
    vec2 normal = vec2(right ? 0.70710677 : -0.70710677, bottom ? 0.70710677 : -0.70710677);
    vec4 pos = vec4(a_origin + em * vec2(a_size, -a_size), normal);
    vec4 tex = vec4(em, 0.0, 0.0);
    float inv_size = 1.0 / a_size;
    vec4 jac = vec4(inv_size, 0.0, 0.0, -inv_size);
    vec4 dilated = slug_dilate(pos, tex, jac, u.mvp_row0, u.mvp_row1, u.mvp_row3, u.viewport.zw);
    vec2 p = dilated.xy;

    vec4 clip_pos = vec4(
        p.x * u.mvp_row0.x + p.y * u.mvp_row0.y + u.mvp_row0.w,
        p.x * u.mvp_row1.x + p.y * u.mvp_row1.y + u.mvp_row1.w,
        p.x * u.mvp_row2.x + p.y * u.mvp_row2.y + u.mvp_row2.w,
        p.x * u.mvp_row3.x + p.y * u.mvp_row3.y + u.mvp_row3.w
    );
    gl_Position = vec4(clip_pos.x, -clip_pos.y, clip_pos.z * 2.0 - clip_pos.w, clip_pos.w);
    v_texcoord = dilated.zw;
    v_banding = entry_band;
    v_glyph = uvec4(entry_blob, entry_points, entry_band_max & 0xFFu, (entry_band_max >> 8u) & 0xFFu);
    v_quant = vec4(entry_bounds.xy, (entry_bounds.zw - entry_bounds.xy) / 65535.0);
    v_color = a_col;
    v_world_pos = p;
    v_clip_node = a_clip_node;
}
