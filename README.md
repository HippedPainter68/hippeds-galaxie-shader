# Hipped´s Galaxie Shader

A shader pack for [Horizon](https://playhorizon.dev), Minecraft Java Edition rewritten in Rust, written in
WGSL for Horizon's shader API 0.2.

## What it does

**Sky**
- By night: a painted galaxy with glowing nebulae, a blue gas giant and four moons that turn, twinkling
  stars, rare shooting stars, now and then a comet that stays for several nights, and an aurora in cold
  biomes.
- By day: a scattered-light blue sky with volumetric clouds. Some days are clear and some overcast; the
  clouds cast shadows and let sun shafts through their gaps.
- After rain: rainbows (sometimes a double one), fog bows on damp mornings, rare solar and lunar eclipses.

**World**
- Sun and moon shadows; torches and other lights fill shadows near them.
- Coloured block light (lava orange, soul fire blue, redstone red) and light from held torches with
  Horizon's Dynamic lights.
- Leaves, grass and flowers sway in the wind; sunlight shines through leaves.
- Rain darkens the ground and leaves puddles with reflections that dry over a few minutes; rain rings and
  sheet lightning in thunderstorms.
- Water with waves, refraction, depth colour, foam, caustics and a mirror; light shafts and floating specks
  under water.
- Bloom, light shafts, biome-tinted haze, auto exposure and a filmic tone curve; optional depth of field,
  motion blur and chromatic aberration.

**Nether and End**
- The Nether glows in the biome's colour, lit from below by the lava sea, with heat shimmer, rising embers
  and an animated portal.
- The End gets a black hole with a glowing accretion disc over a drifting violet nebula.

Every effect has an option on the pack's options page.

## Install

Get the `.hshader` file from the Horizon registry once it is listed, or build it from this repository (below), and put it in the `shaderpacks` folder next to Horizon's `options.txt`, or copy the `galaxy_sky`
folder there. Then pick it on Options > Horizon Settings > Shader Packs.

Needs a Horizon build that serves shader API 0.2.

## Build from source

```bash
horizon-shader check galaxy_sky
horizon-shader pack galaxy_sky --out galaxy_sky.hshader
```

The pack's textures (night sky, planets, cloud noise) are painted by `skygen`, a small Rust program in this
repository:

```bash
cd skygen
cargo run --release -- ../galaxy_sky
```

`tests/test_weather.py` checks the rainwater model (`python tests/test_weather.py`). `test-rig.ps1` starts a
second, windowless Horizon in scratch folders with this pack, for screenshots through `horizon-ctl`.

## Licence

MIT, see [LICENSE](LICENSE). The pack contains no code, textures or data from Minecraft, Mojang or
Microsoft: every texture is painted by `skygen`.
