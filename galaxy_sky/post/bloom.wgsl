// Bloom, at half size: the bright parts of the world (sun, lava, torches, water glints) gathered on three
// rings, so they glow in the final pass. The bright day sky glows only a third as much.
fn gs_bright(uv: vec2<f32>) -> vec3<f32> {
    var c = gs_gamma(textureSampleLevel(scene_color, linear_sampler, uv, 0.0).rgb);
    // The End's black hole is drawn in the final pass, after this one: fetch its light here.
    if frame.dimension == 1 && depth_at(uv) == 0.0 {
        c = gs_end_eye(normalize(view_position(uv, 0.0001) - view_position(uv, 0.5))).rgb * 3.0;
    }
    let sky = select(1.0, 0.35, depth_at(uv) == 0.0);
    // Only what is nearly white-hot glows, and coloured light (lava, torches) more than plain white
    // (snow and sand in the sun), which would wash the picture out.
    let hot = max(c.r, max(c.g, c.b));
    let colourful = hot - min(c.r, min(c.g, c.b));
    return c * smoothstep(0.88, 1.0, hot) * (0.35 + 0.65 * smoothstep(0.1, 0.5, colourful)) * sky;
}

fn post(input: PostInput) -> vec4<f32> {
    let px = frame.resolution.y / 720.0 / frame.resolution;
    var sum = gs_bright(input.uv) * 2.0;
    var weight = 2.0;
    for (var i = 0; i < 24; i++) {
        let ring = f32(i / 8);
        let angle = f32(i) * 0.7853982 + ring * 0.3926991;
        let radius = 4.0 + ring * ring * 7.0;
        let w = 1.0 / (1.0 + ring);
        sum += gs_bright(input.uv + vec2<f32>(cos(angle), sin(angle)) * radius * px) * w;
        weight += w;
    }
    return vec4<f32>(sum / weight * 2.0, 1.0);
}
