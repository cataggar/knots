#version 300 es
precision highp float;
precision highp int;

layout(std140) uniform g0_b0 {
    vec4 viewport;
    vec4 camera;
    vec4 geometry;
    vec4 clip_transform;
} uniforms;

layout(location = 0) in vec3 a_position;
layout(location = 1) in vec3 a_normal;
layout(location = 2) in vec4 a_particle;

out vec3 v_normal;
out vec3 v_view_position;
out float v_phase;

const float TAU = 6.28318530718;

vec3 knot_point(float t) {
    float ring = 1.18 + 0.52 * cos(4.0 * t);
    return vec3(
        ring * cos(3.0 * t),
        0.52 * sin(4.0 * t),
        ring * sin(3.0 * t)
    );
}

vec3 rotate_y(vec3 value, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return vec3(c * value.x + s * value.z, value.y, -s * value.x + c * value.z);
}

vec3 rotate_x(vec3 value, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return vec3(value.x, c * value.y - s * value.z, s * value.y + c * value.z);
}

void main() {
    float t = a_particle.x * TAU;
    vec3 centerline = knot_point(t);
    vec3 tangent = normalize(knot_point(t + 0.002) - knot_point(t - 0.002));
    vec3 guide = abs(tangent.y) > 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 side = normalize(cross(guide, tangent));
    vec3 up = cross(tangent, side);

    float radial_angle = a_particle.y + uniforms.viewport.w * t + uniforms.viewport.z * (0.12 + a_particle.w * 0.08);
    vec3 radial_direction = side * cos(radial_angle) + up * sin(radial_angle);
    vec3 center = centerline + radial_direction * (uniforms.geometry.x * a_particle.z);

    float particle_scale = 0.032 * uniforms.geometry.y * uniforms.geometry.z * (0.62 + a_particle.w * 0.76);
    vec3 local_position = side * a_position.x + up * a_position.y + tangent * a_position.z;
    vec3 local_normal = side * a_normal.x + up * a_normal.y + tangent * a_normal.z;

    vec3 yawed_position = rotate_y(center + local_position * particle_scale, uniforms.camera.x);
    vec3 view_position = rotate_x(yawed_position, uniforms.camera.y) + vec3(0.0, 0.0, 4.8 / uniforms.camera.z);
    vec3 view_normal = rotate_x(rotate_y(local_normal, uniforms.camera.x), uniforms.camera.y);

    float aspect = uniforms.viewport.x / max(uniforms.viewport.y, 1.0);
    float focal = 1.0 / uniforms.camera.w;
    vec4 clip_position = vec4(
        view_position.x * focal / aspect,
        -view_position.y * focal,
        view_position.z - 0.1,
        view_position.z
    );
    gl_Position = vec4(
        clip_position.x * uniforms.clip_transform.x + clip_position.w * uniforms.clip_transform.z,
        clip_position.y * uniforms.clip_transform.y + clip_position.w * uniforms.clip_transform.w,
        clip_position.z * 2.0 - clip_position.w,
        clip_position.w
    );
    v_normal = view_normal;
    v_view_position = view_position;
    v_phase = a_particle.x;
}
