// The lens, last: smooth edges, then the optional camera effects (depth of field, motion blur, chromatic
// aberration) and the vignette. Each optional effect costs nothing while its option is 0.
override fxaa: bool = true;
override depth_of_field: f32 = 0.0;
override motion_blur: f32 = 0.0;
override chromatic_aberration: f32 = 0.0;
override vignette: bool = true;

fn gs_tap(uv: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb;
}

// How far a point is from the camera, in blocks; the sky is far away.
fn gs_distance(uv: vec2<f32>) -> f32 {
    let depth = depth_at(uv);
    if depth <= 0.0 {
        return 2000.0;
    }
    return length(view_position(uv, depth));
}

fn post(input: PostInput) -> vec4<f32> {
    let uv = input.uv;
    let px = 1.0 / frame.resolution;
    var c = input.color.rgb;

    // Smooth edges: where the brightness jumps, blend along the edge.
    if fxaa {
        let n = gs_tap(uv + vec2<f32>(0.0, -px.y));
        let s = gs_tap(uv + vec2<f32>(0.0, px.y));
        let w = gs_tap(uv + vec2<f32>(-px.x, 0.0));
        let e = gs_tap(uv + vec2<f32>(px.x, 0.0));
        let lc = gs_luma(c);
        let ln = gs_luma(n);
        let ls = gs_luma(s);
        let lw = gs_luma(w);
        let le = gs_luma(e);
        let lo = min(lc, min(min(ln, ls), min(lw, le)));
        let hi = max(lc, max(max(ln, ls), max(lw, le)));
        let contrast = hi - lo;
        if contrast > max(0.05, hi * 0.125) {
            // Blend across the edge: sideways for a vertical edge, up and down for a horizontal one.
            let horizontal = abs(ln + ls - 2.0 * lc) >= abs(lw + le - 2.0 * lc);
            let amount = clamp(contrast / max(hi, 0.001), 0.0, 1.0) * 0.5;
            let blurred = select((w + e) * 0.5, (n + s) * 0.5, horizontal);
            c = mix(c, blurred, amount);
        }
    }

    // Depth of field: focus on the middle of the screen, blur by how far off the focus a point is.
    if depth_of_field > 0.0 {
        let focus = gs_distance(vec2<f32>(0.5));
        let here = gs_distance(uv);
        let coc = clamp(abs(here - focus) / max(focus, 1.0), 0.0, 1.0) * depth_of_field;
        if coc > 0.02 {
            let radius = coc * 8.0 * frame.resolution.y / 720.0;
            var sum = c;
            for (var i = 0; i < 8; i++) {
                let a = f32(i) * 0.7853982;
                sum += gs_tap(uv + vec2<f32>(cos(a), sin(a)) * radius * px);
            }
            c = sum / 9.0;
        }
    }

    // Motion blur: smear along the way the point moved on screen since last frame (camera motion).
    if motion_blur > 0.0 {
        let p = view_position(uv, max(depth_at(uv), 0.0005));
        let before = frame.previous_view_projection * vec4<f32>(p + frame.camera_motion, 1.0);
        if before.w > 0.0 {
            let prev_uv = before.xy / before.w * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5);
            var vel = (uv - prev_uv) * motion_blur * 0.5;
            let len = length(vel);
            vel *= min(len, 0.03) / max(len, 0.00001);
            var sum = c;
            for (var i = 1; i < 6; i++) {
                sum += gs_tap(uv - vel * (f32(i) / 5.0));
            }
            c = sum / 6.0;
        }
    }

    // Chromatic aberration: red and blue drift apart toward the corners.
    if chromatic_aberration > 0.0 {
        let off = (uv - vec2<f32>(0.5)) * chromatic_aberration * 0.012;
        c = vec3<f32>(mix(c.r, gs_tap(uv + off).r, 0.8), c.g, mix(c.b, gs_tap(uv - off).b, 0.8));
    }

    if vignette {
        let aspect = frame.resolution.x / frame.resolution.y;
        let d = length((uv - 0.5) * vec2<f32>(aspect, 1.0)) / length(vec2<f32>(aspect, 1.0) * 0.5);
        c *= 1.0 - smoothstep(0.55, 1.1, d) * 0.3;
    }
    // The last pass: back to linear light for Horizon (it clips at white in SDR, as the 0.1 pack did).
    return vec4<f32>(gs_linear(clamp(c, vec3<f32>(0.0), vec3<f32>(1.0))), 1.0);
}
