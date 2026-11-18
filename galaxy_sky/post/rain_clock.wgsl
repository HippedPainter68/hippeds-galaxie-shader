// The rain clock: when the rainwater on the ground will have dried, in frame.time seconds (0 when the
// ground is dry). This pass writes it into rain_clock; the next one copies it into rain_prev, so here
// rain_prev still holds last frame's. The final pass reads rain_clock to draw the wet ground and the
// puddles. (Two small targets of the pack's own instead of a kept resource: the registry's submission
// form reads only these.)
override puddle_drying: f32 = 180.0;

// An expiry time, not a per-frame water increment: a float16 target would round small drying steps away.
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

fn post(input: PostInput) -> vec4<f32> {
    let before = textureLoad(rain_prev, vec2<i32>(0), 0).r;
    return vec4<f32>(gs_rain_deadline(before), 0.0, 0.0, 1.0);
}
