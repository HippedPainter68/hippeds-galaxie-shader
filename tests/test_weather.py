"""Weather checks for rainwater lifetime, float16 precision and world-anchored puddles.

Run: python shaderpacks/tests/test_weather.py
The pack's WGSL must additionally pass horizon-shader check; these are numerical model checks.
"""

import math
from pathlib import Path
import struct
import tomllib
import unittest


PACK = Path(__file__).resolve().parents[1] / "galaxy_sky"


def half(value):
    return struct.unpack("e", struct.pack("e", value))[0]


def rain_deadline(before, now, dt, rain, wetness, drying=180, precipitation=1, dimension=0):
    if dimension != 0:
        return 0
    deadline = before - 1
    if before <= 0 or dt <= 0:
        deadline = now
    elif deadline - now > drying + 4:
        deadline -= 3600
    if precipitation == 1 and rain > 0.001:
        deadline = max(deadline, now + wetness * drying)
    return deadline + 1 if deadline > now else 0


def water_level(deadline, now, drying=180):
    return max(0, min(1, (deadline - 1 - now) / drying)) if deadline > 0 else 0


def smoothstep(lo, hi, value):
    t = max(0, min(1, (value - lo) / (hi - lo)))
    return t * t * (3 - 2 * t)


def puddle(hollow, wet):
    waterline = 0.86 + (0.42 - 0.86) * max(0, min(1, wet))
    return smoothstep(waterline, waterline + 0.035, hollow) * smoothstep(0.04, 0.2, wet)


class WeatherTests(unittest.TestCase):
    def test_dry_world_stays_dry(self):
        self.assertEqual(rain_deadline(0, 10, 1 / 60, 0, 0), 0)

    def test_puddles_form_gradually(self):
        levels = []
        for seconds in (1, 10, 30, 60, 120):
            wetness = 1 - 2 ** (-seconds / 30)
            deadline = half(rain_deadline(0, seconds, 1 / 60, 1, wetness))
            levels.append(water_level(deadline, seconds))
        self.assertEqual(levels, sorted(levels))
        self.assertLess(levels[0], 0.03)
        self.assertGreater(levels[-1], 0.9)

    def test_drying_is_independent_of_fps_and_survives_hour_wrap(self):
        for fps in (30, 60, 144, 240):
            with self.subTest(fps=fps):
                # Fully soaked just before frame.time wraps to zero.
                deadline = half(rain_deadline(0, 3595, 1 / fps, 1, 1))
                for elapsed in range(1, 181):
                    for frame in range(fps):
                        now = (3595 + elapsed - 1 + (frame + 1) / fps) % 3600
                        deadline = half(rain_deadline(deadline, now, 1 / fps, 0, 0))
                    self.assertAlmostEqual(water_level(deadline, now), 1 - elapsed / 180, delta=0.015)
                self.assertEqual(deadline, 0)

    def test_cold_dry_biomes_and_other_dimensions_do_not_fill(self):
        for precipitation in (0, 2):
            self.assertEqual(rain_deadline(0, 20, 1 / 60, 1, 1, precipitation=precipitation), 0)
        for dimension in (-1, 1, 2):
            self.assertEqual(rain_deadline(201, 20, 1 / 60, 1, 1, dimension=dimension), 0)

    def test_new_rain_refills_remaining_puddles(self):
        deadline = rain_deadline(181, 120, 1 / 60, 1, 0.8)
        self.assertAlmostEqual(water_level(deadline, 120), 0.8)

    def test_history_reset_does_not_import_an_old_world(self):
        self.assertEqual(rain_deadline(3500, 50, 0, 0, 1), 0)
        self.assertEqual(rain_deadline(0, 50, 1 / 60, 0, 1), 0)

    def test_shallow_puddles_disappear_first_and_never_grow_while_drying(self):
        hollows = (0.35, 0.48, 0.56, 0.63, 0.72, 0.82)
        for hollow in hollows:
            masks = [puddle(hollow, step / 100) for step in range(101)]
            self.assertEqual(masks, sorted(masks))
            self.assertEqual(masks[0], 0)
        self.assertLess(puddle(0.48, 0.5), puddle(0.72, 0.5))
        self.assertTrue(all(math.isfinite(puddle(h, w)) for h in hollows for w in (0, 0.2, 0.7, 1)))

    def test_puddle_positions_stay_in_world_space_with_walking_bob(self):
        # Reversed perspective with the same translated walking pose used by Horizon.
        near, far = 0.05, 512.0
        a, b = near / (far - near), far * near / (far - near)
        target = (3.25, 65.0, -12.75)
        old_errors = []
        for phase in (-1.0, -0.5, 0.0, 0.5, 1.0):
            camera = (phase * 3, 66.62, phase * 0.7)
            bob = (math.sin(phase * math.pi) * 0.05, -abs(math.cos(phase * math.pi)) * 0.08, 0)
            p = tuple(w - c + t for w, c, t in zip(target, camera, bob))
            uv = (0.5 + p[0] / -p[2] * 0.5, 0.5 - p[1] / -p[2] * 0.5)
            depth = b / -p[2] - a

            def view_position(d):
                distance = b / (d + a)
                return ((uv[0] * 2 - 1) * distance - bob[0],
                        (1 - uv[1] * 2) * distance - bob[1], -distance - bob[2])

            position = view_position(depth)
            world = tuple(c + p for c, p in zip(camera, position))
            self.assertLess(math.dist(world, target), 1e-10)
            # The old ray*distance shortcut magnifies the near ray's bob offset over the ground.
            ray = view_position(0.5)
            scale = math.dist(position, (0, 0, 0)) / math.dist(ray, (0, 0, 0))
            old_world = tuple(c + r * scale for c, r in zip(camera, ray))
            old_errors.append(math.dist(old_world, target))
            direction = tuple(f - n for f, n in zip(view_position(0.0001), view_position(0.5)))
            direction = tuple(d / math.dist(direction, (0, 0, 0)) for d in direction)
            expected_direction = tuple(d / math.dist(p, (0, 0, 0)) for d in p)
            self.assertLess(math.dist(direction, expected_direction), 1e-10)
        self.assertGreater(max(old_errors), 1.0)
        # Keep the actual shader connected to the exact depth position, including reflection/shadows.
        final = (PACK / "post/final.wgsl").read_text()
        self.assertIn("let position = view_position(input.uv, depth);", final)
        self.assertIn("let world = frame.camera_position + position;", final)
        self.assertIn("normalize(view_position(input.uv, 0.0001) - view_position(input.uv, 0.5))", final)
        self.assertIn("gs_puddle_mirror(position, dir, n)", final)
        self.assertIn("gs_cloud_shadow(position)", final)
        self.assertNotIn("dir * dist", final)

    def test_history_wiring_and_shader_defaults(self):
        manifest = tomllib.loads((PACK / "horizon-shaders.toml").read_text())
        self.assertEqual(manifest["post"][-2]["file"], "post/final.wgsl")
        self.assertEqual(manifest["post"][-1]["file"], "post/lens.wgsl")
        options = {option["id"]: option for option in manifest["options"]}
        self.assertEqual(options["puddle_drying"]["default"], 180)
        self.assertIn("set_surface(n, smoothness, rain_exposure)", (PACK / "material.wgsl").read_text())
        # Shader API 0.2: no `history`; the expiry ping-pongs between two of the pack's own float16 targets:
        # the clock pass reads last frame's copy, the copy pass runs after it.
        files = [entry["file"] for entry in manifest["post"]]
        outputs = {entry["file"]: entry.get("output") for entry in manifest["post"]}
        self.assertLess(files.index("post/rain_clock.wgsl"), files.index("post/rain_copy.wgsl"))
        self.assertLess(files.index("post/rain_copy.wgsl"), files.index("post/final.wgsl"))
        self.assertEqual(outputs["post/rain_clock.wgsl"], "rain_clock")
        self.assertEqual(outputs["post/rain_copy.wgsl"], "rain_prev")
        self.assertNotIn("resource", manifest)
        self.assertIn("textureLoad(rain_prev, vec2<i32>(0), 0).r", (PACK / "post/rain_clock.wgsl").read_text())
        self.assertIn("textureLoad(rain_clock, vec2<i32>(0), 0).r", (PACK / "post/rain_copy.wgsl").read_text())
        self.assertIn("textureLoad(rain_clock, vec2<i32>(0), 0).r", (PACK / "post/final.wgsl").read_text())

    def test_grass_relief_is_limited_to_turf_top_faces(self):
        manifest = tomllib.loads((PACK / "horizon-shaders.toml").read_text())
        materials = {entry["id"]: entry["sprites"] for entry in manifest["materials"]}
        self.assertEqual(materials[22], ["block/grass_block_top"])
        shader = (PACK / "material.wgsl").read_text()
        self.assertIn("input.material == 22u && input.normal.y > 0.9", shader)
        self.assertIn("return (1.0 - input.height) * 0.045", shader)

    def test_wood_relief_is_limited_to_bark_and_boards(self):
        manifest = tomllib.loads((PACK / "horizon-shaders.toml").read_text())
        materials = {entry["id"]: entry["sprites"] for entry in manifest["materials"]}
        self.assertEqual(materials[20], ["block/*_log", "block/*_stem"])
        self.assertEqual(materials[21], ["block/*_planks", "block/bamboo_mosaic"])
        shader = (PACK / "material.wgsl").read_text()
        self.assertIn("input.material == 20u", shader)
        self.assertIn("return (1.0 - input.height) * 0.035", shader)
        self.assertIn("input.material == 21u", shader)
        self.assertIn("return (1.0 - input.height) * 0.012", shader)
        self.assertEqual(manifest["displacement"], {"distance": 8.0, "cells": 16})

    def test_small_rain_impacts_and_farmland_relief(self):
        for age in (0, 0.01, 0.1, 0.3, 0.6, 0.99, 1):
            radius = age * 0.48 / 3.0
            envelope = (1-age)**2 * smoothstep(0, 0.1, age)
            self.assertTrue(0 <= radius <= 0.16)
            self.assertTrue(0 <= envelope <= 1)
        self.assertEqual((1-1)**2, 0)
        manifest = tomllib.loads((PACK / "horizon-shaders.toml").read_text())
        self.assertEqual(manifest["displacement"], {"distance": 8.0, "cells": 16})
        self.assertEqual([m["id"] for m in manifest["materials"] if "block/farmland" in m["sprites"]], [19])
        material = (PACK / "material.wgsl").read_text()
        self.assertIn("input.material == 19u && input.normal.y > 0.9", material)
        self.assertIn("return (1.0 - input.height) * 0.08", material)


if __name__ == "__main__":
    unittest.main(verbosity=2)
