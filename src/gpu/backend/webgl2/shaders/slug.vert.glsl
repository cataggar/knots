#version 300 es
precision highp float;
precision highp int;

layout(std140) uniform g0_b0 {
    vec4 mvp_row0;
    vec4 mvp_row1;
    vec4 mvp_row2;
    vec4 mvp_row3;
    vec4 viewport;
} u;

layout(location = 0) in vec4 a_bounds;
layout(location = 1) in vec4 a_origin_size;
layout(location = 2) in vec2 a_glyph;
layout(location = 3) in vec4 a_bnd;
layout(location = 4) in vec4 a_col;
layout(location = 5) in float a_clip_node;

out vec4 v_color;
out vec2 v_texcoord;
flat out vec4 v_banding;
flat out ivec4 v_glyph;
out vec2 v_world_pos;
out float v_clip_node;

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

ivec4 unpack_glyph(vec4 tex) {
    uint zb = floatBitsToUint(tex.z);
    uint wb = floatBitsToUint(tex.w);
    return ivec4(
        int(zb & 0xFFFFu),
        int(zb >> 16u),
        int(wb & 0xFFFFu),
        int(wb >> 16u)
    );
}

void main() {
    uint index = uint(gl_VertexID);
    bool right = (index == 1u) || (index == 2u);
    bool bottom = (index == 2u) || (index == 3u);
    vec2 em = vec2(right ? a_bounds.z : a_bounds.x, bottom ? a_bounds.w : a_bounds.y);
    vec2 normal = vec2(right ? 0.70710677 : -0.70710677, bottom ? 0.70710677 : -0.70710677);
    vec4 pos = vec4(a_origin_size.xy + em * vec2(a_origin_size.z, -a_origin_size.z), normal);
    vec4 tex = vec4(em, a_glyph);
    vec4 jac = vec4(a_origin_size.w, 0.0, 0.0, -a_origin_size.w);
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
    v_banding = a_bnd;
    v_glyph = unpack_glyph(tex);
    v_color = a_col;
    v_world_pos = p;
    v_clip_node = a_clip_node;
}
