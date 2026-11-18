// Galaxy Sky: how surfaces look.
// Terrain: sun shadows and cloud shadows, coloured block light, sunlight through leaves, smooth and
// metallic materials with highlights (LabPBR maps when a resource pack ships them), wet ground and puddles
// after rain, glowing ores.
// Water: waves and ripples, refraction, colour by depth, foam, caustics below, the mirror and sun glints.
override colored_light: f32 = 1.0;

fn displacement(input: DisplacementInput) -> f32 {
    if input.material == 19u && input.normal.y > 0.9 {
        return (1.0 - input.height) * 0.08;
    }
    if input.material == 22u && input.normal.y > 0.9 {
        return (1.0 - input.height) * 0.045;
    }
    if input.material == 20u {
        return (1.0 - input.height) * 0.035;
    }
    if input.material == 21u {
        return (1.0 - input.height) * 0.012;
    }
    return 0.0;
}

fn gs_max3(c: vec3<f32>) -> f32 {
    return max(c.r, max(c.g, c.b));
}

fn gs_screen_texel(screen: vec2<f32>) -> vec2<i32> {
    let size = vec2<i32>(textureDimensions(opaque_depth));
    return clamp(vec2<i32>(screen * vec2<f32>(size)), vec2<i32>(0), size - vec2<i32>(1));
}

// How far from the camera, in blocks, the solid world behind a screen position lies.
fn gs_behind(screen: vec2<f32>) -> f32 {
    let depth = textureLoad(opaque_depth, gs_screen_texel(screen), 0);
    if depth <= 0.0 {
        return 10000.0;
    }
    let clip = vec4<f32>(screen.x * 2.0 - 1.0, 1.0 - screen.y * 2.0, depth, 1.0);
    let view = frame.projection_inverse * clip;
    return length(view.xyz / view.w);
}

fn gs_terrain(input: MaterialInput) -> Surface {
    var base = vec4<f32>(gs_gamma(input.albedo.rgb * input.shaded_tint.rgb), input.albedo.a);
    let v = normalize(-input.position);
    let world = input.position + frame.camera_position;
    let overworld = frame.dimension == 0;
    let sky_w = smoothstep(0.3, 0.9, input.light.y);
    let leafy = input.material == 10u || input.material == 11u || input.material == 12u;
    let l = frame.light_direction;

    // ---- What the surface is made of ----
    var n = input.normal;
    var smoothness = 0.05;
    var f0 = 0.04;
    var metal = 0.0;
    var ao = 1.0;
    var emit = input.emission;
    switch input.material {
        case 13u { smoothness = 0.5; }
        case 14u { smoothness = 0.85; }
        case 15u { smoothness = 0.8; metal = 1.0; }
        case 16u { smoothness = 0.65; }
        default {}
    }
    if block_pbr_maps() {
        let nm = block_normal_map(input.uv);
        let sm = block_specular_map(input.uv);
        let txy = nm.xy * 2.0 - 1.0;
        let tz = sqrt(max(1.0 - dot(txy, txy), 0.0));
        let bitangent = cross(input.normal, input.tangent.xyz) * input.tangent.w;
        n = normalize(input.tangent.xyz * txy.x + bitangent * txy.y + input.normal * tz);
        ao = nm.b;
        if sm.r + sm.g + sm.b + sm.a > 0.0 {
            smoothness = max(smoothness, sm.r);
            if sm.g > 0.9 {
                metal = 1.0;
            } else {
                f0 = max(f0, sm.g);
            }
            if sm.a < 0.999 {
                emit = max(emit, sm.a);
            }
        }
    }

    // ---- Light ----
    var light = gs_gamma(input.lightmap) * ao;

    // Block light takes the colour of its sources: lava orange, soul fire blue, redstone red.
    if colored_light > 0.0 {
        let cl = block_light_color(input.position);
        let w = min(cl.a, 1.0) * smoothstep(0.0, 0.5, input.light.x) * (1.0 - 0.75 * sky_w * gs_dayf()) * min(colored_light, 1.0);
        let cl_rgb = gs_gamma(cl.rgb);
        let hue = cl_rgb / max(gs_max3(cl_rgb), 0.001);
        light *= mix(vec3<f32>(1.0), hue * (1.0 + 0.25 * colored_light), w);
    }
    // Sun or moon: shadows, cloud shadows, colour through stained glass, caustics under water.
    // A shadow only takes away the sun's or moon's light. Where a torch (placed, held or dropped) lights a
    // spot more than the sky does, its light fills the shadow: a torch casts no shadow of its own, and the
    // player's moon shadow vanishes in the light of the torch in their hand.
    let sun_col = gs_light_color();
    var direct = 0.0;
    if overworld {
        var s = 1.0;
        var tint = vec3<f32>(1.0);
        if frame.has_shadow == 1u {
            let bias = input.normal * (frame.shadow_center_texel * 2.0 + 0.03);
            let sp = shadow_position(input.position + bias);
            s = textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy, sp.z);
            // Past the map's edge everything counts as lit.
            let fade = smoothstep(frame.shadow_distance * 0.85, frame.shadow_distance, length(input.position.xz));
            s = mix(s, 1.0, fade);
            // Lit in the solid map but not through translucent terrain: under water or stained glass.
            let st = textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, sp.xy, sp.z);
            if s > 0.5 && st < 0.5 {
                let size = vec2<i32>(textureDimensions(shadow_color));
                let texel = clamp(vec2<i32>(sp.xy * vec2<f32>(size)), vec2<i32>(0), size - vec2<i32>(1));
                let sc = textureLoad(shadow_color, texel, 0);
                if sc.a >= 1.0 {
                    tint = vec3<f32>(0.45, 0.85, 1.0) * (0.35 + 2.0 * gs_caustics(world.xz));
                } else {
                    tint = gs_gamma(sc.rgb);
                }
            }
        }
        s *= gs_cloud_shadow(input.position);
        let ndl = dot(n, l);
        let facing = smoothstep(0.0, 0.2, ndl);
        direct = s * facing;

        // Thin things let the sun through: a leaf seen against the light glows yellow-green.
        var through = 0.0;
        if leafy {
            through = s * (0.35 + 0.65 * pow(max(dot(-v, l), 0.0), 4.0)) * (1.0 - facing);
        }

        let sun_tint = sun_col / max(gs_max3(sun_col), 0.001) * tint;
        // By night the moon tints only a little, or snow turns deep blue.
        let tint_amount = mix(0.15, 0.45, gs_dayf());
        var factor = mix(vec3<f32>(0.58), mix(vec3<f32>(1.0), sun_tint, tint_amount) * 1.02, direct);
        factor += sun_tint * vec3<f32>(1.0, 1.05, 0.55) * through * 0.55;
        // Near a light source its light fills every shadow, by day too: within about three blocks of a
        // torch (block light 11 of 15 and more) no shadow is left, and by seven blocks they are back.
        // The API has no way to keep a block out of the shadow map, so this is how a torch gets none.
        let block = max(input.light.x, gs_max3(gs_gamma(input.colored_light)));
        let sky_share = 1.0 - smoothstep(0.45, 0.72, block);
        light *= mix(vec3<f32>(1.0), factor, sky_w * sky_share);
    }

    // The End: a dim violet glow from everywhere, and the black hole's disc lights what faces it.
    if frame.dimension == 1 {
        // Scaled back when too bright, or the End's own purple flashes (they raise the light map) burn the ground out.
        light += GS_END_LIGHT * (0.55 + 0.45 * max(dot(n, GS_END_EYE), 0.0));
        light *= min(1.0, 1.1 / gs_max3(light));
    }

    // The Nether: the air glows in the colour of the biome's fog (red wastes, blue soul valleys, teal
    // warped forests), and the lava sea lights what is low from below.
    if frame.dimension == -1 {
        let air = gs_fog_color() / max(gs_max3(gs_fog_color()), 0.05);
        let lava = (1.0 - smoothstep(31.0, 75.0, world.y)) * (0.45 - 0.35 * n.y);
        light = light * 1.2 + mix(vec3<f32>(1.0), air, 0.5) * 0.4 + vec3<f32>(1.0, 0.4, 0.1) * lava;
    }

    // Light sources held in a hand or lying on the ground (Horizon's Dynamic lights). Horizon already
    // raises the light map by them, so this only adds their colour, and it is never shadowed. (Seen in
    // the game: adding their full strength here as well burned the ground out to white.)
    light += gs_gamma(input.colored_light) * 0.12 * min(colored_light, 1.0);

    // ---- Highlights and reflections: smooth things shine, metals reflect in their own colour ----
    var shine = vec3<f32>(0.0);
    if smoothness > 0.06 {
        let half_vec = normalize(l + v);
        let nh = max(dot(n, half_vec), 0.0);
        let power = exp2(1.0 + smoothness * 10.0);
        let fresnel = f0 + (1.0 - f0) * pow(1.0 - max(dot(n, v), 0.0), 5.0);
        let shine_col = mix(vec3<f32>(1.0), base.rgb, metal);
        shine = sun_col * shine_col * pow(nh, power) * (power + 8.0) / 40.0 * smoothness * direct * sky_w;
        shine += gs_sky_color() * shine_col * mix(fresnel, 0.6, metal) * smoothness * smoothness * sky_w;
        // Snow glitters: a few crystals catch the sun, by day only (by moonlight the ground looked
        // like a second starry sky).
        if input.material == 13u {
            let crystal = step(0.996, gs_hash13(floor(world * 24.0) + floor(v * 6.0)));
            shine += sun_col * crystal * pow(nh, 12.0) * direct * gs_dayf();
        }
    }

    var col = base.rgb * light * (1.0 - 0.4 * metal * smoothness) + shine;
    col += base.rgb * emit * 0.5;
    // Lava: white-hot patches drift over it.
    if input.fluid == 2u {
        col = base.rgb * vec3<f32>(1.2, 1.0, 0.8) * (1.15 + 0.45 * gs_noise(vec3<f32>(world.xz * 0.6, world.y * 0.6 + frame.time * 0.3)));
    }
    // Ores: their coloured specks glow where it is dark.
    if input.material == 18u {
        let a = gs_gamma(input.albedo.rgb);
        let colourful = smoothstep(0.25, 0.6, gs_max3(a) - min(a.r, min(a.g, a.b)));
        col += a * colourful * (1.0 - min(gs_luma(gs_gamma(input.lightmap)), 1.0)) * 0.9;
    }
    // shortcut: skylight approximates rain shelter; use a rain-height map when the API exposes one.
    let receives_rain = overworld && frame.precipitation == 1u && !leafy && input.material != 13u
        && input.material != 14u && input.fluid == 0u && !input.translucent && input.emission == 0.0;
    let rain_exposure = f32(receives_rain) * smoothstep(0.85, 0.99, input.light.y);
    // The post pass keeps rainwater longer than frame.wetness and shades only visible solid terrain.
    set_surface(n, smoothness, rain_exposure);
    return Surface(vec4<f32>(gs_linear(col), base.a));
}

fn gs_water(input: MaterialInput) -> Surface {
    let world = input.position + frame.camera_position;
    let dist = length(input.position);
    let v = input.position / -dist;
    let top = input.face == 1u;
    let t = frame.time * wave_speed;
    let l = frame.light_direction;

    // Top faces follow the waves plus small ripples that make the sparkles; side faces keep their normal.
    var n = input.normal;
    if top {
        let ripple = vec2<f32>(
            gs_noise(vec3<f32>(world.xz * 4.0, t * 0.7)) - 0.5,
            gs_noise(vec3<f32>(world.xz * 4.0 + vec2<f32>(7.3, 1.9), t * 0.7)) - 0.5);
        n = normalize(gs_water_normal(world.xz) + vec3<f32>(ripple.x, 0.0, ripple.y) * 0.35 / (1.0 + dist * 0.02));
        let impacts = gs_rain_ripples(world.xz) * smoothstep(0.85, 0.99, input.light.y) * exp(-dist * 0.035);
        n = normalize(n + vec3<f32>(impacts.x, 0.0, impacts.y));
    }
    if dot(n, v) < 0.0 {
        n = -n;
    }

    // Refraction: what lies behind the water, shifted by the waves, more where the water is deeper.
    let thick_here = max(gs_behind(input.screen) - dist, 0.0);
    let shift = n.xz * 0.04 * clamp(thick_here, 0.0, 1.0) / (1.0 + dist * 0.08);
    var ruv = clamp(input.screen + shift, vec2<f32>(0.001), vec2<f32>(0.999));
    let behind_shifted = gs_behind(ruv);
    var thick = behind_shifted - dist;
    if thick < 0.0 {
        // The shifted ray would show something in front of the water.
        ruv = input.screen;
        thick = thick_here;
    }
    // Falling water is a thin sheet, however far the land behind it is: without this a waterfall
    // against the sky was as dark as the deep sea.
    if !top {
        thick = min(thick, 3.5);
    }
    let refracted = gs_gamma(textureLoad(opaque_color, gs_screen_texel(ruv), 0).rgb);

    let day = mix(0.15, 1.0, gs_dayf()) * max(input.light.y, 0.25);
    var col: vec3<f32>;
    if frame.eye_in == 1u {
        // From below: the world above shows in a round window overhead, the deep reflects around it.
        // The surface glitters where the waves tilt toward the light.
        let window = smoothstep(0.35, 0.65, max(dot(n, v), 0.0));
        let sparkle = pow(max(dot(n, normalize(l + v)), 0.0), 60.0) * 0.6;
        col = mix(vec3<f32>(0.03, 0.2, 0.3) * day, refracted * 1.15 + vec3<f32>(0.1, 0.25, 0.3) * day, window);
        col += gs_light_color() * sparkle * day;
        return Surface(vec4<f32>(gs_linear(col), 1.0));
    }

    // Water takes red first, then green: shallow water is turquoise, deep water dark blue.
    let absorb = exp(-thick * vec3<f32>(0.42, 0.09, 0.055));
    let scatter = mix(vec3<f32>(0.03, 0.42, 0.45), vec3<f32>(0.01, 0.07, 0.22), 1.0 - exp(-thick * 0.12)) * day;
    col = mix(refracted * absorb, scatter, 1.0 - exp(-thick * 0.25));

    // Reflection: the mirror, else the sky along the reflected ray.
    let fresnel = 0.02 + 0.98 * pow(1.0 - max(dot(n, v), 0.0), 5.0);
    var r = reflect(-v, n);
    r.y = abs(r.y);
    var reflected = mix(gs_sky_color(), gs_atmosphere(r, frame.sun_direction), gs_dayf() * (1.0 - frame.rain));
    // The mirror is the world flipped about the flat water plane, so only flat tops may use it:
    // waterfalls and the sides of flowing water reflect the sky.
    // (Not by the face's own tilt: the waves tilt every top face a little, and judging each block by
    // it left a checkerboard of mirrored and unmirrored squares.)
    if frame.has_reflection == 1u && top {
        reflected = gs_gamma(textureSampleLevel(reflection, reflection_sampler, input.screen + n.xz * 0.02, 0.0).rgb);
    }
    col = mix(col, reflected, fresnel * select(0.5, 1.0, top));

    // Foam: along shores and rocks where the water is thin, and on falling water.
    var foam = 0.0;
    if top {
        let pattern = gs_noise(vec3<f32>(world.xz * 3.0 + gs_wind_dir() * t * 0.4, t * 0.6));
        let edge = 1.0 - smoothstep(0.0, 0.7, thick_here);
        foam = edge * smoothstep(0.35, 0.75, pattern + (1.0 - smoothstep(0.0, 0.25, thick_here)) * 0.5);
    } else {
        // Falling water: thin streaks running down, faint, and fainter still by night. (Round patches of
        // foam here looked like pale blotches crawling over the fall.)
        let streak = gs_noise(vec3<f32>((world.x + world.z) * 7.0, world.y * 0.3 + t * 2.5, world.x - world.z));
        foam = smoothstep(0.55, 0.95, streak) * 0.22 * mix(0.2, 1.0, gs_dayf());
    }
    // Foam is only as bright as the light on it: by night it was a bright speckle on falling water.
    col = mix(col, vec3<f32>(0.95, 0.97, 1.0) * day, foam);

    // Sun glints: a sharp highlight plus sparkles from the ripples; bloom makes them glow.
    let half_vec = normalize(l + v);
    let nh = max(dot(n, half_vec), 0.0);
    let glint = (pow(nh, 500.0) * 1.2 + pow(nh, 2500.0) * 4.0) * max(input.light.y, 0.2) * f32(top) * gs_cloud_shadow(input.position);
    col += gs_light_color() * glint;
    col += vec3<f32>(0.45, 0.55, 0.75) * gs_storm_flash() * max(n.y, 0.0) * input.light.y * 0.25;
    return Surface(vec4<f32>(gs_linear(min(col, vec3<f32>(1.0))), 1.0));
}

// The Nether portal: a thin sheet of violet liquid light. What lies behind shows through it, bent by
// slow ripples and tinted; the sheet glows from inside, brighter where the ripples crest, and shines at
// a flat angle like glass. Drawn in world space, so the blocks of one portal join up.
fn gs_portal_height(p: vec2<f32>, t: f32) -> f32 {
    let warp = gs_noise(vec3<f32>(p * 0.9 + vec2<f32>(0.0, t * 0.15), t * 0.1)) - 0.5;
    return gs_noise(vec3<f32>(p * 2.2 + warp * 2.0 + vec2<f32>(t * 0.1, -t * 0.35), t * 0.25))
        + 0.5 * gs_noise(vec3<f32>(p * 5.0 - warp * 3.0 + vec2<f32>(0.0, -t * 0.6), t * 0.4));
}

fn gs_portal(input: MaterialInput) -> Surface {
    let world = input.position + frame.camera_position;
    let p = vec2<f32>(world.x + world.z, world.y);
    let t = frame.time;
    let dist = length(input.position);
    let h = gs_portal_height(p, t);
    let slope = vec2<f32>(gs_portal_height(p + vec2<f32>(0.06, 0.0), t) - h, gs_portal_height(p + vec2<f32>(0.0, 0.06), t) - h) / 0.06;

    // Behind the sheet, bent by the ripples (less from afar, and not if that would show something in front).
    var ruv = clamp(input.screen + slope * 0.02 / (1.0 + dist * 0.1), vec2<f32>(0.001), vec2<f32>(0.999));
    if gs_behind(ruv) < dist {
        ruv = input.screen;
    }
    let behind = gs_gamma(textureLoad(opaque_color, gs_screen_texel(ruv), 0).rgb);

    let v = normalize(-input.position);
    let facing = abs(dot(input.normal, v));
    let glow = mix(vec3<f32>(0.10, 0.01, 0.24), vec3<f32>(0.50, 0.14, 0.85), smoothstep(0.45, 1.2, h));
    var col = behind * vec3<f32>(0.55, 0.3, 0.8) * 0.55 + glow * (0.55 + 0.1 * sin(t * 1.3));
    // Crests catch the light as thin bright lines; the sheet mirrors violet at a flat angle.
    col += vec3<f32>(0.9, 0.6, 1.0) * smoothstep(1.6, 2.6, length(slope)) * 0.35;
    col += vec3<f32>(0.6, 0.3, 1.0) * pow(1.0 - facing, 4.0) * 0.6;
    return Surface(vec4<f32>(gs_linear(col), 1.0));
}
fn material(input: MaterialInput) -> Surface {
    if input.material == 23u {
        return gs_portal(input);
    }
    if input.fluid == 1u {
        return gs_water(input);
    }
    return gs_terrain(input);
}
