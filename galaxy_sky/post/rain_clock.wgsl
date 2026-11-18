// The rain clock: when the rainwater on the ground will have dried, in frame.time seconds, kept from frame
// to frame in rain_clock (one texel; 0 when the ground is dry). The final pass reads it to draw the wet
// ground and the puddles. (Shader API 0.1 kept it in the picture's alpha through `history`; 0.2 has no
// history and ignores a post pass's alpha, but keeps resources.)
override puddle_drying: f32 = 180.0;

// An expiry time, not a per-frame water increment, so a small drying step is never rounded away.
fn gs_rain_deadline(before: f32) -> f32 {
    if frame.dimension != 0 {
        return 0.0;
    }
    var deadline = before - 1.0;
    if before <= 0.0 || frame.delta_time <= 0.0 {
        deadline = frame.time;
    } else if deadline - frame.time > puddle_drying + 4.0 {
        // frame.time wraps hourly; an expiry can lie just beyond that boundary.
        deadline -= 3600.0;
    }
    if frame.precipitation == 1u && frame.rain > 0.001 {
        deadline = max(deadline, frame.time + frame.wetness * puddle_drying);
    }
    if deadline <= frame.time {
        return 0.0;
    }
    return deadline + 1.0;
}

fn compute(input: ComputeInput) {
    if !input.in_bounds {
        return;
    }
    let before = textureLoad(rain_clock_previous, vec2<i32>(0), 0).r;
    textureStore(rain_clock, vec2<i32>(0), vec4<f32>(gs_rain_deadline(before), 0.0, 0.0, 0.0));
}
