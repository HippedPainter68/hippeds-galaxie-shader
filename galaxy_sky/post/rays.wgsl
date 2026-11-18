// Volumetric light, at half size: the view ray is marched through the shadow map, so the air glows where
// the sun (or the moon) reaches it and stays dark in the shadow of trees, cliffs and cave mouths: light
// shafts. Strongest looking toward the light. Under water it is blue and stronger.
override ray_strength: f32 = 0.6;

// A per-pixel offset for the march, so 12 steps look like many after the blur.
fn gs_ign(p: vec2<f32>) -> f32 {
    return fract(52.9829189 * fract(dot(p, vec2<f32>(0.06711056, 0.00583715))));
}

fn post(input: PostInput) -> vec4<f32> {
    if frame.has_shadow == 0u || ray_strength <= 0.0 || frame.dimension != 0 {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let depth = depth_at(input.uv);
    // From a far and a nearer point: walking bob shifts the projection, so a single point just in front
    // of the camera gives a direction that swings with every step (the shafts swung with it).
    let dir = normalize(view_position(input.uv, 0.0001) - view_position(input.uv, 0.5));
    var len = frame.shadow_distance;
    if depth > 0.0 {
        len = min(length(view_position(input.uv, depth)), frame.shadow_distance);
    }
    let step_len = len / 12.0;
    let jitter = gs_ign(input.pixel);
    var lit = 0.0;
    for (var i = 0; i < 12; i++) {
        let sp = shadow_position(dir * (f32(i) + jitter) * step_len);
        lit += textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy, sp.z);
    }
    lit /= 12.0;

    // Shafts between the clouds. The air under the cloud layer is walked along the view ray, out to 900
    // blocks. A sample glows where sunlight comes down in a bundle: at the edges of clouds and through
    // holes in them. The bundles are a pattern that is the same all along the sun's direction (it is
    // looked up on the plane that faces the sun), so on the screen they fan out from the sun, lean as it
    // moves, and drift over the land with the wind and the clouds.
    var beams = 0.0;
    let sun = frame.sun_direction;
    if sun.y > 0.03 && frame.eye_in == 0u && frame.camera_position.y < GS_CLOUD_LOW {
        var reach = 900.0;
        if depth > 0.0 {
            reach = min(length(view_position(input.uv, depth)), reach);
        }
        // Not above the cloud base.
        if dir.y > 0.001 {
            reach = min(reach, (GS_CLOUD_LOW - frame.camera_position.y) / dir.y);
        }
        let across = normalize(cross(sun, vec3<f32>(0.0, 1.0, 0.0)));
        let up_sun = cross(across, sun);
        let wind = gs_wind_dir() * frame.time * 1.5;
        // The samples sit on planes fixed in the world, not at fixed distances from the camera: walking
        // forward leaves them where they are, and the ones that come and go at the ends fade in and out.
        // About 16 a ray, spaced 8, 16, 32 or 64 blocks: in steps, so the spacing stays put while walking
        // (a short ray up to the cloud base with only two samples showed rings in the sky).
        let step = exp2(clamp(ceil(log2(reach / 16.0)), 3.0, 6.0));
        let shift = fract(dot(frame.camera_position, dir) / step + jitter) * step;
        for (var i = 0; i < 17; i++) {
            let t = (f32(i) + 1.0) * step - shift;
            let w = clamp(t / step, 0.0, 1.0) * clamp((reach - t) / step + 0.5, 0.0, 1.0);
            if w <= 0.0 {
                continue;
            }
            let p = dir * t;
            let open = clamp((gs_cloud_shadow(p) - 0.4) / 0.6, 0.0, 1.0);
            let world = p + frame.camera_position + vec3<f32>(wind.x, 0.0, wind.y);
            let q = vec2<f32>(dot(world, across), dot(world, up_sun));
            let bundle = gs_noise(vec3<f32>(q * 0.035, frame.time * 0.01)) * 0.7 + gs_noise(vec3<f32>(q * 0.09, 4.0)) * 0.3;
            beams += w * (4.0 * open * (1.0 - open) * smoothstep(0.45, 0.7, bundle) + 0.35 * (1.0 - open) * smoothstep(0.62, 0.8, bundle));
        }
        beams *= step / 900.0;
    }    let toward = max(dot(dir, frame.light_direction), 0.0);
    // Mostly toward the light: looking away from it the air stays clear, so open land is not washed out.
    var phase = 0.03 + 1.4 * pow(toward, 8.0) + 0.25 * pow(toward, 2.0);
    let air = len / frame.shadow_distance;
    var tint = vec3<f32>(1.0);
    if frame.eye_in == 1u {
        // Under water the shafts are blue and show from every side; the deeper the camera, the less
        // light is left of them.
        phase = 0.5 + 1.2 * pow(toward, 4.0);
        tint = vec3<f32>(0.35, 0.8, 1.0) * 2.0 * (0.2 + 0.8 * frame.eye_light_smooth.y);
    }
    // By night only a faint glow is left.
    let night_dim = mix(0.35, 1.0, gs_dayf());
    let rays = gs_light_color() * tint * lit * phase * air * ray_strength * 0.3 * night_dim * (1.0 - frame.thunder * 0.6);
    let shafts = gs_light_color() * beams * (0.25 + 0.75 * pow(toward, 2.0)) * ray_strength * 7.0 * gs_dayf()
        * (1.0 - frame.rain * 0.7) * (1.0 - gs_solar_eclipse().y);
    return vec4<f32>(rays + shafts, 1.0);
}
