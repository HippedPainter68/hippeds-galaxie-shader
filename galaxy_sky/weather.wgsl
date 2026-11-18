// Colour the engine's depth-tested rain streaks; snow keeps its own texture and opacity.
fn weather(input: WeatherInput) -> vec4<f32> {
    if input.snow || frame.dimension != 0 {
        return input.color;
    }
    let daylight = mix(0.28, 1.0, gs_dayf()) * (1.0 - 0.3 * frame.thunder);
    let lit = max(input.light.x * 0.8, input.light.y * daylight);
    let tint = mix(vec3<f32>(0.38, 0.48, 0.62), vec3<f32>(0.65, 0.75, 0.86), lit);
    let flash = vec3<f32>(0.35, 0.42, 0.6) * gs_storm_flash() * input.light.y;
    // Break up the sheets without moving the engine's depth-tested streaks through roofs or walls.
    let world = input.position + frame.camera_position;
    let drops = gs_noise(vec3<f32>(world.xz * 12.0, (world.y + frame.time * 18.0) * 1.5));
    let thin = smoothstep(0.08, 0.45, drops);
    let near_fade = smoothstep(0.35, 1.5, length(input.position));
    return vec4<f32>(gs_linear(vec3<f32>(gs_luma(gs_gamma(input.color.rgb))) * tint + flash),
        input.color.a * mix(0.3, 0.8, thin) * near_fade * mix(0.8, 1.0, frame.thunder));
}
