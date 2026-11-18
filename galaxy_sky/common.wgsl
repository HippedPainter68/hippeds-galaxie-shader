// Galaxy Sky: helpers shared by every stage. Names start with gs_ so they never clash with the prelude.

// Options several stages read (see horizon-shaders.toml).
override wave_height: f32 = 0.12;
override wave_speed: f32 = 1.0;
override wind_strength: f32 = 1.0;
override cloud_amount: f32 = 0.5;
override day_blue: f32 = 1.0;
override wetness_amount: f32 = 1.0;
override storm_flashes: f32 = 0.6;
// [shadow] and [reflection] options: Horizon turns the shadow map and the water mirror on or off with them.
override shadows: bool = true;
override reflections: bool = true;

// The cloud layer, in world blocks.
const GS_CLOUD_LOW: f32 = 190.0;
const GS_CLOUD_HIGH: f32 = 430.0;
// How much light a block of the densest cloud takes away.
const GS_CLOUD_SIGMA: f32 = 0.03;
// The world's radius for the sky, in blocks: small enough that far clouds sink to the horizon.
const GS_PLANET: f32 = 40000.0;

fn gs_luma(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

// Shader API 0.2 hands every colour over in linear light and takes it back in linear light. This pack
// was tuned in vanilla's gamma values, and its own textures are data in those values, so it works in
// gamma inside: a colour Horizon gives goes through gs_gamma when read, and a colour the pack returns
// goes through gs_linear. (Horizon decodes and encodes with the same plain 2.2 power, so the look is the
// one the 0.1 pack had.)
fn gs_gamma(c: vec3<f32>) -> vec3<f32> {
    return pow(max(c, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
}

fn gs_linear(c: vec3<f32>) -> vec3<f32> {
    return pow(max(c, vec3<f32>(0.0)), vec3<f32>(2.2));
}

// Vanilla's fog and sky colours of this frame, in the pack's gamma values.
fn gs_fog_color() -> vec3<f32> {
    return gs_gamma(frame.fog_color);
}

fn gs_sky_color() -> vec3<f32> {
    return gs_gamma(frame.sky_color);
}

// 1 by day, 0 by night, with a twilight that keeps sunsets bright.
fn gs_dayf() -> f32 {
    return smoothstep(-0.15, 0.05, frame.sun_direction.y);
}

// 1 while the sun sits on the horizon, 0 from a third of the way up.
fn gs_sun_low() -> f32 {
    return 1.0 - smoothstep(0.0, 0.35, abs(frame.sun_direction.y));
}

// The colour of the light that casts shadows: white sun, orange at sunset, pale blue moon.
fn gs_light_color() -> vec3<f32> {
    let sun = mix(vec3<f32>(1.0, 0.96, 0.9), vec3<f32>(1.0, 0.55, 0.25), gs_sun_low());
    let moon = vec3<f32>(0.35, 0.45, 0.7) * 0.35;
    let day = smoothstep(-0.05, 0.1, frame.sun_direction.y);
    return mix(moon, sun, day) * (1.0 - 0.6 * frame.rain) * (1.0 - 0.35 * frame.thunder);
}

// Hash functions (Dave Hoskins style): a pseudo-random 0..1 value per point.
fn gs_hash13(p: vec3<f32>) -> f32 {
    var q = fract(p * 0.1031);
    q += dot(q, q.zyx + 31.32);
    return fract((q.x + q.y) * q.z);
}

fn gs_hash33(p: vec3<f32>) -> vec3<f32> {
    var q = fract(p * vec3<f32>(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yxz + 33.33);
    return fract((q.xxy + q.yxx) * q.zyx);
}

// Distant sheet lightning, shared by clouds, rain and reflections; vanilla owns strikes and sound.
fn gs_storm_flash() -> f32 {
    if frame.dimension != 0 || frame.thunder <= 0.0 || storm_flashes <= 0.0 {
        return 0.0;
    }
    let slot = floor(frame.time / 12.0);
    let seed = gs_hash13(vec3<f32>(slot, 17.0, 83.0));
    let t = frame.time - slot * 12.0 - 2.0 - seed * 7.0;
    let first = smoothstep(0.0, 0.025, t) * (1.0 - smoothstep(0.06, 0.16, t));
    let echo = smoothstep(0.23, 0.25, t) * (1.0 - smoothstep(0.28, 0.42, t));
    return (first + echo * 0.55) * step(0.48, seed) * frame.rain * frame.thunder * storm_flashes;
}

// Smooth 3D value noise.
fn gs_noise(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let c000 = gs_hash13(i);
    let c100 = gs_hash13(i + vec3<f32>(1.0, 0.0, 0.0));
    let c010 = gs_hash13(i + vec3<f32>(0.0, 1.0, 0.0));
    let c110 = gs_hash13(i + vec3<f32>(1.0, 1.0, 0.0));
    let c001 = gs_hash13(i + vec3<f32>(0.0, 0.0, 1.0));
    let c101 = gs_hash13(i + vec3<f32>(1.0, 0.0, 1.0));
    let c011 = gs_hash13(i + vec3<f32>(0.0, 1.0, 1.0));
    let c111 = gs_hash13(i + vec3<f32>(1.0, 1.0, 1.0));
    return mix(
        mix(mix(c000, c100, u.x), mix(c010, c110, u.x), u.y),
        mix(mix(c001, c101, u.x), mix(c011, c111, u.x), u.y),
        u.z);
}

// Several octaves of noise: clouds and dust. More octaves, finer detail.
fn gs_fbmn(p0: vec3<f32>, octaves: i32) -> f32 {
    var p = p0;
    var amp = 0.5;
    var sum = 0.0;
    for (var k = 0; k < octaves; k++) {
        sum += amp * gs_noise(p);
        p = p * 2.03 + vec3<f32>(1.7, 9.2, 3.4);
        amp *= 0.5;
    }
    return sum;
}

fn gs_fbm(p: vec3<f32>) -> f32 {
    return gs_fbmn(p, 5);
}

// A fixed landscape of hollows: falling water levels shrink their edges and empty shallow ones first.
fn gs_puddle(world: vec3<f32>, wet: f32) -> f32 {
    let broad = gs_noise(vec3<f32>(world.xz * 0.28, world.y * 0.13));
    let detail = gs_noise(vec3<f32>(world.xz * 1.1, world.y * 0.31 + 7.0));
    let hollow = broad * 0.8 + detail * 0.2;
    let waterline = mix(0.86, 0.42, clamp(wet, 0.0, 1.0));
    return smoothstep(waterline, waterline + 0.035, hollow) * smoothstep(0.04, 0.2, wet);
}

// Expanding impact rings at fixed world positions, with independently timed drops in neighbouring cells.
fn gs_rain_ripples(xz: vec2<f32>) -> vec2<f32> {
    if frame.dimension != 0 || frame.precipitation != 1u || frame.rain <= 0.0 {
        return vec2<f32>(0.0);
    }
    let p = xz * 3.0;
    let cell = floor(p);
    var slope = vec2<f32>(0.0);
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let id = cell + vec2<f32>(f32(x), f32(y));
            let seed = gs_hash33(vec3<f32>(id, 29.0));
            let age = fract(frame.time * 1.8 + seed.z);
            let delta = p - (id + vec2<f32>(0.15) + seed.xy * 0.7);
            let dist = length(delta);
            let ring = dist - age * 0.48;
            let envelope = exp(-ring * ring * 700.0) * (1.0 - age) * (1.0 - age) * smoothstep(0.0, 0.1, age);
            slope += delta / max(dist, 0.001) * cos(ring * 85.0) * envelope * step(seed.x, frame.rain);
        }
    }
    return slope * 0.08 * frame.rain;
}

// ---- Wind ----

// Where the wind blows to (xz), and how hard: rain and thunder add to the option.
fn gs_wind_dir() -> vec2<f32> {
    return vec2<f32>(0.8, 0.6);
}

fn gs_wind() -> f32 {
    return wind_strength * (0.6 + 0.9 * frame.rain + 0.5 * frame.thunder);
}

// A gust passing over a world xz position, -1..1: slow swells with quicker flutters on top.
fn gs_gust(xz: vec2<f32>, speed: f32) -> f32 {
    let t = frame.time * speed;
    let along = dot(xz, gs_wind_dir());
    return sin(along * 0.35 - t * 1.6) * 0.6 + sin(along * 1.3 - t * 2.9 + xz.x * 0.7) * 0.4;
}

// ---- Water ----

// One wave train: deep-water waves travel at a speed set by their length, and their crests are sharper
// than their troughs.
fn gs_wave_train(xz: vec2<f32>, dir: vec2<f32>, k: f32, amp: f32) -> f32 {
    let omega = sqrt(9.8 * k) * 0.45 * wave_speed;
    let s = sin(dot(xz, dir) * k - frame.time * omega) * 0.5 + 0.5;
    return amp * (2.0 * pow(s, 1.5) - 1.0);
}

// Height of the water surface at a world xz position, in blocks above its rest level: long swells along
// the wind, shorter waves fanned out around it. Rain raises them.
fn gs_wave(xz: vec2<f32>) -> f32 {
    var h = gs_wave_train(xz, vec2<f32>(0.8, 0.6), 0.4, 0.42);
    h += gs_wave_train(xz, vec2<f32>(0.41, 0.91), 0.9, 0.25);
    h += gs_wave_train(xz, vec2<f32>(1.0, -0.05), 1.7, 0.16);
    h += gs_wave_train(xz, vec2<f32>(-0.36, 0.93), 3.1, 0.10);
    h += gs_wave_train(xz, vec2<f32>(0.3, -0.95), 5.3, 0.07);
    return h * wave_height * (1.0 + 0.6 * frame.rain);
}

// Surface normal of the waves, from the slope of gs_wave.
fn gs_water_normal(xz: vec2<f32>) -> vec3<f32> {
    let e = 0.05;
    let dx = (gs_wave(xz + vec2<f32>(e, 0.0)) - gs_wave(xz - vec2<f32>(e, 0.0))) / (2.0 * e);
    let dz = (gs_wave(xz + vec2<f32>(0.0, e)) - gs_wave(xz - vec2<f32>(0.0, e))) / (2.0 * e);
    return normalize(vec3<f32>(-dx, 1.0, -dz));
}

// Bright lines of light that dance on the ground under water (caustics), 0..1. They drift with the waves.
fn gs_caustics(xz: vec2<f32>) -> f32 {
    let t = frame.time * 0.8 * wave_speed;
    let drift = gs_wind_dir() * t * 0.3;
    let a = gs_noise(vec3<f32>((xz - drift) * 0.9, t * 0.5));
    let b = gs_noise(vec3<f32>((xz + drift.yx) * 1.5 + vec2<f32>(3.1, 7.7), -t * 0.6));
    return pow(clamp(1.0 - abs(a - b) * 2.5, 0.0, 1.0), 6.0);
}

// ---- Clouds ----

// How much of the sky the clouds cover right now, 0..1: the option, more in rain.
fn gs_cloud_amount() -> f32 {
    // The weather's mood drifts between a nearly clear sky and a heavy one: a slow swing over the hour
    // frame.time runs plus a faster one over a Minecraft day (a third of an hour), so no two days are
    // alike. Where the swing starts depends on when the player last slept (gs_event_seed).
    let start = gs_hash13(vec3<f32>(gs_event_seed().x, 41.0, 2.0)) * 6.2831853;
    let turn = frame.time * 0.0017453293;
    let mood = 0.6 * sin(turn + start) + 0.4 * sin(turn * 3.0 + start * 2.0);
    return clamp(cloud_amount * (1.0 + mood * mix(0.85, 0.65, step(0.0, mood))) + frame.rain * 0.5 + frame.thunder * 0.2, 0.0, 1.0);
}

// The clouds are real volumes. Their shapes come from two cubes of noise the pack ships as pictures
// (cloud_shape.png and cloud_detail.png: the cube's slices side by side, each with a one-texel border
// copied from its far side). skygen/src/main.rs paints them and holds a copy of the arithmetic below
// for its preview: change both together.

// A slice's place in its picture: `q` 0..1 across the slice, `n` texels a side, 8 slices a row.
fn gs_slice_uv(q: vec2<f32>, slice: i32, n: f32, size: vec2<f32>) -> vec2<f32> {
    let origin = vec2<f32>(f32(slice % 8), f32(slice / 8)) * (n + 2.0);
    return (origin + vec2<f32>(1.0) + q * n) / size;
}

// The shape cube at `p` (it spans 0..1 and repeats): two reads, blended between the slices.
fn gs_cloud_shape(p: vec3<f32>) -> vec4<f32> {
    let q = fract(p);
    let z = q.z * 64.0 - 0.5;
    let z0 = floor(z);
    let s0 = (i32(z0) + 64) % 64;
    let size = vec2<f32>(528.0, 528.0);
    let a = textureSampleLevel(cloud_shape, cloud_shape_sampler, gs_slice_uv(q.xy, s0, 64.0, size), 0.0);
    let b = textureSampleLevel(cloud_shape, cloud_shape_sampler, gs_slice_uv(q.xy, (s0 + 1) % 64, 64.0, size), 0.0);
    return mix(a, b, z - z0);
}

fn gs_cloud_fine(p: vec3<f32>) -> vec3<f32> {
    let q = fract(p);
    let z = q.z * 32.0 - 0.5;
    let z0 = floor(z);
    let s0 = (i32(z0) + 32) % 32;
    let size = vec2<f32>(272.0, 136.0);
    let a = textureSampleLevel(cloud_detail, cloud_detail_sampler, gs_slice_uv(q.xy, s0, 32.0, size), 0.0);
    let b = textureSampleLevel(cloud_detail, cloud_detail_sampler, gs_slice_uv(q.xy, (s0 + 1) % 32, 32.0, size), 0.0);
    return mix(a.rgb, b.rgb, z - z0);
}

fn gs_remap(x: f32, a: f32, b: f32) -> f32 {
    return clamp((x - a) / (b - a), 0.0, 1.0);
}

// How dense the clouds are at a world position (y its height), 0..1.
// `level` 0: the masses only (for light and shadows); 1: with the middle-sized lumps; 2: with frayed edges.
fn gs_cloud_density_at(p0: vec3<f32>, level: i32) -> f32 {
    let h = (p0.y - GS_CLOUD_LOW) / (GS_CLOUD_HIGH - GS_CLOUD_LOW);
    if h <= 0.0 || h >= 1.0 {
        return 0.0;
    }
    // Everything drifts with the wind, three blocks a second.
    let drift = gs_wind_dir() * frame.time * 3.0;
    let p = vec3<f32>(p0.x + drift.x, p0.y, p0.z + drift.y);

    // Where clouds stand: fields of them with clear sky between, more as the Clouds option and rain rise.
    let w = textureSampleLevel(cloud_noise, cloud_noise_sampler, p.xz * 0.0004, 0.0).rgb;
    let field = w.r * 0.6 + w.b * 0.4;
    let threshold = mix(0.54, 0.02, gs_cloud_amount());
    let cover = smoothstep(threshold, threshold + 0.3, field);
    if cover <= 0.0 {
        return 0.0;
    }
    // How tall they grow here: flat bases, and tops that round off lower or higher.
    let kind = clamp(w.b * 0.6 + cover * 0.5 + frame.thunder * 0.3, 0.0, 1.0);
    let top = mix(0.3, 1.0, kind);
    let gradient = smoothstep(0.0, 0.07, h) * (1.0 - smoothstep(top * 0.4, top, h));

    // The masses: soft noise carved by round billows.
    let s = gs_cloud_shape(p.xzy * 0.0011);
    let billows = s.g * 0.625 + s.b * 0.25 + s.a * 0.125;
    let base = gs_remap(s.r, billows - 1.0, 1.0) * gradient;
    var d = gs_remap(base, 1.0 - cover, 1.0) * cover;
    if d <= 0.0 {
        return 0.0;
    }
    if level >= 1 {
        // Middle-sized billows bite into the mass, most at its edge: the cauliflower look.
        let m = gs_cloud_shape(p.xzy * 0.0037 + vec3<f32>(0.31, 0.17, 0.0));
        let lumps = m.g * 0.6 + m.b * 0.4;
        d = gs_remap(d, (1.0 - lumps) * 0.42 * (1.0 - d * 0.5), 1.0);
    }
    if level >= 2 && d > 0.0 {
        // Fine billows fray the edge: wisps below, puffs above.
        let f = gs_cloud_fine(p.xzy * 0.0075);
        let fine = f.r * 0.625 + f.g * 0.25 + f.b * 0.125;
        d = gs_remap(d, mix(fine, 1.0 - fine, clamp(h * 4.0, 0.0, 1.0)) * 0.45, 1.0);
    }
    // Clouds are dense right behind their edge: that is what gives them a firm outline.
    return clamp(d * 3.0, 0.0, 1.0);
}

// The same, for the ground (cloud shadows) and the puddles' reflections: `detail` asks for the lumps.
fn gs_cloud_density(p: vec3<f32>, detail: bool) -> f32 {
    return gs_cloud_density_at(p, select(0, 1, detail));
}

// How much sunlight the clouds let through to a camera-relative point, 0.35..1: the cloud layer where
// the ray to the light crosses it.
fn gs_cloud_shadow(position: vec3<f32>) -> f32 {
    let l = frame.light_direction;
    if l.y < 0.05 || frame.dimension != 0 {
        return 1.0;
    }
    let world = position + frame.camera_position;
    // A quarter of the way up the layer, where every cloud is at its widest.
    let level = GS_CLOUD_LOW + 60.0;
    let hit = world + l * ((level - world.y) / l.y);
    let d = gs_cloud_density(vec3<f32>(hit.x, level, hit.z), false);
    return 1.0 - 0.6 * smoothstep(0.0, 0.5, d);
}

override cloud_quality: u32 = 1u;

// How strongly a cloud sends light on at an angle to where it came from: mostly straight ahead.
fn gs_henyey(cos_t: f32, g: f32) -> f32 {
    return (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cos_t, 1.5);
}

// The clouds along a ray, as far as `tmax` blocks: the sky passes no limit, the last post pass the
// distance to the terrain, so clouds also stand in front of the ground when the camera flies above or
// inside them. The ray is traced through the cloud layer, which follows the curve of the world, so far
// clouds sink to the horizon. At each step inside a cloud, three looks toward the sun (or moon) measure
// how much cloud the light crossed: tops and sunward sides are bright, cores and bases grey, thin edges
// before the sun glow. `behind` is the colour behind the clouds: far clouds fade into it. rgb is the
// colour, a how much of what is behind they hide. (skygen's `march` is its copy.)
fn gs_clouds_along(d: vec3<f32>, behind: vec3<f32>, tmax: f32) -> vec4<f32> {
    let cam = frame.camera_position;
    let r0 = GS_PLANET + cam.y;
    let b = r0 * d.y;
    // Where the ray meets the spheres of the layer's base and top: `near` entering, `far` leaving.
    let low_disc = b * b - (r0 * r0 - (GS_PLANET + GS_CLOUD_LOW) * (GS_PLANET + GS_CLOUD_LOW));
    let high_disc = b * b - (r0 * r0 - (GS_PLANET + GS_CLOUD_HIGH) * (GS_PLANET + GS_CLOUD_HIGH));
    var t0 = 0.0;
    var t1 = 0.0;
    if cam.y < GS_CLOUD_LOW {
        // Below the clouds: up through the base, out through the top.
        if d.y < 0.0 {
            return vec4<f32>(0.0);
        }
        t0 = -b + sqrt(max(low_disc, 0.0));
        t1 = -b + sqrt(max(high_disc, 0.0));
    } else {
        if cam.y > GS_CLOUD_HIGH {
            // Above the clouds: only rays that go down through the top reach them.
            if high_disc < 0.0 || b > 0.0 {
                return vec4<f32>(0.0);
            }
            t0 = -b - sqrt(high_disc);
        }
        // Inside, or after entering from above: on until the ray leaves through the base or the top.
        if low_disc > 0.0 && -b - sqrt(low_disc) > t0 {
            t1 = -b - sqrt(low_disc);
        } else {
            t1 = -b + sqrt(max(high_disc, 0.0));
        }
    }
    t1 = min(min(t1, t0 + 2600.0), tmax);
    if t1 <= t0 {
        return vec4<f32>(0.0);
    }

    let l = frame.light_direction;
    let dayf = gs_dayf();
    let low = gs_sun_low() * dayf;
    let storm = (1.0 - 0.45 * frame.rain) * (1.0 - 0.3 * frame.thunder);
    let flash = vec3<f32>(0.55, 0.65, 0.95) * gs_storm_flash();
    let light = gs_light_color() * 1.3 * storm;
    let cos_t = dot(d, l);
    let phase = clamp(0.6 * gs_henyey(cos_t, 0.6) + 0.4 * gs_henyey(cos_t, -0.25), 0.75, mix(1.7, 3.0, low));
    // The sky's own light on the clouds: blue-white by day, dim violet at sunset, nearly none by night.
    let sky_light = mix(vec3<f32>(0.035, 0.045, 0.08), mix(vec3<f32>(0.8), vec3<f32>(0.22, 0.24, 0.42), low), dayf) * storm;

    let steps = 12 + 10 * i32(cloud_quality);
    let dt = (t1 - t0) / f32(steps);
    // Each ray starts at its own depth, which turns the steps' bands into fine grain.
    let jitter = gs_hash13(d * 731.0);
    var trans = 1.0;
    var sum = vec3<f32>(0.0);
    for (var i = 0; i < steps; i++) {
        let t = t0 + (f32(i) + jitter) * dt;
        let rel = vec3<f32>(d.x * t, r0 + d.y * t, d.z * t);
        let p = vec3<f32>(cam.x + rel.x, length(rel) - GS_PLANET, cam.z + rel.z);
        let dens = gs_cloud_density_at(p, 2);
        if dens <= 0.004 {
            continue;
        }
        let tau = gs_cloud_density_at(p + l * 10.0, 0) * 20.0
            + gs_cloud_density_at(p + l * 42.0, 0) * 45.0
            + gs_cloud_density_at(p + l * 110.0, 0) * 90.0;
        // Light that reaches here directly, or after bouncing about inside the cloud.
        let energy = max(exp(-tau * GS_CLOUD_SIGMA), exp(-tau * GS_CLOUD_SIGMA * 0.25) * 0.7);
        let h = clamp((p.y - GS_CLOUD_LOW) / (GS_CLOUD_HIGH - GS_CLOUD_LOW), 0.0, 1.0);
        let ambient = mix(vec3<f32>(0.34, 0.40, 0.50), vec3<f32>(0.58, 0.70, 0.90), h) * sky_light;
        let lit = light * energy * phase + ambient + flash * (0.4 + 0.6 * energy);
        let a = 1.0 - exp(-dens * dt * GS_CLOUD_SIGMA);
        sum += lit * trans * a;
        trans *= 1.0 - a;
        if trans < 0.02 {
            break;
        }
    }
    let alpha = 1.0 - trans;
    if alpha < 0.001 {
        return vec4<f32>(0.0);
    }
    var col = sum / alpha;
    col = col / (1.0 + 0.35 * col) * 1.2;
    // Far clouds take the colour of the air in front of them.
    col = mix(col, behind, (1.0 - exp(-t0 / 3500.0)) * 0.85);
    return vec4<f32>(col, alpha);
}

// ---- Atmosphere ----

// The colour of the clear sky along a ray: sunlight scattered by the air. Blue overhead, pale at the
// horizon, and at sunrise and sunset the long path through the air leaves the light orange and red.
fn gs_atmosphere(d: vec3<f32>, sun: vec3<f32>) -> vec3<f32> {
    let beta = vec3<f32>(0.10, 0.32, 1.0);
    let up = max(d.y, 0.0);
    let air = 1.0 / (up + 0.12);
    let sun_air = 1.0 / (max(sun.y, 0.0) + 0.08);
    let sun_col = exp(-beta * sun_air * 0.30);
    let scattered = 1.0 - exp(-beta * air * 0.22);
    let cos_t = dot(d, sun);
    let phase = 0.75 * (1.0 + cos_t * cos_t);
    var raw = sun_col * scattered * phase * 5.0;
    // Light that bounced more than once keeps the top of the sky blue when the sun is low.
    raw += vec3<f32>(0.04, 0.10, 0.26) * smoothstep(-0.2, 0.3, sun.y) * (0.4 + 0.6 * up);
    // Haze around the sun.
    raw += sun_col * pow(max(cos_t, 0.0), 8.0) * 0.5;
    // At sunrise and sunset the sky overhead stays blue instead of turning green.
    let low = 1.0 - smoothstep(0.0, 0.35, abs(sun.y));
    raw += vec3<f32>(0.02, 0.04, 0.20) * low * (0.3 + 0.7 * up);
    raw *= vec3<f32>(1.0, 1.0 - 0.3 * low, 1.0);
    var col = 1.0 - exp(-raw * 1.4);
    // The Day blue option deepens the blue overhead.
    let grey = vec3<f32>(gs_luma(col));
    col = mix(grey, col, 1.0 + (day_blue - 1.0) * 0.8 * up);
    return max(col, vec3<f32>(0.0));
}

// The air of the biome at the camera: rgb a tint for the haze, a how thick it is (1 normal). Jungles are
// humid and green-white, deserts dusty and warm, cold biomes clear and blue.
fn gs_biome_air() -> vec4<f32> {
    let temp = frame.temperature;
    let wet = frame.downfall;
    let humid = smoothstep(0.7, 0.95, temp) * smoothstep(0.6, 0.9, wet);
    let dusty = smoothstep(1.2, 1.9, temp) * (1.0 - smoothstep(0.0, 0.3, wet));
    let cold = 1.0 - smoothstep(0.0, 0.3, temp);
    var tint = vec3<f32>(1.0);
    tint = mix(tint, vec3<f32>(0.82, 1.0, 0.88), humid);
    tint = mix(tint, vec3<f32>(1.0, 0.84, 0.6), dusty);
    tint = mix(tint, vec3<f32>(0.8, 0.9, 1.0), cold);
    return vec4<f32>(tint, 1.0 + humid * 1.2 + dusty * 0.6 - cold * 0.3);
}

// ---- Rare events in the sky ----
// Horizon tells a pack no day number, so the chance of an event comes from two things: x, the gap between
// the world's game time and its clock in steps of a minute (it changes whenever the player sleeps or the
// time is set, and is the same all the while otherwise), and y, which third of the session's hour it is
// (a Minecraft day is a third of an hour). The 1/2400 keeps a whole tick off the rounding edge.
fn gs_event_seed() -> vec2<f32> {
    let gap = fract(frame.game_time - frame.day_time + 1.0);
    return vec2<f32>(floor(gap * 20.0 + 0.5 + 1.0 / 2400.0), floor(frame.time / 1200.0));
}

// A solar eclipse, on about one noon in fourteen: x how far the moon's disc stands beside the sun's
// (radians, signed; both discs are 0.04 wide), y how dark it is, 0..1. The moon takes a minute to cross,
// a fifth of it total.
fn gs_solar_eclipse() -> vec2<f32> {
    let phase = (frame.day_time - 0.25) / 0.025;
    let seed = gs_event_seed();
    if frame.dimension != 0 || abs(phase) >= 1.0 || gs_hash13(vec3<f32>(seed, 7.0)) > 0.07 {
        return vec2<f32>(1.0, 0.0);
    }
    let x = sign(phase) * max(abs(phase) - 0.2, 0.0) * 0.125;
    let cover = 1.0 - smoothstep(0.0, 0.085, abs(x));
    return vec2<f32>(x, cover * cover);
}

// A lunar eclipse, on about one midnight in eleven: how deep the moon is in the shadow, 0..1.
fn gs_lunar_eclipse() -> f32 {
    let phase = (frame.day_time - 0.75) / 0.04;
    let seed = gs_event_seed();
    if frame.dimension != 0 || abs(phase) >= 1.0 || gs_hash13(vec3<f32>(seed, 11.0)) > 0.09 {
        return 0.0;
    }
    return smoothstep(1.0, 0.5, abs(phase));
}

// The night sky turning slowly about the zenith, its nebulae billowing: `turns` turns and `swells`
// swells an hour (whole numbers: frame.time wraps hourly), `amount` how far the swell pushes.
fn gs_sky_drift(d: vec3<f32>, turns: f32, swells: f32, amount: f32) -> vec3<f32> {
    let a = frame.time * turns * 0.0017453293;
    let r = vec3<f32>(d.x * cos(a) - d.z * sin(a), d.y, d.x * sin(a) + d.z * cos(a));
    let ph = frame.time * swells * 0.0017453293;
    return normalize(r + amount * (sin(r.yzx * 6.0 + vec3<f32>(ph)) + 0.5 * sin(r.zxy * 11.0 - vec3<f32>(2.0 * ph))));
}

// ---- The End ----
// Toward the End's black hole: it hangs over the main island as seen from the arrival platform.
const GS_END_EYE: vec3<f32> = vec3<f32>(-0.7454, 0.5963, 0.2981);
const GS_END_LIGHT: vec3<f32> = vec3<f32>(0.62, 0.4, 1.0);

// The black hole along a ray: a black disc, a thin bright ring of bent light around it and a glowing
// disc of dust seen nearly edge-on, turning once a minute (frame.time wraps hourly, so whole turns only).
// rgb is the light, a how much of the sky behind is hidden.
fn gs_end_eye(d: vec3<f32>) -> vec4<f32> {
    let z = dot(d, GS_END_EYE);
    if z < 0.55 {
        return vec4<f32>(0.0);
    }
    let right = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), GS_END_EYE));
    let up = cross(GS_END_EYE, right);
    let p = vec2<f32>(dot(d, right), dot(d, up)) / z;
    let r0 = 0.11;
    let r = length(p) / r0;
    // The dust disc: tilted 15 degrees and squashed, its lower half in front of the hole.
    let q = vec2<f32>(p.x * 0.966 + p.y * 0.259, (p.y * 0.966 - p.x * 0.259) * 5.5) / r0;
    let dr = length(q);
    let spin = frame.time * 0.104719755;
    let cs = vec2<f32>(cos(spin + dr * 0.8), sin(spin + dr * 0.8));
    let turned = vec2<f32>(q.x * cs.x - q.y * cs.y, q.x * cs.y + q.y * cs.x);
    let streaks = 0.45 + 0.55 * gs_noise(vec3<f32>(turned * 1.6, dr * 3.0));
    var disc = smoothstep(1.25, 1.7, dr) * (1.0 - smoothstep(2.4, 4.6, dr)) * streaks;
    disc *= 0.65 + 0.35 * q.x / max(dr, 0.001);
    if r < 1.0 && q.y > 0.0 {
        disc = 0.0;
    }
    let ring = smoothstep(0.98, 1.03, r) * exp(-(r - 1.0) * 9.0);
    let glow = exp(-r * 0.55) * smoothstep(0.98, 1.2, r);
    let disc_col = mix(vec3<f32>(1.0, 0.9, 1.0), vec3<f32>(0.7, 0.2, 1.0), smoothstep(1.5, 3.8, dr));
    let rgb = disc_col * disc * 1.5 + vec3<f32>(1.0, 0.75, 1.0) * ring * 1.4 + vec3<f32>(0.4, 0.12, 0.7) * glow * 0.6;
    return vec4<f32>(rgb, max(1.0 - smoothstep(0.97, 1.0, r), min(disc, 1.0)));
}

// The End's sky: the night sky's nebulae in violet and teal, turning once an hour, mirrored into the void
// below, stars, and the black hole.
fn gs_end_sky(d: vec3<f32>) -> vec3<f32> {
    let e = gs_sky_drift(d, 6.0, 60.0, 0.06);
    let u = atan2(e.z, e.x) / 6.2831853 + 0.5;
    let v = (1.5707963 - asin(clamp(abs(e.y), 0.0, 1.0))) / 1.8849556;
    let t = textureSampleLevel(night_sky, night_sky_sampler, vec2<f32>(u, clamp(v, 0.001, 0.999)), 0.0).rgb;
    let lum = gs_luma(t);
    let teal = smoothstep(0.35, 0.7, gs_noise(d * 2.5 + vec3<f32>(4.0, 1.0, 7.0)));
    var col = mix(vec3<f32>(0.75, 0.2, 1.0), vec3<f32>(0.15, 0.9, 0.7), teal) * lum * 2.2;
    col += vec3<f32>(0.03, 0.012, 0.06) + vec3<f32>(0.07, 0.02, 0.12) * pow(1.0 - abs(d.y), 3.0);
    let cell = floor(d * 140.0);
    let h = gs_hash13(cell);
    if h > 0.93 {
        let star = normalize(cell + gs_hash33(cell) * 0.6 + vec3<f32>(0.2));
        col += vec3<f32>(0.85, 0.8, 1.0) * smoothstep(0.3, 0.0, length(d - star) * 140.0) * (h - 0.93) * 20.0;
    }
    let eye = gs_end_eye(d);
    return col * (1.0 - eye.a) + eye.rgb;
}
