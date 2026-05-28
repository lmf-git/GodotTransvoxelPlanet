//! Port of `scripts/planet/density.gd`'s composition, on top of our own
//! hand-rolled noise (`crate::noise`) — no external noise crate. The layer
//! structure (continents, ridges, hills, spires, plateaus, canyons, caves) and
//! the height budget are the same; only the underlying noise basis differs, so
//! the planet's look will need re-tuning.

use crate::noise::{Fractal, Noise};

// Height budget cut ~3.5× for the 24 km planet, so mountains read at roughly
// Earth-like proportions (Everest is ~0.14% of Earth's radius; 170 m / 24 km ≈
// 0.7% — still gameplay-friendly but no longer cartoonishly tall on the
// horizon). The proportional "continent" lift, ridge/spire amplitudes, and
// cave depth all drop together so terrain features stay visually balanced
// against each other.
const MAX_TERRAIN_HEIGHT: f32 = 170.0;
const MAX_SPIRE_HEIGHT: f32 = 120.0;
const MAX_PLATEAU_RISE: f32 = 65.0;
const MAX_CANYON_DEPTH: f32 = 75.0;
const CAVE_BOTTOM_DEPTH: f32 = 110.0;

/// Godot's `smoothstep`, including the reversed-edge case (e0 > e1) used by the
/// cave carve.
#[inline]
fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn mk(seed: i32, ft: Fractal, freq: f32, octaves: i32, lacunarity: f32, gain: f32) -> Noise {
    Noise::new(seed, freq, octaves, lacunarity, gain, ft)
}

pub struct PlanetDensity {
    radius: f32,
    enable_caves: bool,
    continent: Noise,
    ridge: Noise,
    detail: Noise,
    warp: Noise,
    cave: Noise,
    uber: Noise,
    uber_warp: Noise,
    spire: Noise,
    terrace: Noise,
    canyon: Noise,
    biome: Noise,
}

impl PlanetDensity {
    pub fn new(seed: i32, radius: f32) -> Self {
        use Fractal::{Fbm, Ridged};
        // Same seeds/frequencies/octaves as density.gd; the GDScript noise-type
        // distinction (Perlin vs SimplexSmooth) collapses onto our single
        // Perlin basis. Layers without a fractal type in GDScript were FBM.
        Self {
            radius,
            enable_caves: true,
            continent: mk(seed, Fbm, 0.00022, 6, 2.1, 0.55),
            ridge: mk(seed + 17, Ridged, 0.00085, 7, 2.2, 0.58),
            detail: mk(seed + 41, Fbm, 0.0017, 2, 2.0, 0.5),
            warp: mk(seed + 113, Fbm, 0.00035, 2, 2.0, 0.5),
            cave: mk(seed + 257, Fbm, 0.0055, 3, 2.1, 0.55),
            uber: mk(seed + 619, Fbm, 0.00045, 3, 2.0, 0.5),
            uber_warp: mk(seed + 733, Fbm, 0.00028, 2, 2.0, 0.5),
            spire: mk(seed + 829, Ridged, 0.0011, 3, 2.1, 0.55),
            terrace: mk(seed + 911, Fbm, 0.0009, 3, 2.0, 0.5),
            canyon: mk(seed + 977, Ridged, 0.0008, 3, 2.0, 0.5),
            biome: mk(seed + 1031, Fbm, 0.00018, 3, 2.0, 0.5),
        }
    }

    /// Density at a world-space point. Positive = solid (inside the planet).
    pub fn sample(&self, x: f32, y: f32, z: f32) -> f32 {
        let r = (x * x + y * y + z * z).sqrt();
        if r < 0.0001 {
            return self.radius;
        }
        let inv_r = 1.0 / r;
        let (nx, ny, nz) = (x * inv_r, y * inv_r, z * inv_r);

        // Domain-warp the look-up direction along the radial.
        let w = self.warp.get_noise_3d(x, y, z) * 240.0;
        let (psx, psy, psz) = (x + nx * w, y + ny * w, z + nz * w);

        let mut continent = self.continent.get_noise_3d(psx, psy, psz);
        // More spread (×1.5) + lower mean (−0.3) so a good fraction of the
        // planet drops below the sea sphere (radius − 12) and oceans form, like
        // Earth. The hand-rolled noise has a different range than FastNoiseLite,
        // so this is re-tuned; surface_radius_stats() reports the actual range.
        continent = continent * 1.5 - 0.3;

        let land_mask = smoothstep(-0.05, 0.35, continent);

        let uwx = self.uber_warp.get_noise_3d(x, y, z) * 280.0;
        let uwy = self.uber_warp.get_noise_3d(x + 131.0, y - 47.0, z + 19.0) * 280.0;
        let uwz = self.uber_warp.get_noise_3d(x - 73.0, y + 11.0, z - 233.0) * 280.0;
        let region = self.uber.get_noise_3d(x + uwx, y + uwy, z + uwz);
        let mountain_belt = smoothstep(0.10, 0.50, region);
        let hill_belt = 1.0 - smoothstep(-0.30, 0.25, region);

        let mut ridge = self.ridge.get_noise_3d(psx, psy, psz).abs();
        ridge = 1.0 - ridge;
        ridge = ridge.powf(2.8);
        ridge *= land_mask * mountain_belt;

        let mut hills = self
            .uber
            .get_noise_3d(x * 2.7 + 511.0, y * 2.7 - 219.0, z * 2.7 + 83.0);
        hills *= land_mask * hill_belt;

        let detail = self.detail.get_noise_3d(x, y, z);

        let biome = self
            .biome
            .get_noise_3d(x + uwx * 1.7, y + uwy * 1.7, z + uwz * 1.7);
        let spire_mask = smoothstep(0.55, 0.74, biome) * land_mask;
        let plateau_mask = smoothstep(-0.05, 0.15, biome)
            * (1.0 - smoothstep(0.30, 0.45, biome))
            * land_mask;
        let canyon_mask = (1.0 - smoothstep(-0.45, -0.25, biome)) * land_mask;

        let spire_raw = self.spire.get_noise_3d(x, y, z).abs();
        let spire = (1.0 - spire_raw).clamp(0.0, 1.0).powf(3.0) * spire_mask;

        let terr_raw = self.terrace.get_noise_3d(x, y, z) * 0.5 + 0.5;
        let terr_tiers = 3.0_f32;
        let terr_scaled = terr_raw * terr_tiers;
        let terr_step = terr_scaled.floor();
        let terr_frac = terr_scaled - terr_step;
        let terr_smoothed = terr_step + smoothstep(0.30, 0.70, terr_frac);
        let plateau = (terr_smoothed / terr_tiers) * plateau_mask;

        let canyon_raw = self.canyon.get_noise_3d(psx, psy, psz).abs();
        let canyon = (1.0 - canyon_raw).clamp(0.0, 1.0).powf(2.0) * canyon_mask;

        let height = continent * 75.0
            + ridge * MAX_TERRAIN_HEIGHT
            + hills * 14.0
            + detail * 1.5
            + spire * MAX_SPIRE_HEIGHT
            + plateau * MAX_PLATEAU_RISE
            - canyon * MAX_CANYON_DEPTH;

        let surface_r = self.radius + height;
        let mut d = surface_r - r;

        if self.enable_caves && d > 8.0 && d < CAVE_BOTTOM_DEPTH {
            let cave_v = self.cave.get_noise_3d(x, y, z);
            let cave_v2 = self
                .cave
                .get_noise_3d(x * 1.7 + 91.0, y * 0.6 - 13.0, z * 1.7 + 47.0);
            let tunnel = cave_v.abs() + cave_v2.abs() * 0.7;
            let carve_amount = smoothstep(0.34, 0.12, tunnel) * 28.0;
            let depth_fade = smoothstep(8.0, 32.0, d)
                * smoothstep(CAVE_BOTTOM_DEPTH, CAVE_BOTTOM_DEPTH - 80.0, d);
            d -= carve_amount * depth_fade;
        }

        d
    }
}
