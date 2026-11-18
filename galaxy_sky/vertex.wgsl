// Galaxy Sky: where corners are drawn. Water rolls with the waves; leaves, grass, flowers and water plants
// move with the wind or the water. Material ids are the manifest's [[materials]].
fn vertex(input: VertexInput) -> vec3<f32> {
    var p = input.position;
    let world = p + frame.camera_position;

    // Water: only corners in the top half of a block move, so a block's side and top meet with no gap.
    if input.fluid == 1u {
        if fract(world.y) > 0.5 {
            p.y += gs_wave(world.xz);
        }
        return p;
    }

    // Each plant column gets its own rhythm, so a meadow does not move as one. (Plants sit inside their
    // block, so every corner of one plant gets the same value.)
    let own = gs_hash13(vec3<f32>(floor(world.xz), 7.0));
    // Sheltered plants (no sky above) barely move.
    let open = 0.15 + 0.85 * smoothstep(0.2, 0.8, input.light.y);
    let wind = gs_wind() * open;
    let dir = gs_wind_dir();

    if input.material == 10u {
        // Leaves: the whole canopy leans with the gusts and flutters. Leaf blocks share corners, so the
        // motion depends on the position only: a shared corner moves the same for every block.
        let lean = gs_gust(world.xz, 0.8) * 0.035;
        let flutter = sin(frame.time * 3.1 + dot(world, vec3<f32>(1.3, 2.1, 1.7))) * 0.02;
        p += vec3<f32>(dir.x * lean + flutter, flutter * 0.6, dir.y * lean - flutter) * wind;
    } else if input.material == 11u {
        // Grass, flowers, crops: the root stays, the top bends. The top of the sprite is uv.y 0.
        let top = 1.0 - input.uv.y;
        let bend = (gs_gust(world.xz, 1.0 + own * 0.6) * 0.5 + 0.25) * 0.11 * top * wind;
        let side = sin(frame.time * (1.7 + own) + own * 30.0) * 0.03 * top * wind;
        p += vec3<f32>(dir.x * bend - dir.y * side, -abs(bend) * 0.25, dir.y * bend + dir.x * side);
    } else if input.material == 12u {
        // Water plants: slow, with the swell, whatever the wind above.
        let top = 1.0 - input.uv.y;
        let t = frame.time * wave_speed;
        let sway = sin(dot(world.xz, dir) * 0.6 - t * 1.1 + world.y * 0.8 + own * 6.0) * 0.12 * (0.3 + 0.7 * top);
        p += vec3<f32>(dir.x * sway, 0.0, dir.y * sway);
    }
    return p;
}
