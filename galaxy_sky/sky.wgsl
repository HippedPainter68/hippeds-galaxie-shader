// Galaxy Sky: the sky. By day sunlight scattered by the air with volumetric clouds; by night the pack's
// painted sky (night_sky.png: a blue gas giant with its moons over glowing nebulae) under sharp twinkling
// stars and, in cold biomes now and then, an aurora. The giant and its moons show by day too, pale behind
// the air. The sun, the moon and the stars are drawn here (the manifest turns Horizon's own off).
override galaxy_brightness: f32 = 1.0;
override star_density: f32 = 0.5;
override aurora: f32 = 1.0;

// The painted nebulae along a ray. u is the compass direction, v runs from the zenith (0) to 18 degrees
// below the horizon (1): skygen/src/main.rs paints it that way.
fn gs_sky_image(d: vec3<f32>) -> vec3<f32> {
    let u = atan2(d.z, d.x) / 6.2831853 + 0.5;
    let v = (1.5707963 - asin(clamp(d.y, -1.0, 1.0))) / 1.8849556;
    return textureSampleLevel(night_sky, night_sky_sampler, vec2<f32>(u, clamp(v, 0.001, 0.999)), 0.0).rgb;
}

// The giant and its moons along a ray: a flat picture held up toward the giant in the north, 36 degrees
// up, covering 26 degrees to each side (skygen's GIANT and BODIES_SPAN). rgb is the colour times the
// coverage, a the coverage.
fn gs_sky_bodies(d: vec3<f32>) -> vec4<f32> {
    let centre = vec3<f32>(0.0, 0.5877853, -0.8090170);
    let right = vec3<f32>(-1.0, 0.0, 0.0);
    let up = vec3<f32>(0.0, 0.8090170, 0.5877853);
    let z = dot(d, centre);
    if z < 0.5 {
        return vec4<f32>(0.0);
    }
    let p = vec2<f32>(dot(d, right), dot(d, up)) / (z * 0.4877326);
    if abs(p.x) >= 0.998 || abs(p.y) >= 0.998 {
        return vec4<f32>(0.0);
    }
    var out = textureSampleLevel(sky_bodies, sky_bodies_sampler, vec2<f32>(0.5 + p.x * 0.5, 0.5 - p.y * 0.5), 0.0);

    // The painted picture gives the shapes; the surfaces come from planet_maps.png, turned by the time,
    // and are lit here the way skygen lights them. xyz the direction, w the sine of the angular radius;
    // turns an hour (whole numbers: frame.time wraps hourly).
    var body = array<vec4<f32>, 5>(
        vec4<f32>(0.0, 0.5878, -0.8090, 0.2588), vec4<f32>(0.1853, 0.4540, -0.8715, 0.04711),
        vec4<f32>(-0.2825, 0.7986, -0.5314, 0.02967), vec4<f32>(0.2890, 0.7880, -0.5436, 0.02007),
        vec4<f32>(-0.3234, 0.3256, -0.8885, 0.01222));
    var turns = array<f32, 5>(10.0, 24.0, -18.0, 36.0, 45.0);
    for (var i = 0; i < 5; i++) {
        let b = body[i];
        let t1 = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), b.xyz));
        let t2 = cross(b.xyz, t1);
        let off = d - b.xyz * dot(d, b.xyz);
        let q = vec2<f32>(dot(off, t1), dot(off, t2)) / b.w;
        let r = length(q);
        if r >= 1.0 || dot(d, b.xyz) < 0.0 {
            continue;
        }
        let n = vec3<f32>(q, sqrt(1.0 - r * r));
        var s = n;
        var v = 0.0;
        if i == 0 {
            // The giant turns about its tilted axis.
            s = vec3<f32>(n.x * 0.9492 - n.y * 0.3146, n.x * 0.3146 + n.y * 0.9492, n.z);
            v = clamp(0.5 - asin(s.y) / 3.1415927, 0.004, 0.996) / 1.5;
        } else {
            v = (8.0 + f32(i - 1) + clamp(0.5 - asin(s.y) / 3.1415927, 0.12, 0.88)) / 12.0;
        }
        let u = atan2(s.x, s.z) / 6.2831853 - frame.time * turns[i] / 3600.0;
        var c = textureSampleLevel(planet_maps, planet_maps_sampler, vec2<f32>(u, v), 0.0).rgb;
        let ndl = dot(n, vec3<f32>(-0.6211, 0.4208, 0.6612));
        let lit = smoothstep(-0.08, 0.30, ndl) * (0.25 + 0.75 * pow(max(ndl, 0.0), 0.8));
        c *= (0.55 + 0.45 * sqrt(n.z)) * (lit * 1.15 + 0.012);
        if i == 0 {
            c += vec3<f32>(0.25, 0.55, 1.0) * pow(1.0 - n.z, 3.0) * (0.15 + 0.85 * lit) * 0.7;
            c += vec3<f32>(0.02, 0.05, 0.12) * (1.0 - lit) * 0.5;
        }
        let cover = 1.0 - smoothstep(1.0 - clamp(0.0015 / b.w, 0.01, 0.3), 1.0, r);
        out = out * (1.0 - cover) + vec4<f32>(c * cover, cover);
    }
    return out;
}

// Stars: one per cell of a fine grid over the sky, each with its own brightness, colour and twinkle.
fn gs_star_layer(d: vec3<f32>, t: f32, scale: f32, chance: f32, size: f32) -> vec3<f32> {
    let cell = floor(d * scale);
    let h = gs_hash13(cell);
    if h < 1.0 - chance {
        return vec3<f32>(0.0);
    }
    // The star sits where its cell's point lies on the sky, so it shows from wherever the cell is seen.
    let star_dir = normalize(cell + gs_hash33(cell + vec3<f32>(3.0)) * 0.6 + vec3<f32>(0.2));
    let dist = length(d - star_dir) * scale;
    let core = smoothstep(size, 0.0, dist);
    let k = gs_hash13(cell + vec3<f32>(7.0));
    let bright = mix(0.45, 1.6, pow(k, 3.0));
    let twinkle = 0.75 + 0.25 * sin(t * (1.5 + h * 4.0) + h * 60.0);
    // Most stars are white, some bluish, some warm.
    let colour = mix(vec3<f32>(0.75, 0.85, 1.0), vec3<f32>(1.0, 0.85, 0.7), gs_hash13(cell + vec3<f32>(11.0)));
    return mix(vec3<f32>(1.0), colour, 0.6) * core * bright * twinkle;
}

// Two layers: fewer bright stars, and many faint ones behind them.
fn gs_stars(d: vec3<f32>, t: f32) -> vec3<f32> {
    return gs_star_layer(d, t, 110.0, 0.08 * star_density, 0.3)
        + gs_star_layer(d, t, 230.0, 0.12 * star_density, 0.35) * 0.45;
}

// Aurora: curtains of green light turning violet higher up, with fine vertical rays. Only where the biome
// at the camera is cold, and only now and then: it fades in and out over minutes.
fn gs_aurora(d: vec3<f32>) -> vec3<f32> {
    let cold = 1.0 - smoothstep(0.0, 0.2, frame.temperature);
    if aurora <= 0.0 || cold <= 0.0 || d.y < 0.05 {
        return vec3<f32>(0.0);
    }
    let t = frame.time;
    let showing = smoothstep(0.55, 0.72, gs_noise(vec3<f32>(t * 0.008, 3.3, 9.1)));
    if showing <= 0.0 {
        return vec3<f32>(0.0);
    }
    let p = d.xz / (d.y + 0.25);
    var glow = 0.0;
    for (var k = 0; k < 3; k++) {
        let q = p * (1.0 + 0.15 * f32(k));
        let wave = gs_noise(vec3<f32>(q.x * 1.2 + t * 0.02, q.y * 0.3, t * 0.03 + f32(k) * 5.0));
        let curtain = pow(clamp(1.0 - abs(wave - 0.5) * 4.0, 0.0, 1.0), 3.0);
        let rays = 0.55 + 0.45 * gs_noise(vec3<f32>(q.x * 14.0, q.y * 2.0, t * 0.2));
        glow += curtain * rays;
    }
    let colour = mix(vec3<f32>(0.1, 1.0, 0.45), vec3<f32>(0.55, 0.2, 0.9), smoothstep(0.25, 0.8, d.y));
    let shape = smoothstep(0.05, 0.25, d.y) * (1.0 - smoothstep(0.75, 1.0, d.y));
    return colour * glow * 0.4 * shape * cold * showing * aurora;
}

// Shooting stars: time is cut into slots of GS_METEOR_SLOT seconds, and in about one slot of five a
// single streak crosses a random part of the upper sky in under a second: on average one a minute.
const GS_METEOR_SLOT: f32 = 12.0;

fn gs_meteor(d: vec3<f32>) -> vec3<f32> {
    let slot = floor(frame.time / GS_METEOR_SLOT);
    let seed = vec3<f32>(slot, 17.0, 4.0);
    let p = (frame.time - slot * GS_METEOR_SLOT) / 0.8;
    if p > 1.0 || gs_hash13(seed) > 0.2 || d.y < 0.0 {
        return vec3<f32>(0.0);
    }
    let r = gs_hash33(seed) - 0.5;
    let start = normalize(vec3<f32>(r.x, abs(r.y) + 0.25, r.z));
    let along = normalize(cross(start, gs_hash33(seed + vec3<f32>(9.0)) - 0.5));
    // The head runs just under 30 degrees; the tail follows a third of the way behind.
    let head = normalize(start + along * 0.5 * p);
    let tail = normalize(start + along * 0.5 * max(p - 0.3, 0.0));
    let seg = head - tail;
    let h = clamp(dot(d - tail, seg) / max(dot(seg, seg), 1.0e-6), 0.0, 1.0);
    let off = length(d - (tail + seg * h));
    let streak = smoothstep(0.0035, 0.0, off) * h * h + smoothstep(0.008, 0.0, length(d - head));
    return vec3<f32>(0.85, 0.93, 1.0) * streak * sin(p * 3.1415927) * 1.6;
}

// A great comet, in about one stretch of nights in five (a stretch lasts until the player sleeps or the
// time is set), drawn after photographs of Hale-Bopp and NEOWISE: a tiny bright nucleus in a green-cyan
// coma; a broad, curved dust tail that fans out behind the orbit with faint striations and fades over
// some 30 degrees; and a narrow, straight blue ion tail with streamers, both pointing away from the sun.
// It wanders about 20 degrees a night, back and forth over the hour frame.time runs.
fn gs_comet(d: vec3<f32>) -> vec3<f32> {
    let seed = gs_event_seed().x;
    if gs_hash13(vec3<f32>(seed, 3.0, 1.0)) > 0.2 {
        return vec3<f32>(0.0);
    }
    let h = gs_hash33(vec3<f32>(seed, 8.0, 2.0));
    let swing = frame.time * 0.0017453293;
    let az = h.x * 6.2831853 + 0.35 * sin(swing);
    let el = 0.45 + 0.35 * h.y + 0.08 * sin(swing * 2.0);
    let c = vec3<f32>(cos(el) * cos(az), sin(el), cos(el) * sin(az));
    let z = dot(d, c);
    if z < 0.5 {
        return vec3<f32>(0.0);
    }
    // Sky coordinates around the head, gnomonic so the long tails stay straight: x away from the sun.
    let sun = frame.sun_direction;
    let away = normalize(c * dot(sun, c) - sun);
    let side = normalize(cross(c, away));
    let p = vec2<f32>(dot(d, away), dot(d, side)) / z;
    let r = length(p);
    let s = max(p.x, 0.0);

    let nucleus = exp(-r * r * 60000.0) * 2.2;
    let coma = exp(-r * 90.0) * 0.4 + exp(-r * r * 1500.0) * 0.25;

    // Ion tail: narrow and straight, streamers drifting slowly outward.
    let ion_w = 0.003 + s * 0.03;
    let streamers = 0.5 + 0.5 * gs_noise(vec3<f32>(p.y / ion_w * 2.5, s * 5.0 - frame.time * 0.01, 7.0));
    let ion = exp(-pow(p.y / ion_w, 2.0)) * exp(-s * 2.4) * smoothstep(0.0, 0.03, p.x) * streamers;

    // Dust tail: bends behind the orbit and fans out; striations run out from the nucleus.
    let dy = p.y - s * s * 0.7;
    let dust_w = 0.008 + s * 0.3;
    let striae = 0.7 + 0.3 * gs_noise(vec3<f32>(dy / (s + 0.015) * 12.0, s * 1.2, 3.0));
    let dust = exp(-pow(dy / dust_w, 2.0)) * exp(-s * 2.2) * smoothstep(-0.01, 0.04, p.x) * striae;

    return vec3<f32>(1.0, 0.98, 0.92) * nucleus + vec3<f32>(0.6, 1.0, 0.85) * coma
        + vec3<f32>(0.3, 0.55, 1.0) * ion * 0.16 + vec3<f32>(1.0, 0.9, 0.72) * dust * 0.85;
}

// The moon: a round, cratered ball (planet_maps.png's grey moon, its face always toward the world) in
// the phase Horizon's moon has, the terminator soft, a faint earthshine on the dark side. 4 degrees across
// (Minecraft's square was 11). rgb its light, a how much of the sky behind it it hides.
fn gs_moon(d: vec3<f32>) -> vec4<f32> {
    let m = frame.moon_direction;
    let rad = 0.035;
    let up_ref = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(m.y) > 0.99);
    let t1 = normalize(cross(up_ref, m));
    let t2 = cross(m, t1);
    let off = d - m * dot(d, m);
    let q = vec2<f32>(dot(off, t1), dot(off, t2)) / rad;
    let r = length(q);
    if r >= 1.0 || dot(d, m) < 0.0 {
        return vec4<f32>(0.0);
    }
    let n = vec3<f32>(q, sqrt(1.0 - r * r));
    // Phase 0 full, 4 new: the light comes from the viewer's side at full moon, from behind at new moon;
    // waning moons are lit on one side, waxing ones on the other.
    let a = f32(frame.moon_phase) * 0.7853982;
    let l = vec3<f32>(-sin(a), 0.0, cos(a));
    let lit = smoothstep(-0.04, 0.1, dot(n, l));
    let u = atan2(n.x, n.z) / 12.566371 + 0.25;
    let v = (8.0 + clamp(0.5 - asin(n.y) / 3.1415927, 0.12, 0.88)) / 12.0;
    let tex = textureSampleLevel(planet_maps, planet_maps_sampler, vec2<f32>(u, v), 0.0).rgb;
    // Dark grey seas, bright highlands and crater rims.
    let grey = mix(vec3<f32>(0.33, 0.33, 0.36), vec3<f32>(0.93, 0.92, 0.88), smoothstep(0.12, 0.7, gs_luma(tex)));
    let limb = 0.75 + 0.25 * sqrt(n.z);
    let rgb = grey * limb * (lit * 1.05 + 0.035);
    let cover = 1.0 - smoothstep(0.97, 1.0, r);
    return vec4<f32>(rgb * cover, cover);
}

fn sky(input: SkyInput) -> vec4<f32> {
    // Only the Overworld gets this sky; the Nether and the End keep vanilla's.
    if frame.dimension != 0 {
        return input.color;
    }
    let d = input.direction;
    let sun = frame.sun_direction;
    // A solar eclipse turns the day sky to dusk: the stars come out.
    let ecl = gs_solar_eclipse();
    let dayf = gs_dayf() * (1.0 - 0.88 * ecl.y);
    let clear = 1.0 - frame.rain;
    let ecl_side = normalize(cross(sun, vec3<f32>(0.0, 0.0, 1.0)));
    let ecl_moon = normalize(sun + ecl_side * ecl.x);
    let hidden = 1.0 - smoothstep(0.040, 0.043, acos(clamp(dot(d, ecl_moon), -1.0, 1.0)));
    let bodies = gs_sky_bodies(d);

    // Day: the scattered sky, greyer in rain, and the sun's disc in the colour its light arrives with.
    var day = gs_atmosphere(d, sun);
    // The giant and its moons hang in the day sky like the moon does: their lit parts pale through the
    // air, their dark parts the colour of the sky.
    let body = clamp(gs_luma(bodies.rgb) * 1.6, 0.0, 1.0);
    day = mix(day, day * 0.65 + bodies.rgb * 0.35 + vec3<f32>(0.55, 0.62, 0.7) * body, body * 0.75);
    day = mix(day, vec3<f32>(gs_luma(day)) * 0.7, frame.rain * 0.75);
    let toward = max(dot(d, sun), 0.0);
    day += gs_light_color() * smoothstep(0.9992, 0.9996, toward) * 2.5 * clear * (1.0 - hidden);
    // The moon by day: its lit part pale through the air, its dark part the colour of the sky.
    let moon = gs_moon(d);
    day += moon.rgb * 0.45 * clear;

    // Night: the painted sky, the nebulae brightened by the option, stars everywhere but in front of the
    // giant and its moons, a glow around the moon, the aurora.
    // The nebulae and the stars turn once an hour; the nebulae also billow.
    var night = gs_sky_image(gs_sky_drift(d, 1.0, 20.0, 0.025)) * 1.6 * galaxy_brightness
        + gs_stars(gs_sky_drift(d, 1.0, 0.0, 0.0), frame.time);
    // The giant's blue glow, around the giant itself (it used to be painted into the turning panorama
    // and drifted off as a second disc).
    let giant_ang = acos(clamp(dot(d, vec3<f32>(0.0, 0.5878, -0.8090)), -1.0, 1.0));
    night += vec3<f32>(0.10, 0.30, 0.55) * 0.3 * exp(-max(giant_ang - 0.2618, 0.0) / 0.2618 * 5.0);
    night = night * (1.0 - bodies.a) + bodies.rgb;
    // The moon hides the stars behind it; its glow grows with the lit part.
    night = night * (1.0 - moon.a) + moon.rgb;
    let moon_lit = 0.5 + 0.5 * cos(f32(frame.moon_phase) * 0.7853982);
    night += vec3<f32>(0.15, 0.2, 0.35) * pow(max(dot(d, frame.moon_direction), 0.0), 24.0) * 0.4 * moon_lit;
    night += gs_aurora(d) + gs_meteor(d) + gs_comet(d);
    night *= 1.0 - 0.8 * frame.rain;

    var col = mix(night, day, dayf);
    if ecl.y > 0.0 {
        // The moon's black disc, the corona streaming out around it at totality, and a sunset glow
        // all around the horizon.
        col = mix(col, vec3<f32>(0.004, 0.005, 0.01), hidden * smoothstep(0.1, 0.5, ecl.y));
        let ang = acos(clamp(toward, -1.0, 1.0));
        let around = vec2<f32>(dot(d, ecl_side), dot(d, cross(ecl_side, sun))) / max(sin(ang), 0.001);
        let streaks = 0.45 + 0.75 * gs_noise(vec3<f32>(around * 3.5, 2.0)) * gs_noise(vec3<f32>(around * 9.0, 5.0));
        let corona = (exp(-max(ang - 0.04, 0.0) * 16.0) * streaks + exp(-max(ang - 0.04, 0.0) * 70.0))
            * smoothstep(0.7, 1.0, ecl.y) * (1.0 - hidden) * step(0.0, toward);
        col += vec3<f32>(1.0, 0.96, 0.9) * corona * 1.2 * clear;
        col += vec3<f32>(0.9, 0.45, 0.2) * pow(1.0 - max(d.y, 0.0), 6.0) * 0.3 * ecl.y * clear;
    }
    let clouds = gs_clouds_along(d, col, 1.0e9);
    col = mix(col, clouds.rgb * (1.0 - 0.8 * ecl.y), clouds.a);
    let storm_sky = mix(vec3<f32>(0.012, 0.018, 0.03), vec3<f32>(0.17, 0.21, 0.28), dayf);
    col = mix(col, storm_sky, frame.rain * frame.thunder * 0.35);
    col += vec3<f32>(0.35, 0.45, 0.7) * gs_storm_flash() * 0.3;
    return vec4<f32>(gs_linear(clamp(col, vec3<f32>(0.0), vec3<f32>(1.0))), 1.0);
}
