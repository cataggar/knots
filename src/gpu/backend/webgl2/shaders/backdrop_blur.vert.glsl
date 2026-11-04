#version 300 es
precision highp float;
precision highp int;

out vec2 v_uv;

void main() {
    const vec2 positions[3] = vec2[3](
        vec2(0.0, 0.0),
        vec2(2.0, 0.0),
        vec2(0.0, 2.0)
    );
    vec2 uv = positions[gl_VertexID];
    gl_Position = vec4(uv.x * 2.0 - 1.0, uv.y * 2.0 - 1.0, 0.0, 1.0);
    v_uv = uv;
}
