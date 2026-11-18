// Keeps this frame's rain clock for the next frame (see rain_clock.wgsl).
fn post(input: PostInput) -> vec4<f32> {
    return vec4<f32>(textureLoad(rain_clock, vec2<i32>(0), 0).r, 0.0, 0.0, 1.0);
}
