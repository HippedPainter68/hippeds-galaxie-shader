// The picture: the world, haze in the colour of the biome's air, blue fog and drifting specks under water,
// the light shafts and the bloom, then exposure like an eye's and a filmic tone curve.
override fog_amount: f32 = 0.5;
override bloom_strength: f32 = 0.4;
override exposure: f32 = 1.0;
override auto_exposure: bool = true;
override saturation: f32 = 1.1;
override puddle_drying: f32 = 180.0;

// Sky reflection at the puddle's own height; the engine's water mirror belongs to a different plane.
fn gs_puddle_sky(dir: vec3<f32>, world: vec3<f32>, normal: vec3<f32>) -> vec3<f32> {
    var r = reflect(dir, normal);
    r.y = max(abs(r.y), 0.03);
    r = normalize(r);
    let uv = vec2<f32>(atan2(r.z, r.x) / 6.2831853 + 0.5,
        clamp((1.5707963 - asin(r.y)) / 1.8849556, 0.001, 0.999));
    let night = textureSampleLevel(night_sky, night_sky_sampler, uv, 0.0).rgb * 0.6;
    var col = mix(night, gs_atmosphere(r, frame.sun_direction), gs_dayf());
    let cloud_hit = world + r * (max(GS_CLOUD_LOW + 15.0 - world.y, 0.0) / r.y);
    let cloud = gs_cloud_density(cloud_hit, false);
    let grey = mix(vec3<f32>(0.015, 0.025, 0.045), vec3<f32>(0.3, 0.35, 0.42), gs_dayf());
    col = mix(col, grey * (1.0 - frame.thunder * 0.4), max(frame.rain * 0.65, cloud));
    return col + vec3<f32>(0.4, 0.5, 0.75) * gs_storm_flash();
}

// Trace visible trees, walls and terrain; off-screen reflections fade back to the sky.
fn gs_puddle_mirror(position: vec3<f32>, dir: vec3<f32>, normal: vec3<f32>) -> vec4<f32> {
    let origin = position + normal * 0.06;
    let ray = reflect(dir, normal);
    var previous_t = 0.12;
    for (var i = 1; i <= 16; i++) {
        let t = 0.18 + f32(i * i) * 0.14;
        let point = origin + ray * t;
        let clip = frame.projection * frame.view * vec4<f32>(point, 1.0);
        if clip.w <= 0.0 {
            break;
        }
        let uv = clip.xy / clip.w * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5);
        if any(uv <= vec2<f32>(0.002)) || any(uv >= vec2<f32>(0.998)) {
            break;
        }
        let depth = depth_at(uv);
        if depth > 0.0 {
            let gap = length(point) - length(view_position(uv, depth));
            if gap > 0.0 && gap < 0.2 + (t - previous_t) * 1.5 {
                var lo = previous_t;
                var hi = t;
                var hit_uv = uv;
                for (var refine = 0; refine < 4; refine++) {
                    let mid = (lo + hi) * 0.5;
                    let sample_point = origin + ray * mid;
                    let projected = frame.projection * frame.view * vec4<f32>(sample_point, 1.0);
                    let probe = projected.xy / projected.w * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5);
                    let sample_depth = depth_at(probe);
                    if sample_depth > 0.0 && length(sample_point) > length(view_position(probe, sample_depth)) {
                        hi = mid;
                        hit_uv = probe;
                    } else {
                        lo = mid;
                    }
                }
                let edge = min(min(hit_uv.x, hit_uv.y), min(1.0 - hit_uv.x, 1.0 - hit_uv.y));
                let confidence = smoothstep(0.01, 0.12, edge) * (1.0 - smoothstep(24.0, 36.1, hi));
                return vec4<f32>(gs_gamma(textureSampleLevel(scene_color, linear_sampler, hit_uv, 0.0).rgb), confidence);
            }
        }
        previous_t = t;
    }
    return vec4<f32>(0.0);
}

// The ACES film curve (Narkowicz's fit): deep shadows, a long soft shoulder for the highlights.
fn gs_filmic(x: vec3<f32>) -> vec3<f32> {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), vec3<f32>(0.0), vec3<f32>(1.0));
}

// Specks near the camera (motes under water, embers in the Nether). Each has its own place in the world,
// one per cell of `cell` blocks, and drifts with `moved` (how far they have all moved by now), so they
// stay where they are while the camera walks. The ray is walked through the cells for about 10 blocks.
fn gs_specks(dir: vec3<f32>, dist: f32, moved: vec3<f32>, cell: f32, radius: f32) -> f32 {
    let origin = frame.camera_position - moved;
    var sum = 0.0;
    var last = vec3<f32>(1.0e9);
    for (var i = 0; i < 20; i++) {
        let id = floor((origin + dir * (0.3 + f32(i) * cell * 0.35)) / cell);
        if all(id == last) || gs_hash13(id) > 0.4 {
            continue;
        }
        last = id;
        let to = (id + vec3<f32>(0.2) + gs_hash33(id) * 0.6) * cell - origin;
        let along = dot(to, dir);
        if along < 0.3 || along > dist {
            continue;
        }
        let flicker = 0.6 + 0.4 * sin(frame.time * (2.0 + 6.0 * gs_hash13(id + vec3<f32>(3.0))) + id.x);
        sum += smoothstep(radius, 0.0, length(to - dir * along)) * flicker / (1.0 + along * 0.12);
    }
    return sum;
}
fn post(input: PostInput) -> vec4<f32> {
    var c = gs_gamma(textureSampleLevel(scene_color, linear_sampler, input.uv, 0.0).rgb);
    let depth = depth_at(input.uv);
    let is_sky = depth <= 0.0;
    // Walking bob translates the projection: a near ray scaled by distance is not the terrain point.
    let position = view_position(input.uv, depth);
    let dir = normalize(view_position(input.uv, 0.0001) - view_position(input.uv, 0.5));
    var dist = 1000.0;
    if !is_sky {
        dist = length(position);
    }
    let overworld = frame.dimension == 0;
    let deadline = textureLoad(rain_clock, vec2<i32>(0), 0).r;
    let rainwater = select(0.0, clamp((deadline - 1.0 - frame.time) / puddle_drying, 0.0, 1.0), deadline > 0.0);

    if !is_sky && frame.eye_in == 0u && overworld {
        let texel = vec2<i32>(input.uv * frame.resolution);
        let surface = surface_at(texel);
        if surface.present && surface.data > 0.0 {
            let wet = rainwater * wetness_amount * surface.data;
            if wet > 0.0 {
                let world = frame.camera_position + position;
                let flat = smoothstep(0.8, 0.98, surface.normal.y);
                let puddle = gs_puddle(world, wet) * flat;
                let impacts = gs_rain_ripples(world.xz) * surface.data * exp(-dist * 0.035);
                let n = normalize(mix(surface.normal, vec3<f32>(0.0, 1.0, 0.0), puddle)
                    + vec3<f32>(impacts.x, 0.0, impacts.y) * puddle);
                let fresnel = 0.025 + 0.975 * pow(1.0 - max(dot(n, -dir), 0.0), 5.0);
                c *= mix(1.0, 0.76, wet * (0.5 + 0.5 * flat));
                if puddle > 0.001 {
                    var reflected = gs_puddle_sky(dir, world, n);
                    if dist < 48.0 {
                        let mirror = gs_puddle_mirror(position, dir, n);
                        reflected = mix(reflected, mirror.rgb, mirror.a * (1.0 - smoothstep(32.0, 48.0, dist)));
                    }
                    c = mix(c, reflected, puddle * (0.12 + 0.8 * fresnel));
                    let half_vec = normalize(frame.light_direction - dir);
                    let glint = pow(max(dot(n, half_vec), 0.0), 220.0) * puddle;
                    c += gs_light_color() * glint * gs_cloud_shadow(position) * 0.5;
                }
            }
            c += vec3<f32>(0.25, 0.32, 0.48) * gs_storm_flash() * surface.data;
        }
    }

    // Haze over far terrain, in the colour of the sky behind it, tinted and thickened by the biome's air.
    if !is_sky && frame.eye_in == 0u && overworld {
        let air = gs_biome_air();
        let flat_dir = normalize(vec3<f32>(dir.x, 0.03, dir.z));
        // Half vanilla's fog colour, half the scattered sky, so far land pales instead of turning cyan.
        let sky_col = mix(gs_fog_color(), gs_atmosphere(flat_dir, frame.sun_direction), 0.5 * gs_dayf() * (1.0 - frame.rain));
        let h = 1.0 - exp(-dist * 0.0015 * fog_amount * air.a * (1.0 + 3.0 * frame.rain + 2.0 * frame.thunder));
        let storm_fog = mix(sky_col * air.rgb, vec3<f32>(gs_luma(sky_col)) * vec3<f32>(0.75, 0.85, 1.0), frame.thunder * 0.6);
        c = mix(c, storm_fog, h * 0.45);
    }

    // The End: its own sky (Horizon runs no sky stage there), and far islands sink into violet haze.
    if frame.dimension == 1 {
        if is_sky {
            // What Horizon drew there stays on top where it is bright: the End's purple flashes.
            c = gs_end_sky(dir) + max(c - vec3<f32>(0.15), vec3<f32>(0.0));
        } else {
            c = mix(c, vec3<f32>(0.1, 0.035, 0.17), 1.0 - exp(-dist * 0.004 * fog_amount * 2.0));
        }
    }

    // The Nether: the hot air shimmers over what is far, the haze glows in the biome's fog colour and
    // orange from the lava below, and embers rise past the camera.
    if frame.dimension == -1 && frame.eye_in == 0u {
        let wobble = vec2<f32>(gs_noise(vec3<f32>(input.uv * vec2<f32>(60.0, 35.0), frame.time * 1.5)),
            gs_noise(vec3<f32>(input.uv * vec2<f32>(60.0, 35.0) + vec2<f32>(9.0), frame.time * 1.5))) - 0.5;
        c = gs_gamma(textureSampleLevel(scene_color, linear_sampler, input.uv + wobble * 0.004 * smoothstep(10.0, 60.0, dist), 0.0).rgb);
        let h = 1.0 - exp(-dist * 0.012 * fog_amount * 2.0);
        let glow = gs_fog_color() * 1.5 + vec3<f32>(1.0, 0.35, 0.08) * 0.2 * smoothstep(0.25, -0.4, dir.y);
        c = mix(c, glow, h * 0.6);
        c += vec3<f32>(1.0, 0.45, 0.1) * gs_specks(dir, dist, vec3<f32>(0.1, 0.5, 0.07) * frame.time, 1.5, 0.04) * 1.5;
    }

    // Clouds in front of the ground: when the camera flies above or inside them, or a mountain reaches
    // past their base. (The sky stage draws them where only sky is behind.)
    if !is_sky && frame.eye_in == 0u && overworld
        && (frame.camera_position.y > GS_CLOUD_LOW - 2.0 || frame.camera_position.y + position.y > GS_CLOUD_LOW) {
        let clouds = gs_clouds_along(dir, c, dist);
        c = mix(c, clouds.rgb, clouds.a);
    }

    if overworld && frame.eye_in == 0u {
        let sun = frame.sun_direction;
        let seed = gs_event_seed();
        // Rainbows while the ground is still wet after rain: a ring 42 degrees around the point opposite
        // the sun, red outside, so only a low sun lifts it above the horizon. Now and then a second,
        // fainter one at 51 degrees with its colours reversed. In front of far land it is fainter.
        let bow_angle = degrees(acos(clamp(dot(dir, -sun), -1.0, 1.0)));
        let seen = select(smoothstep(30.0, 140.0, dist) * 0.6, 1.0, is_sky) * smoothstep(-0.03, 0.05, dir.y)
            * smoothstep(0.0, 0.08, sun.y) * gs_dayf();
        let wet_air = clamp(rainwater * 1.5, 0.0, 1.0) * (1.0 - frame.rain * 0.8) * (1.0 - frame.thunder);
        if wet_air * seen > 0.0 {
            let k = (bow_angle - 40.0) / 2.4;
            let hue = 0.78 * (1.0 - clamp(k, 0.0, 1.0));
            let spectrum = clamp(abs(fract(hue + vec3<f32>(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, vec3<f32>(0.0), vec3<f32>(1.0));
            var bow = spectrum * smoothstep(0.0, 0.25, k) * smoothstep(1.0, 0.75, k);
            // Inside the bow the sky is a little brighter.
            bow += vec3<f32>(0.06) * smoothstep(42.0, 38.0, bow_angle);
            if gs_hash13(vec3<f32>(seed, 21.0)) < 0.3 {
                let k2 = (bow_angle - 50.0) / 3.6;
                let hue2 = 0.78 * clamp(k2, 0.0, 1.0);
                let spectrum2 = clamp(abs(fract(hue2 + vec3<f32>(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, vec3<f32>(0.0), vec3<f32>(1.0));
                bow += spectrum2 * smoothstep(0.0, 0.25, k2) * smoothstep(1.0, 0.75, k2) * 0.35;
            }
            c += bow * wet_air * seen * 0.45;
        }
        // Fog bows: a broad white ring, on some damp mornings and evenings in humid, cool biomes.
        let damp = smoothstep(0.7, 0.9, frame.downfall) * (1.0 - smoothstep(0.7, 1.0, frame.temperature)) * gs_sun_low();
        if damp * seen > 0.0 && gs_hash13(vec3<f32>(seed, 31.0)) < 0.35 {
            let kf = (bow_angle - 34.0) / 8.0;
            c += vec3<f32>(0.95, 0.97, 1.0) * smoothstep(0.0, 0.5, kf) * smoothstep(1.0, 0.5, kf) * damp * seen * (1.0 - frame.rain) * 0.12;
        }
        // A solar eclipse dims the land to a cold dusk (the sky stage dims the sky).
        let ecl = gs_solar_eclipse();
        if !is_sky {
            c *= mix(vec3<f32>(1.0), vec3<f32>(0.28, 0.32, 0.42), ecl.y);
        }
        // A lunar eclipse: the moon (Horizon draws it) turns copper red.
        let lun = gs_lunar_eclipse();
        if is_sky && lun > 0.0 {
            let near = 1.0 - smoothstep(0.1, 0.2, acos(clamp(dot(dir, frame.moon_direction), -1.0, 1.0)));
            c = mix(c, vec3<f32>(gs_luma(c)) * vec3<f32>(1.0, 0.3, 0.18) * 0.9, near * lun);
        }
    }

    // The light shafts, blurred a little (they were marched at half size with a jitter).
    let px = 1.5 / frame.resolution;
    var rays = textureSampleLevel(rays_target, linear_sampler, input.uv, 0.0).rgb;
    rays += textureSampleLevel(rays_target, linear_sampler, input.uv + vec2<f32>(px.x, px.y), 0.0).rgb;
    rays += textureSampleLevel(rays_target, linear_sampler, input.uv + vec2<f32>(-px.x, px.y), 0.0).rgb;
    rays += textureSampleLevel(rays_target, linear_sampler, input.uv + vec2<f32>(px.x, -px.y), 0.0).rgb;
    rays += textureSampleLevel(rays_target, linear_sampler, input.uv - px, 0.0).rgb;
    rays /= 5.0;

    // Under water: things lose their red with distance and sink into blue fog; specks drift in the light.
    let uw = frame.in_water;
    if uw > 0.0 {
        let water = vec3<f32>(0.10, 0.42, 0.52) * (0.3 + 0.7 * frame.eye_light_smooth.y) * mix(0.3, 1.0, gs_dayf());
        let f = 1.0 - exp(-dist * 0.025);
        c = mix(c, mix(c * vec3<f32>(0.75, 0.95, 1.0), water, f), uw);
        c += (rays * 6.0 + water * 0.5) * gs_specks(dir, dist, vec3<f32>(0.05, 0.03, -0.04) * frame.time, 0.9, 0.025) * uw;
    }

    c += rays;
    c += textureSampleLevel(glow_target, linear_sampler, input.uv, 0.0).rgb * bloom_strength;

    // Exposure: brighter in the dark, as an eye adapts (from the light at the camera, eased over seconds).
    var ev = exposure;
    if auto_exposure {
        let sky_light = frame.eye_light_smooth.y * mix(0.25, 1.0, gs_dayf());
        let seen = max(sky_light, frame.eye_light_smooth.x * 0.6);
        ev *= mix(1.25, 0.9, smoothstep(0.0, 0.9, seen));
    }

    // Tone: to linear light, exposure, the film curve, back; then the grade.
    var lin = pow(max(c, vec3<f32>(0.0)), vec3<f32>(2.2)) * ev;
    let golden = gs_sun_low() * gs_dayf() * (1.0 - frame.rain * 0.7) * 0.5 * f32(overworld);
    lin *= mix(vec3<f32>(1.0), vec3<f32>(1.1, 1.0, 0.82), golden);
    c = pow(gs_filmic(lin * 0.85), vec3<f32>(1.0 / 2.2));
    c = mix(vec3<f32>(gs_luma(c)), c, saturation);
    return vec4<f32>(clamp(c, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
