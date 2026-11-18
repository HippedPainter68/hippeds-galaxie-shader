//! Paints galaxy_sky's two textures.
//!
//! `night_sky.png` (2048 x 1024, RGBA): the night sky as a panorama. u is the compass direction
//! (`atan2(z, x)`), v runs from the zenith (0) down to 18 degrees below the horizon (1). It holds a
//! huge blue gas giant in the north with four moons and glowing nebulae; alpha is 1 on the planet and
//! the moons, so the shader can show them by day too. Stars are not painted: the shader draws them
//! sharp and twinkling.
//!
//! `cloud_noise.png` (512 x 512, RGBA, tiles): R the clouds' shapes (Perlin noise carved by cells),
//! G fine cell detail for their edges, B a second soft noise for where the sky is clearer.

use std::f32::consts::PI;
use std::fs::File;
use std::io::BufWriter;
use std::path::Path;

type V3 = [f32; 3];

fn add(a: V3, b: V3) -> V3 { [a[0] + b[0], a[1] + b[1], a[2] + b[2]] }
fn sub(a: V3, b: V3) -> V3 { [a[0] - b[0], a[1] - b[1], a[2] - b[2]] }
fn mul(a: V3, k: f32) -> V3 { [a[0] * k, a[1] * k, a[2] * k] }
fn mulv(a: V3, b: V3) -> V3 { [a[0] * b[0], a[1] * b[1], a[2] * b[2]] }
fn dot(a: V3, b: V3) -> f32 { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
fn cross(a: V3, b: V3) -> V3 {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}
fn norm(a: V3) -> V3 { mul(a, 1.0 / dot(a, a).sqrt()) }
fn mix(a: f32, b: f32, t: f32) -> f32 { a + (b - a) * t }
fn mix3(a: V3, b: V3, t: f32) -> V3 { add(mul(a, 1.0 - t), mul(b, t)) }
fn sat(x: f32) -> f32 { x.clamp(0.0, 1.0) }
fn smoothstep(a: f32, b: f32, x: f32) -> f32 {
    let t = sat((x - a) / (b - a));
    t * t * (3.0 - 2.0 * t)
}

fn hash(x: i32, y: i32, z: i32, seed: u32) -> u32 {
    let mut h = (x as u32).wrapping_mul(0x8da6_b343)
        ^ (y as u32).wrapping_mul(0xd816_3841)
        ^ (z as u32).wrapping_mul(0xcb1a_b31f)
        ^ seed.wrapping_mul(0x9e37_79b9);
    h ^= h >> 15;
    h = h.wrapping_mul(0x2c1b_3c6d);
    h ^= h >> 12;
    h = h.wrapping_mul(0x297a_2d39);
    h ^ (h >> 15)
}

fn hash01(x: i32, y: i32, z: i32, seed: u32) -> f32 {
    (hash(x, y, z, seed) & 0xff_ffff) as f32 / 16_777_216.0
}

fn grad(h: u32, x: f32, y: f32, z: f32) -> f32 {
    match h & 15 {
        0 => x + y, 1 => -x + y, 2 => x - y, 3 => -x - y,
        4 => x + z, 5 => -x + z, 6 => x - z, 7 => -x - z,
        8 => y + z, 9 => -y + z, 10 => y - z, 11 => -y - z,
        12 => x + y, 13 => -x + y, 14 => -y + z, _ => -y - z,
    }
}

fn fade(t: f32) -> f32 { t * t * t * (t * (t * 6.0 - 15.0) + 10.0) }

/// Perlin noise, about -1..1. `period` > 0 makes x and y repeat every `period` lattice cells.
fn perlin(p: V3, seed: u32, period: i32) -> f32 {
    let (fx, fy, fz) = (p[0].floor(), p[1].floor(), p[2].floor());
    let (x0, y0, z0) = (fx as i32, fy as i32, fz as i32);
    let (x, y, z) = (p[0] - fx, p[1] - fy, p[2] - fz);
    let (u, v, w) = (fade(x), fade(y), fade(z));
    let wrap = |i: i32| if period > 0 { i.rem_euclid(period) } else { i };
    let g = |dx: i32, dy: i32, dz: i32| {
        grad(hash(wrap(x0 + dx), wrap(y0 + dy), z0 + dz, seed), x - dx as f32, y - dy as f32, z - dz as f32)
    };
    let a = mix(mix(g(0, 0, 0), g(1, 0, 0), u), mix(g(0, 1, 0), g(1, 1, 0), u), v);
    let b = mix(mix(g(0, 0, 1), g(1, 0, 1), u), mix(g(0, 1, 1), g(1, 1, 1), u), v);
    mix(a, b, w)
}

/// Octaves of Perlin noise, 0..1.
fn fbm(p: V3, octaves: u32, seed: u32) -> f32 {
    let (mut sum, mut amp, mut freq, mut total) = (0.0, 0.5, 1.0, 0.0);
    for i in 0..octaves {
        sum += amp * perlin(mul(p, freq), seed + i, 0);
        total += amp;
        amp *= 0.5;
        freq *= 2.02;
    }
    sat(0.5 + 0.5 * sum / total * 1.6)
}

/// Wispy ridges, 0..1.
fn ridged(p: V3, octaves: u32, seed: u32) -> f32 {
    let (mut sum, mut amp, mut freq, mut total) = (0.0, 0.5, 1.0, 0.0);
    for i in 0..octaves {
        let n = 1.0 - perlin(mul(p, freq), seed + i, 0).abs() * 1.8;
        sum += amp * n.max(0.0).powi(2);
        total += amp;
        amp *= 0.5;
        freq *= 2.1;
    }
    sum / total
}

/// A round body in the sky.
struct Body {
    dir: V3,
    /// Angular radius, radians.
    radius: f32,
    seed: u32,
    giant: bool,
    colour: V3,
}

/// Where the light comes from, in a body's own frame (x right, y up, z toward the viewer).
const LIGHT: V3 = [-0.62, 0.42, 0.66];

fn from_angles(az_deg: f32, el_deg: f32) -> V3 {
    let (az, el) = (az_deg.to_radians(), el_deg.to_radians());
    [el.cos() * az.cos(), el.sin(), el.cos() * az.sin()]
}

/// The colour of the gas giant's cloud tops at a point of its sphere.
fn giant_surface(n: V3, seed: u32) -> V3 {
    // Tilt the axis a little.
    let tilt = 0.32f32;
    let x = n[0] * tilt.cos() - n[1] * tilt.sin();
    let y = n[0] * tilt.sin() + n[1] * tilt.cos();
    let p = [x, y, n[2]];
    // Bands by latitude, pushed around by turbulence that is stretched along them.
    let turb = fbm([p[0] * 2.5, p[1] * 9.0, p[2] * 2.5], 6, seed) - 0.5;
    let swirl = fbm([p[0] * 6.0, p[1] * 16.0, p[2] * 6.0], 5, seed + 20) - 0.5;
    let lat = y + turb * 0.16 + swirl * 0.04;
    let f = lat * 9.0;
    let deep = [0.05, 0.13, 0.40];
    let azure = [0.16, 0.42, 0.78];
    let pale = [0.70, 0.86, 0.95];
    let violet = [0.30, 0.24, 0.62];
    let teal = [0.10, 0.55, 0.62];
    let mut c = mix3(deep, azure, 0.5 + 0.5 * (f * PI).sin());
    c = mix3(c, pale, smoothstep(0.35, 0.95, (f * 2.3 + 1.0).sin()) * 0.75);
    c = mix3(c, violet, smoothstep(0.5, 1.0, (f * 1.3 - 2.0).sin()) * 0.55);
    c = mix3(c, teal, smoothstep(0.6, 1.0, (f * 0.7 + 0.6).sin()) * 0.5);
    // Fine streaks.
    let streak = fbm([p[0] * 5.0, p[1] * 60.0, p[2] * 5.0], 4, seed + 40);
    c = mul(c, 0.8 + 0.4 * streak);
    // The great storm: a pale oval eye with a dark rim, in the southern half.
    let lon = x.atan2(n[2]);
    let (sx, sy) = ((lon + 0.25) / 0.34, (y + 0.36) / 0.13);
    let d = sx * sx + sy * sy;
    let spin = fbm([sx * 3.0 + d * 2.0, sy * 3.0 - d * 2.0, 1.0], 4, seed + 60);
    let eye = (-d * 1.6).exp();
    c = mix3(c, mul([0.95, 0.90, 0.86], 0.75 + 0.35 * spin), eye * 0.85);
    c = mul(c, 1.0 - 0.45 * smoothstep(0.9, 1.3, d) * (1.0 - smoothstep(1.3, 2.4, d)));
    c
}

/// The colour of a rocky or icy moon.
fn moon_surface(n: V3, seed: u32, colour: V3) -> V3 {
    let p = add(mul(n, 2.2), [seed as f32 * 3.1, 0.0, 0.0]);
    let rough = fbm(p, 6, seed);
    let seas = smoothstep(0.42, 0.62, fbm(mul(p, 0.7), 4, seed + 9));
    let craters = ridged(mul(p, 3.0), 4, seed + 17);
    mul(colour, (0.55 + 0.6 * rough) * (1.0 - 0.35 * seas) * (0.85 + 0.3 * craters))
}

/// The empty sky behind everything: deep blue, glowing nebulae along a band, dark dust.
fn nebula(d: V3) -> V3 {
    let horizon = (1.0 - d[1].max(0.0)).powi(3);
    let mut c = mix3([0.006, 0.010, 0.028], [0.015, 0.050, 0.075], horizon);
    let w = [fbm(mul(d, 2.0), 4, 100) - 0.5, fbm(mul(d, 2.0), 4, 110) - 0.5, fbm(mul(d, 2.0), 4, 120) - 0.5];
    let p = add(mul(d, 2.0), mul(w, 1.6));
    let plane = norm([0.35, 1.0, -0.45]);
    let h = dot(d, plane);
    let band = (-h * h * 5.0).exp();
    let wisps = ridged(mul(p, 1.6), 5, 200);
    let teal = smoothstep(0.42, 0.80, fbm(mul(p, 1.4), 6, 300));
    let magenta = smoothstep(0.50, 0.85, fbm(add(mul(p, 1.9), [10.0, 0.0, 0.0]), 6, 400));
    let blue = fbm(mul(p, 0.8), 4, 500);
    c = add(c, mul([0.04, 0.52, 0.58], teal * (0.2 + 0.8 * band) * (0.35 + 0.9 * wisps) * 0.55));
    c = add(c, mul([0.55, 0.12, 0.62], magenta * band * (0.4 + 0.8 * wisps) * 0.5));
    c = add(c, mul([0.08, 0.16, 0.55], blue * (0.25 + 0.75 * band) * 0.22));
    // A warm bright core where the band is thickest.
    let core = (-(1.0 - dot(d, norm([0.75, 0.42, 0.5]))) * 14.0).exp();
    c = add(c, mul([0.95, 0.70, 0.50], core * band * 0.35 * (0.5 + wisps)));
    // Dust lanes.
    let dust = smoothstep(0.52, 0.74, fbm(add(mul(p, 2.6), [20.0, 5.0, 0.0]), 6, 600));
    c = mul(c, 1.0 - 0.75 * dust * band);
    c
}

/// One sample of the sky behind the bodies: the nebulae only. The giant's glow is drawn by the shader
/// (sky.wgsl), because the panorama turns and the giant does not: painted in here, the glow drifted
/// away from the giant as a second blue disc.
fn background_sample(d: V3, _bodies: &[Body]) -> [f32; 4] {
    let c = nebula(d);
    [c[0], c[1], c[2], 1.0]
}

/// One sample of the giant and its moons: rgb times coverage, and the coverage.
fn bodies_sample(d: V3, bodies: &[Body]) -> [f32; 4] {
    let mut c = [0.0f32; 3];
    let mut alpha = 0.0f32;
    for b in bodies {
        let ang = dot(d, b.dir).clamp(-1.0, 1.0).acos();
        if ang >= b.radius {
            continue;
        }
        let t1 = norm(cross([0.0, 1.0, 0.0], b.dir));
        let t2 = cross(b.dir, t1);
        let off = sub(d, mul(b.dir, dot(d, b.dir)));
        let k = 1.0 / b.radius.sin();
        let (x, y) = (dot(off, t1) * k, dot(off, t2) * k);
        let r2 = (x * x + y * y).min(1.0);
        let z = (1.0 - r2).sqrt();
        let n = [x, y, z];
        let ndl = dot(n, norm(LIGHT));
        let lit = smoothstep(-0.08, 0.30, ndl) * (0.25 + 0.75 * ndl.max(0.0).powf(0.8));
        let mut s = if b.giant { giant_surface(n, b.seed) } else { moon_surface(n, b.seed, b.colour) };
        // Darker toward the limb, a thin blue atmosphere on the giant, a faint glow on its night side.
        s = mul(s, 0.55 + 0.45 * z.powf(0.5));
        let mut out = mul(s, lit * 1.15 + 0.012);
        if b.giant {
            let rim = (1.0 - z).powi(3);
            out = add(out, mul([0.25, 0.55, 1.0], rim * (0.15 + 0.85 * lit) * 0.7));
            out = add(out, mul([0.02, 0.05, 0.12], (1.0 - lit) * 0.5));
        }
        // The 2 x 2 samples a pixel soften the edge; a later body covers an earlier one.
        c = out;
        alpha = 1.0;
    }
    [c[0], c[1], c[2], alpha]
}

/// The giant is the centre of the bodies' picture, which covers this many degrees to each side of it.
const GIANT: (f32, f32) = (-90.0, 36.0);
const BODIES_SPAN: f32 = 26.0;

fn bodies() -> [Body; 5] {
    [
        Body { dir: from_angles(GIANT.0, GIANT.1), radius: 15f32.to_radians(), seed: 1, giant: true, colour: [0.0; 3] },
        // A moon crossing the giant's lower right, and others around it.
        Body { dir: from_angles(-78.0, 27.0), radius: 2.7f32.to_radians(), seed: 2, giant: false, colour: [0.80, 0.74, 0.66] },
        Body { dir: from_angles(-118.0, 53.0), radius: 1.7f32.to_radians(), seed: 3, giant: false, colour: [0.85, 0.50, 0.38] },
        Body { dir: from_angles(-62.0, 52.0), radius: 1.15f32.to_radians(), seed: 4, giant: false, colour: [0.72, 0.86, 0.95] },
        Body { dir: from_angles(-110.0, 19.0), radius: 0.7f32.to_radians(), seed: 5, giant: false, colour: [0.75, 0.80, 0.60] },
    ]
}

/// The bodies' surfaces without light, unrolled (longitude across, latitude down), so the shader can
/// turn them: the giant in the top two thirds, then one strip per moon. `p` is (u, v, unused).
fn maps_sample(p: V3, bodies: &[Body]) -> [f32; 4] {
    let lon = p[0] * 2.0 * PI;
    let ball = |lat: f32| [lat.cos() * lon.sin(), lat.sin(), lat.cos() * lon.cos()];
    let c = if p[1] < 2.0 / 3.0 {
        // In the giant's tilted frame, so it turns about its own axis (giant_surface's tilt, undone).
        let q = ball((0.5 - p[1] * 1.5) * PI);
        let tilt = 0.32f32;
        giant_surface([q[0] * tilt.cos() + q[1] * tilt.sin(), q[1] * tilt.cos() - q[0] * tilt.sin(), q[2]], bodies[0].seed)
    } else {
        let strip = (p[1] - 2.0 / 3.0) * 12.0;
        let b = &bodies[1 + (strip as usize).min(3)];
        moon_surface(ball((0.5 - strip.fract()) * PI), b.seed, b.colour)
    };
    [c[0], c[1], c[2], 1.0]
}

/// Where a pixel of the panorama looks.
fn panorama_dir(u: f32, v: f32) -> V3 {
    let az = (u - 0.5) * 2.0 * PI;
    let el = PI / 2.0 - v * 0.6 * PI;
    [el.cos() * az.cos(), el.sin(), el.cos() * az.sin()]
}

/// Where a pixel of the bodies' picture looks: a flat picture held up toward the giant, x to its right
/// (west, as the giant stands in the north), y up.
fn bodies_dir(u: f32, v: f32) -> V3 {
    let c = from_angles(GIANT.0, GIANT.1);
    let t1 = norm(cross([0.0, 1.0, 0.0], c));
    let t2 = cross(c, t1);
    let k = BODIES_SPAN.to_radians().tan();
    norm(add(c, add(mul(t1, (u * 2.0 - 1.0) * k), mul(t2, (1.0 - v * 2.0) * k))))
}

/// Paints a picture on every core: `dir` says where a pixel looks, `sample` what is there.
fn paint(
    width: usize,
    height: usize,
    channels: usize,
    dir: fn(f32, f32) -> V3,
    sample: fn(V3, &[Body]) -> [f32; 4],
) -> Vec<u8> {
    let bodies = bodies();
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get());
    let rows_per = height.div_ceil(threads);
    let mut data = vec![0u8; width * height * channels];
    std::thread::scope(|scope| {
        for (chunk_index, chunk) in data.chunks_mut(rows_per * width * channels).enumerate() {
            let bodies = &bodies;
            scope.spawn(move || {
                for (row, line) in chunk.chunks_mut(width * channels).enumerate() {
                    let py = chunk_index * rows_per + row;
                    for (px, pixel) in line.chunks_mut(channels).enumerate() {
                        // 3 x 3 samples a pixel.
                        let mut sum = [0.0f32; 4];
                        for s in 0..9 {
                            let (ox, oy) = ((0.5 + (s % 3) as f32) / 3.0, (0.5 + (s / 3) as f32) / 3.0);
                            let u = (px as f32 + ox) / width as f32;
                            let v = (py as f32 + oy) / height as f32;
                            let c = sample(dir(u, v), bodies);
                            // Coverage weights the colour, so edges blend without a dark fringe.
                            for i in 0..3 {
                                sum[i] += c[i] * c[3] / 9.0;
                            }
                            sum[3] += c[3] / 9.0;
                        }
                        for i in 0..channels {
                            pixel[i] = (sat(sum[i]) * 255.0 + 0.5) as u8;
                        }
                    }
                }
            });
        }
    });
    data
}

/// Cell noise that tiles: the distance to the nearest of one random point per cell, 0..1.
fn worley(x: f32, y: f32, cells: i32, seed: u32) -> f32 {
    let (px, py) = (x * cells as f32, y * cells as f32);
    let (cx, cy) = (px.floor() as i32, py.floor() as i32);
    let mut best = 9.0f32;
    for dy in -1..=1 {
        for dx in -1..=1 {
            let (ix, iy) = (cx + dx, cy + dy);
            let (wx, wy) = (ix.rem_euclid(cells), iy.rem_euclid(cells));
            let fx = ix as f32 + hash01(wx, wy, 0, seed);
            let fy = iy as f32 + hash01(wx, wy, 1, seed);
            best = best.min((fx - px).powi(2) + (fy - py).powi(2));
        }
    }
    best.sqrt().min(1.0)
}

fn tile_fbm(x: f32, y: f32, base: i32, octaves: u32, seed: u32) -> f32 {
    let (mut sum, mut amp, mut total, mut cells) = (0.0, 0.5, 0.0, base);
    for i in 0..octaves {
        sum += amp * perlin([x * cells as f32, y * cells as f32, 0.5], seed + i, cells);
        total += amp;
        amp *= 0.5;
        cells *= 2;
    }
    sat(0.5 + 0.5 * sum / total * 1.7)
}

fn cloud_noise(size: usize) -> Vec<u8> {
    let mut data = vec![0u8; size * size * 4];
    for (i, pixel) in data.chunks_mut(4).enumerate() {
        let (x, y) = ((i % size) as f32 / size as f32, (i / size) as f32 / size as f32);
        // Billows: inverted cells at three sizes.
        let cells = |base: i32, seed: u32| {
            (1.0 - worley(x, y, base, seed)) * 0.625
                + (1.0 - worley(x, y, base * 2, seed + 1)) * 0.25
                + (1.0 - worley(x, y, base * 4, seed + 2)) * 0.125
        };
        let soft = tile_fbm(x, y, 4, 6, 900);
        let billow = cells(5, 950);
        // Perlin-Worley: soft noise whose low parts the billows carve away, so clouds get round edges.
        let shape = sat((soft - (1.0 - billow) * 0.55) / (1.0 - (1.0 - billow) * 0.55));
        let detail = cells(12, 1000);
        let patches = tile_fbm(x, y, 2, 4, 1100);
        pixel[0] = (shape * 255.0 + 0.5) as u8;
        pixel[1] = (sat(detail) * 255.0 + 0.5) as u8;
        pixel[2] = (patches * 255.0 + 0.5) as u8;
        pixel[3] = 255;
    }
    data
}

// ---- Cloud volumes: real 3D noise, stored as slices side by side in one picture ----

/// Perlin noise that repeats every `period` lattice cells along all three axes.
fn perlin3(p: V3, seed: u32, period: i32) -> f32 {
    let (fx, fy, fz) = (p[0].floor(), p[1].floor(), p[2].floor());
    let (x0, y0, z0) = (fx as i32, fy as i32, fz as i32);
    let (x, y, z) = (p[0] - fx, p[1] - fy, p[2] - fz);
    let (u, v, w) = (fade(x), fade(y), fade(z));
    let g = |dx: i32, dy: i32, dz: i32| {
        let h = hash((x0 + dx).rem_euclid(period), (y0 + dy).rem_euclid(period), (z0 + dz).rem_euclid(period), seed);
        grad(h, x - dx as f32, y - dy as f32, z - dz as f32)
    };
    let a = mix(mix(g(0, 0, 0), g(1, 0, 0), u), mix(g(0, 1, 0), g(1, 1, 0), u), v);
    let b = mix(mix(g(0, 0, 1), g(1, 0, 1), u), mix(g(0, 1, 1), g(1, 1, 1), u), v);
    mix(a, b, w)
}

/// 3D cell noise that tiles over 0..1: 1 at a cell's point, falling to 0 a cell away (round billows).
fn billow3(p: V3, cells: i32, seed: u32) -> f32 {
    let q = mul(p, cells as f32);
    let c = [q[0].floor() as i32, q[1].floor() as i32, q[2].floor() as i32];
    let mut best = 9.0f32;
    for dz in -1..=1 {
        for dy in -1..=1 {
            for dx in -1..=1 {
                let i = [c[0] + dx, c[1] + dy, c[2] + dz];
                let w = [i[0].rem_euclid(cells), i[1].rem_euclid(cells), i[2].rem_euclid(cells)];
                let f = [
                    i[0] as f32 + hash01(w[0], w[1], w[2], seed),
                    i[1] as f32 + hash01(w[0], w[1], w[2], seed + 1),
                    i[2] as f32 + hash01(w[0], w[1], w[2], seed + 2),
                ];
                let d = sub(f, q);
                best = best.min(dot(d, d));
            }
        }
    }
    1.0 - best.sqrt().min(1.0)
}

/// Billows at three sizes, 0..1.
fn billow_fbm(p: V3, cells: i32, seed: u32) -> f32 {
    billow3(p, cells, seed) * 0.625 + billow3(p, cells * 2, seed + 10) * 0.25 + billow3(p, cells * 4, seed + 20) * 0.125
}

fn remap(x: f32, a: f32, b: f32, c: f32, d: f32) -> f32 { c + (x - a) / (b - a) * (d - c) }

/// A cube of noise, `n` texels a side, four values a texel; texel (x, y, z) is `x + n * (y + n * z)`.
struct Volume {
    n: usize,
    data: Vec<[f32; 4]>,
}

impl Volume {
    fn new(n: usize, texel: fn(V3) -> [f32; 4]) -> Self {
        let threads = std::thread::available_parallelism().map_or(4, |t| t.get());
        let mut data = vec![[0.0f32; 4]; n * n * n];
        let per = (n * n * n).div_ceil(threads);
        std::thread::scope(|scope| {
            for (chunk_index, chunk) in data.chunks_mut(per).enumerate() {
                scope.spawn(move || {
                    for (k, out) in chunk.iter_mut().enumerate() {
                        let i = chunk_index * per + k;
                        let at = |v: usize| (v as f32 + 0.5) / n as f32;
                        *out = texel([at(i % n), at(i / n % n), at(i / (n * n))]);
                    }
                });
            }
        });
        Self { n, data }
    }

    /// The value at `p` (the cube spans 0..1 and repeats), blended between the eight texels around it:
    /// what the shader's two bilinear reads and its blend between slices give.
    fn at(&self, p: V3) -> [f32; 4] {
        let n = self.n as i32;
        let f = |v: f32| (v - v.floor()) * n as f32 - 0.5;
        let (x, y, z) = (f(p[0]), f(p[1]), f(p[2]));
        let (x0, y0, z0) = (x.floor(), y.floor(), z.floor());
        let (tx, ty, tz) = (x - x0, y - y0, z - z0);
        let get = |dx: i32, dy: i32, dz: i32| {
            let w = |v: f32, d: i32| (v as i32 + d).rem_euclid(n) as usize;
            self.data[w(x0, dx) + self.n * (w(y0, dy) + self.n * w(z0, dz))]
        };
        let mut out = [0.0f32; 4];
        for (i, value) in out.iter_mut().enumerate() {
            let a = mix(mix(get(0, 0, 0)[i], get(1, 0, 0)[i], tx), mix(get(0, 1, 0)[i], get(1, 1, 0)[i], tx), ty);
            let b = mix(mix(get(0, 0, 1)[i], get(1, 0, 1)[i], tx), mix(get(0, 1, 1)[i], get(1, 1, 1)[i], tx), ty);
            *value = mix(a, b, tz);
        }
        out
    }

    /// The cube as a picture: its slices in `columns`, each with a border of one texel copied from the
    /// slice's far side, so a bilinear read at a slice's edge wraps instead of bleeding into the next.
    fn atlas(&self, columns: usize, channels: usize) -> (usize, usize, Vec<u8>) {
        let (n, tile) = (self.n, self.n + 2);
        let rows = n.div_ceil(columns);
        let (width, height) = (columns * tile, rows * tile);
        let mut out = vec![0u8; width * height * channels];
        for z in 0..n {
            for ty in 0..tile {
                for tx in 0..tile {
                    let (sx, sy) = ((tx + n - 1) % n, (ty + n - 1) % n);
                    let texel = self.data[sx + n * (sy + n * z)];
                    let (px, py) = (z % columns * tile + tx, z / columns * tile + ty);
                    for c in 0..channels {
                        out[(py * width + px) * channels + c] = (sat(texel[c]) * 255.0 + 0.5) as u8;
                    }
                }
            }
        }
        (width, height, out)
    }
}

/// The clouds' shapes: R soft Perlin noise carved by billows (round, cauliflower-like masses), G, B and
/// A billows at growing detail, which the shader uses to carve R further.
fn shape_texel(p: V3) -> [f32; 4] {
    let (mut sum, mut amp, mut total, mut period) = (0.0, 0.5, 0.0, 4);
    for i in 0..4 {
        sum += amp * perlin3(mul(p, period as f32), 2000 + i, period);
        total += amp;
        amp *= 0.5;
        period *= 2;
    }
    let soft = sat(0.5 + 0.5 * sum / total * 1.9);
    let big = billow_fbm(p, 4, 2100);
    [sat(remap(soft, big - 1.0, 1.0, 0.0, 1.0)), big, billow_fbm(p, 8, 2200), billow3(p, 16, 2300) * 0.7 + billow3(p, 32, 2310) * 0.3]
}

/// Fine billows that fray the clouds' edges.
fn detail_texel(p: V3) -> [f32; 4] {
    [billow_fbm(p, 2, 2400), billow_fbm(p, 4, 2500), billow3(p, 8, 2600) * 0.7 + billow3(p, 16, 2610) * 0.3, 1.0]
}

// ---- A preview of the clouds, with the shader's own arithmetic ----
// Everything from here to `preview` mirrors common.wgsl and sky.wgsl: change both together.

const CLOUD_LOW: f32 = 190.0;
const CLOUD_HIGH: f32 = 430.0;
const PLANET: f32 = 40000.0;
const SIGMA: f32 = 0.03;

struct Clouds {
    weather: Vec<u8>,
    size: usize,
    shape: Volume,
    detail: Volume,
    amount: f32,
}

impl Clouds {
    fn weather(&self, u: f32, v: f32) -> [f32; 3] {
        let n = self.size as i32;
        let f = |x: f32| (x - x.floor()) * n as f32 - 0.5;
        let (x, y) = (f(u), f(v));
        let (x0, y0) = (x.floor(), y.floor());
        let get = |dx: i32, dy: i32, c: usize| {
            let w = |v: f32, d: i32| (v as i32 + d).rem_euclid(n) as usize;
            self.weather[(w(y0, dy) * self.size + w(x0, dx)) * 4 + c] as f32 / 255.0
        };
        let mut out = [0.0; 3];
        for (c, value) in out.iter_mut().enumerate() {
            *value = mix(mix(get(0, 0, c), get(1, 0, c), x - x0), mix(get(0, 1, c), get(1, 1, c), x - x0), y - y0);
        }
        out
    }

    fn density(&self, p: V3, detail: bool) -> f32 {
        let h = (p[1] - CLOUD_LOW) / (CLOUD_HIGH - CLOUD_LOW);
        if h <= 0.0 || h >= 1.0 {
            return 0.0;
        }
        let w = self.weather(p[0] * 0.0004, p[2] * 0.0004);
        let field = w[0] * 0.6 + w[2] * 0.4;
        let threshold = mix(0.54, 0.02, self.amount);
        let cover = smoothstep(threshold, threshold + 0.3, field);
        if cover <= 0.0 {
            return 0.0;
        }
        let kind = sat(w[2] * 0.6 + cover * 0.5);
        let top = mix(0.3, 1.0, kind);
        let gradient = smoothstep(0.0, 0.07, h) * (1.0 - smoothstep(top * 0.4, top, h));
        let s = self.shape.at([p[0] * 0.0011, p[2] * 0.0011, p[1] * 0.0011]);
        let billows = s[1] * 0.625 + s[2] * 0.25 + s[3] * 0.125;
        let base = sat(remap(s[0], billows - 1.0, 1.0, 0.0, 1.0)) * gradient;
        let mut d = sat(remap(base, 1.0 - cover, 1.0, 0.0, 1.0)) * cover;
        if d <= 0.0 {
            return 0.0;
        }
        // Middle-sized billows bite into the mass, most at its edge: the cauliflower look.
        let m = self.shape.at([p[0] * 0.0037 + 0.31, p[2] * 0.0037 + 0.17, p[1] * 0.0037]);
        let lumps = m[1] * 0.6 + m[2] * 0.4;
        d = sat(remap(d, (1.0 - lumps) * 0.42 * (1.0 - d * 0.5), 1.0, 0.0, 1.0));
        if detail && d > 0.0 {
            let f = self.detail.at([p[0] * 0.0075, p[2] * 0.0075, p[1] * 0.0075]);
            let fine = f[0] * 0.625 + f[1] * 0.25 + f[2] * 0.125;
            let fray = mix(fine, 1.0 - fine, sat(h * 4.0)) * 0.45;
            d = sat(remap(d, fray, 1.0, 0.0, 1.0));
        }
        // Clouds are dense right behind their edge: that is what gives them a firm outline.
        sat(d * 3.0)
    }
}

fn atmosphere(d: V3, sun: V3) -> V3 {
    let beta = [0.10, 0.32, 1.0];
    let up = d[1].max(0.0);
    let air = 1.0 / (up + 0.12);
    let sun_air = 1.0 / (sun[1].max(0.0) + 0.08);
    let cos_t = dot(d, sun);
    let phase = 0.75 * (1.0 + cos_t * cos_t);
    let mut col = [0.0; 3];
    for i in 0..3 {
        let sun_col = (-beta[i] * sun_air * 0.30f32).exp();
        let scattered = 1.0 - (-beta[i] * air * 0.22f32).exp();
        let mut raw = sun_col * scattered * phase * 5.0;
        raw += [0.04, 0.10, 0.26][i] * smoothstep(-0.2, 0.3, sun[1]) * (0.4 + 0.6 * up);
        raw += sun_col * cos_t.max(0.0).powi(8) * 0.5;
        let low = 1.0 - smoothstep(0.0, 0.35, sun[1].abs());
        raw += [0.02, 0.04, 0.20][i] * low * (0.3 + 0.7 * up);
        raw *= [1.0, 1.0 - 0.3 * low, 1.0][i];
        col[i] = 1.0 - (-raw * 1.4f32).exp();
    }
    col
}

fn henyey(cos_t: f32, g: f32) -> f32 {
    (1.0 - g * g) / (1.0 + g * g - 2.0 * g * cos_t).powf(1.5)
}

/// The clouds along a ray from a camera at height `cam_y`: rgb and how much sky they hide.
fn march(clouds: &Clouds, cam_y: f32, d: V3, sun: V3, behind: V3, steps: usize, jitter: f32) -> [f32; 4] {
    if d[1] < 0.0 {
        return [0.0; 4];
    }
    let r0 = PLANET + cam_y;
    let b = r0 * d[1];
    let shell = |alt: f32| -b + (b * b + (PLANET + alt - r0) * (PLANET + alt + r0)).sqrt();
    let t0 = shell(CLOUD_LOW);
    let t1 = shell(CLOUD_HIGH).min(t0 + 2600.0);
    let at = |t: f32| {
        let rel = [d[0] * t, r0 + d[1] * t, d[2] * t];
        [rel[0], dot(rel, rel).sqrt() - PLANET, rel[2]]
    };
    let low = 1.0 - smoothstep(0.0, 0.35, sun[1].abs());
    let light = mix3([1.0, 0.96, 0.9], [1.0, 0.50, 0.24], low);
    let cos_t = dot(d, sun);
    let phase = (0.6 * henyey(cos_t, 0.6) + 0.4 * henyey(cos_t, -0.25)).clamp(0.75, mix(1.7, 3.0, low));
    let dt = (t1 - t0) / steps as f32;
    let (mut trans, mut sum) = (1.0f32, [0.0f32; 3]);
    for i in 0..steps {
        let p = at(t0 + (i as f32 + jitter) * dt);
        let dens = clouds.density(p, true);
        if dens <= 0.004 {
            continue;
        }
        let mut tau = 0.0;
        let mut reach = 0.0;
        for step in [14.0f32, 24.0, 42.0, 70.0] {
            reach += step;
            tau += clouds.density(add(p, mul(sun, reach - step * 0.5)), false) * step;
        }
        let energy = (-tau * SIGMA).exp().max((-tau * SIGMA * 0.25).exp() * 0.7);
        let h = sat((p[1] - CLOUD_LOW) / (CLOUD_HIGH - CLOUD_LOW));
        let ambient = mix3([0.34, 0.40, 0.50], [0.58, 0.70, 0.90], h);
        let lit = add(mul(light, energy * phase * 1.3), mulv(ambient, mix3([0.8; 3], [0.22, 0.24, 0.42], low)));
        let a = 1.0 - (-dens * dt * SIGMA).exp();
        sum = add(sum, mul(lit, trans * a));
        trans *= 1.0 - a;
        if trans < 0.02 {
            break;
        }
    }
    let alpha = 1.0 - trans;
    if alpha < 0.001 {
        return [0.0; 4];
    }
    let mut col = mul(sum, 1.0 / alpha);
    for c in &mut col {
        *c = *c / (1.0 + 0.35 * *c) * 1.2;
    }
    // Far clouds take the colour of the air in front of them.
    let haze = 1.0 - (-t0 / 3500.0f32).exp();
    col = mix3(col, behind, haze * 0.85);
    [col[0], col[1], col[2], alpha]
}

/// Paints what a player would see: a view of `width` x `height` pixels, 85 degrees wide, looking
/// `yaw` degrees round from east and `pitch` degrees up, with the sun `sun_el` degrees high in the east.
fn preview(clouds: &Clouds, width: usize, height: usize, yaw: f32, pitch: f32, sun_el: f32, steps: usize) -> Vec<u8> {
    let sun = from_angles(0.0, sun_el);
    let forward = from_angles(yaw, pitch);
    let right = norm(cross(forward, [0.0, 1.0, 0.0]));
    let up = cross(right, forward);
    let k = (85.0f32 / 2.0).to_radians().tan();
    let threads = std::thread::available_parallelism().map_or(4, |t| t.get());
    let rows_per = height.div_ceil(threads);
    let mut data = vec![0u8; width * height * 3];
    std::thread::scope(|scope| {
        for (chunk_index, chunk) in data.chunks_mut(rows_per * width * 3).enumerate() {
            scope.spawn(move || {
                for (row, line) in chunk.chunks_mut(width * 3).enumerate() {
                    let py = chunk_index * rows_per + row;
                    for (px, pixel) in line.chunks_mut(3).enumerate() {
                        let x = ((px as f32 + 0.5) / width as f32 * 2.0 - 1.0) * k;
                        let y = (1.0 - (py as f32 + 0.5) / height as f32 * 2.0) * k * height as f32 / width as f32;
                        let d = norm(add(forward, add(mul(right, x), mul(up, y))));
                        let mut col = atmosphere(d, sun);
                        if dot(d, sun) > 0.9994 {
                            col = [1.0; 3];
                        }
                        if d[1] < 0.0 {
                            col = [0.16, 0.24, 0.16];
                        }
                        let c = march(clouds, 70.0, d, sun, col, steps, hash01(px as i32, py as i32, 0, 77));
                        col = mix3(col, [c[0], c[1], c[2]], c[3]);
                        for i in 0..3 {
                            pixel[i] = (sat(col[i]) * 255.0 + 0.5) as u8;
                        }
                    }
                }
            });
        }
    });
    data
}

fn save(path: &Path, width: usize, height: usize, data: &[u8]) {
    let file = BufWriter::new(File::create(path).expect("create the png"));
    let mut encoder = png::Encoder::new(file, width as u32, height as u32);
    let rgba = data.len() == width * height * 4;
    encoder.set_color(if rgba { png::ColorType::Rgba } else { png::ColorType::Rgb });
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::High);
    let mut writer = encoder.write_header().expect("write the header");
    writer.write_image_data(data).expect("write the pixels");
    println!("wrote {} ({width} x {height})", path.display());
}

/// A brighter enchantment glint than vanilla's, of the pack's own: streaks running along the diagonal the
/// game scrolls it on, violet shading to cyan-white, with a few sparks. The game adds it over the item or
/// armour, so black is "no glint". It tiles.
fn glint(size: usize, seed: u32) -> Vec<u8> {
    let mut data = vec![0u8; size * size * 4];
    for (i, pixel) in data.chunks_mut(4).enumerate() {
        let (x, y) = ((i % size) as f32 / size as f32, (i / size) as f32 / size as f32);
        // Along the diagonal, and three times finer across it.
        let (u, v) = ((x + y).fract(), (3.0 * (x - y)).rem_euclid(1.0));
        let streak = tile_fbm(u, v, 3, 5, seed);
        let glow = smoothstep(0.38, 0.85, streak).powf(1.3);
        let hue = tile_fbm(u, v, 2, 3, seed + 50);
        let colour = mix3([0.62, 0.25, 1.0], [0.55, 0.9, 1.0], smoothstep(0.35, 0.7, hue));
        let spark = smoothstep(0.80, 0.92, tile_fbm(x, y, 16, 2, seed + 90)) * 0.9;
        let c = add(mul(colour, 0.16 + 1.25 * glow), [spark; 3]);
        for k in 0..3 {
            pixel[k] = (sat(c[k]) * 255.0 + 0.5) as u8;
        }
        pixel[3] = 255;
    }
    data
}

fn main() {
    // `skygen --glint <textures/misc folder>` paints only the enchantment glint.
    if std::env::args().nth(1).as_deref() == Some("--glint") {
        let folder = std::env::args().nth(2).expect("usage: skygen --glint <folder>");
        let folder = Path::new(&folder);
        save(&folder.join("enchanted_glint_armor.png"), 128, 128, &glint(128, 3000));
        save(&folder.join("enchanted_glint_item.png"), 128, 128, &glint(128, 3100));
        return;
    }
    let out = std::env::args().nth(1).expect("usage: skygen <pack folder>");
    let out = Path::new(&out);
    // Horizon takes at most 1024 KiB a texture: the soft nebulae fit in a smaller picture, and the giant
    // gets one of its own, so it stays sharp.
    save(&out.join("night_sky.png"), 1536, 768, &paint(1536, 768, 3, panorama_dir, background_sample));
    save(&out.join("sky_bodies.png"), 1024, 1024, &paint(1024, 1024, 4, bodies_dir, bodies_sample));
    save(&out.join("planet_maps.png"), 1024, 768, &paint(1024, 768, 3, |u, v| [u, v, 0.0], maps_sample));
    let weather = cloud_noise(512);
    save(&out.join("cloud_noise.png"), 512, 512, &weather);
    let shape = Volume::new(64, shape_texel);
    let detail = Volume::new(32, detail_texel);
    let (w, h, data) = shape.atlas(8, 4);
    save(&out.join("cloud_shape.png"), w, h, &data);
    let (w, h, data) = detail.atlas(8, 3);
    save(&out.join("cloud_detail.png"), w, h, &data);

    // `skygen <pack folder> <preview folder>` also paints what the clouds will look like in the game.
    if let Some(folder) = std::env::args().nth(2) {
        let folder = Path::new(&folder);
        let clouds = Clouds { weather, size: 512, shape, detail, amount: 0.5 };
        for (name, yaw, pitch, sun_el) in [("noon", 60.0, 22.0, 50.0), ("sunset", 20.0, 14.0, 6.0), ("up", 120.0, 60.0, 40.0)] {
            save(&folder.join(format!("clouds_{name}.png")), 960, 540, &preview(&clouds, 960, 540, yaw, pitch, sun_el, 32));
        }
    }
}
