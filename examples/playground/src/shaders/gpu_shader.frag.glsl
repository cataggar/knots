#version 300 es
precision highp float;
precision highp int;

layout(std140) uniform g0_b0 {
    vec4 viewport;
    vec4 camera;
    vec4 geometry;
    vec4 clip_transform;
} uniforms;

in vec3 v_normal;
in vec3 v_view_position;
in float v_phase;

layout(location = 0) out vec4 frag_color;

const float TAU = 6.28318530718;

void main() {
    vec3 normal = normalize(v_normal);
    vec3 view_direction = normalize(-v_view_position);
    vec3 light_direction = normalize(vec3(-0.45, 0.72, -0.9));
    float diffuse = max(dot(normal, light_direction), 0.0);
    float rim = pow(1.0 - abs(dot(normal, view_direction)), 2.0);
    float depth_fade = clamp(1.38 - v_view_position.z * 0.17, 0.28, 1.0);
    float shimmer = 0.82 + 0.18 * sin(uniforms.viewport.z * 1.8 + v_phase * 37.0);

    vec3 cyan = vec3(0.12, 0.82, 1.0);
    vec3 violet = vec3(0.48, 0.28, 1.0);
    vec3 white = vec3(0.82, 0.96, 1.0);
    vec3 base = mix(cyan, violet, 0.5 + 0.5 * sin(v_phase * TAU * 3.0));
    vec3 color = mix(base, white, diffuse * 0.52 + rim * 0.34);
    float intensity = (0.026 + diffuse * 0.055 + rim * 0.082) * depth_fade * shimmer * uniforms.geometry.w;
    vec3 emission = color * intensity;
    frag_color = vec4(emission, 0.0);
}
