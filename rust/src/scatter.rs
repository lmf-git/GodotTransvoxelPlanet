//! Deterministic prop scatter (rocks + biome foliage), computed on the worker pool
//! right after meshing so it stays OFF the main thread. Previously this ran in
//! GDScript (`scatter.gd`) when each near chunk's mesh was applied — thousands of
//! per-triangle noise samples on the main thread, the streaming hitch. The meshes
//! and materials still live in GDScript; only the per-instance TRANSFORM buffers are
//! produced here (MultiMesh `TRANSFORM_3D` layout: 12 floats per instance).

use crate::noise::{Fractal, Noise};

// ── Rocks ────────────────────────────────────────────────────────────────────
const ROCK_MIN_SLOPE: f32 = 0.45;
const ROCK_MAX_SLOPE: f32 = 0.93;
const ROCK_PROBABILITY: f32 = 0.18;
const ROCK_MIN_SCALE: f32 = 0.6;
const ROCK_MAX_SCALE: f32 = 1.7;
// Cliff outcrops on steep slopes — denser + a wider steep band than before, so the
// cliffs/canyon walls/mountain faces are actually clad in rock meshes instead of bare
// shaded terrain (the "there should be cliff/rock meshes on steep surfaces" report).
const CLIFF_MIN_SLOPE: f32 = 0.0;
const CLIFF_MAX_SLOPE: f32 = 0.52;
const CLIFF_PROBABILITY: f32 = 0.17;
const CLIFF_MIN_SCALE: f32 = 2.6;
const CLIFF_MAX_SCALE: f32 = 7.5;
const MIN_ALTITUDE_OFFSET: f32 = 4.0;

// ── Foliage ──────────────────────────────────────────────────────────────────
pub const FOLIAGE_TYPE_COUNT: usize = 9;
const FT_CONIFER: usize = 0;
const FT_BROADLEAF: usize = 1;
const FT_PALM: usize = 2;
const FT_CACTUS: usize = 3;
const FT_GRASS: usize = 4;
const FT_DEADBUSH: usize = 5;
const FT_FERN: usize = 6;
const FT_FLOWER: usize = 7;
const FT_SHRUB: usize = 8;
const FOLIAGE_MIN_SLOPE: f32 = 0.74;
const FOLIAGE_PROBABILITY: f32 = 0.55;
const FOLIAGE_MIN_ALT: f32 = 5.0;
const FOLIAGE_MAX_ALT: f32 = 560.0;
const FOLIAGE_LAPSE_RATE: f32 = 0.6;
const FOLIAGE_LAPSE_FULL: f32 = 1500.0;

/// Result handed back to GDScript: one rock buffer + one buffer per foliage type.
pub struct ScatterData {
    pub rocks: Vec<f32>,
    pub foliage: Vec<Vec<f32>>, // FOLIAGE_TYPE_COUNT entries
}

impl ScatterData {
    fn empty() -> Self {
        ScatterData { rocks: Vec::new(), foliage: vec![Vec::new(); FOLIAGE_TYPE_COUNT] }
    }
}

// ── tiny vec3 helpers (local; density.rs keeps its own private copies) ────────
#[inline]
fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
#[inline]
fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}
#[inline]
fn norm(a: [f32; 3]) -> [f32; 3] {
    let l = dot(a, a).sqrt();
    if l < 1e-9 { [0.0, 0.0, 1.0] } else { [a[0] / l, a[1] / l, a[2] / l] }
}

// Deterministic per-triangle RNG (xorshift32). Seeded from the chunk seed + tri
// index, so scatter is stable across runs / regardless of when a chunk is meshed.
struct Rng(u32);
impl Rng {
    #[inline]
    fn next(&mut self) -> u32 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.0 = if x == 0 { 0x9E3779B1 } else { x };
        self.0
    }
    #[inline]
    fn f01(&mut self) -> f32 {
        self.next() as f32 / u32::MAX as f32
    }
    #[inline]
    fn range(&mut self, lo: f32, hi: f32) -> f32 {
        lo + (hi - lo) * self.f01()
    }
}

const TAU: f32 = std::f32::consts::TAU;

/// Build the scatter transforms for one meshed chunk. `positions`/`normals` are flat
/// (3 floats per vertex); `indices` a triangle soup. `in_settlement(dir)` returns
/// true if a unit direction falls on a city pad / road (those props are skipped).
/// `want_foliage` is false for airless bodies (the moon).
pub fn build(
    positions: &[f32],
    normals: &[f32],
    indices: &[i32],
    radius: f32,
    sea_offset: f32,
    coords_seed: u32,
    want_foliage: bool,
    in_settlement: &dyn Fn([f32; 3]) -> bool,
) -> ScatterData {
    if indices.len() < 3 || positions.is_empty() {
        return ScatterData::empty();
    }
    let mut out = ScatterData::empty();
    let tri_count = indices.len() / 3;

    // Climate fields — mirror scatter.gd's FastNoiseLite (seed/freq), 5-octave fbm.
    let humidity_n = Noise::new(9701, 0.0009, 5, 2.0, 0.5, Fractal::Fbm);
    let temp_n = Noise::new(4451, 0.0006, 5, 2.0, 0.5, Fractal::Fbm);
    let region_n = Noise::new(2287, 0.00035, 5, 2.0, 0.5, Fractal::Fbm);

    let rock_min_r = radius + sea_offset + MIN_ALTITUDE_OFFSET;
    let fol_min_r = radius + sea_offset + FOLIAGE_MIN_ALT;
    let fol_max_r = radius + sea_offset + FOLIAGE_MAX_ALT;
    let beach_alt = sea_offset + 6.0;
    let pole = [0.0f32, 1.0, 0.0];

    let vert = |i: i32| -> [f32; 3] {
        let k = (i as usize) * 3;
        [positions[k], positions[k + 1], positions[k + 2]]
    };
    let nrm = |i: i32| -> [f32; 3] {
        let k = (i as usize) * 3;
        [normals[k], normals[k + 1], normals[k + 2]]
    };

    for ti in 0..tri_count {
        let mut rng = Rng(coords_seed ^ ((ti as u32).wrapping_mul(0x9E3779B1)).max(1));
        let i0 = indices[ti * 3];
        let i1 = indices[ti * 3 + 1];
        let i2 = indices[ti * 3 + 2];
        let v0 = vert(i0);
        let v1 = vert(i1);
        let v2 = vert(i2);
        let centroid = [
            (v0[0] + v1[0] + v2[0]) / 3.0,
            (v0[1] + v1[1] + v2[1]) / 3.0,
            (v0[2] + v1[2] + v2[2]) / 3.0,
        ];
        let r = dot(centroid, centroid).sqrt();
        if r < rock_min_r {
            continue;
        }
        let radial = [centroid[0] / r, centroid[1] / r, centroid[2] / r];
        if in_settlement(radial) {
            continue;
        }
        let n0 = nrm(i0);
        let n1 = nrm(i1);
        let n2 = nrm(i2);
        let n = norm([
            (n0[0] + n1[0] + n2[0]) / 3.0,
            (n0[1] + n1[1] + n2[1]) / 3.0,
            (n0[2] + n1[2] + n2[2]) / 3.0,
        ]);
        let slope = dot(n, radial).abs();

        // Rocks: shallow-ground boulders + steep-cliff outcrops, one shared buffer.
        if slope >= ROCK_MIN_SLOPE && slope <= ROCK_MAX_SLOPE && rng.f01() <= ROCK_PROBABILITY {
            let sc = rng.range(ROCK_MIN_SCALE, ROCK_MAX_SCALE);
            pack(&mut out.rocks, centroid, n, radial, rng.range(0.0, TAU), sc, sc * 0.25);
        }
        if slope >= CLIFF_MIN_SLOPE && slope <= CLIFF_MAX_SLOPE && rng.f01() <= CLIFF_PROBABILITY {
            let sc = rng.range(CLIFF_MIN_SCALE, CLIFF_MAX_SCALE);
            pack(&mut out.rocks, centroid, radial, radial, rng.range(0.0, TAU), sc, sc * 0.3);
        }

        if !want_foliage {
            continue;
        }
        if r < fol_min_r || r > fol_max_r || slope < FOLIAGE_MIN_SLOPE {
            continue;
        }
        if rng.f01() > FOLIAGE_PROBABILITY {
            continue;
        }

        // Climate (mirrors scatter.gd / the terrain shader's structure).
        let lat = dot(radial, pole).abs();
        let lapse = (((r - radius - beach_alt) / FOLIAGE_LAPSE_FULL).clamp(0.0, 1.0)) * FOLIAGE_LAPSE_RATE;
        let temp_anom = temp_n.get_noise_3d(centroid[0], centroid[1], centroid[2]) * 0.28;
        let temperature = (1.0 - lat + temp_anom - lapse).clamp(0.0, 1.0);
        let humidity = (0.5 + humidity_n.get_noise_3d(centroid[0], centroid[1], centroid[2]) * 0.95).clamp(0.0, 1.0);
        let region = region_n.get_noise_3d(centroid[0], centroid[1], centroid[2]);

        let ft = foliage_type(temperature, humidity, region, &mut rng);
        let scale = foliage_scale(ft, &mut rng);
        let yaw = rng.range(0.0, TAU);
        let sink = scale * 0.08;
        let lean = if ft >= FT_GRASS { 0.18 } else { 0.07 };
        let up = leaned_up(radial, &mut rng, lean);
        pack(&mut out.foliage[ft], centroid, up, radial, yaw, scale, sink);
    }

    out
}

// Climate → plant type (temperature × humidity, biased by region "lushness").
fn foliage_type(temperature: f32, humidity: f32, region: f32, rng: &mut Rng) -> usize {
    if temperature < 0.33 {
        if humidity > 0.42 {
            if region > 0.3 && humidity > 0.6 && rng.f01() < 0.25 {
                return FT_FERN;
            }
            return FT_CONIFER;
        }
        return if rng.f01() < 0.5 { FT_DEADBUSH } else { FT_GRASS };
    } else if temperature > 0.66 {
        if humidity > 0.5 {
            return if rng.f01() < 0.32 { FT_FERN } else { FT_PALM };
        }
        let rr = rng.f01();
        if rr < 0.5 {
            return FT_CACTUS;
        }
        return if rr < 0.8 { FT_SHRUB } else { FT_DEADBUSH };
    }
    if humidity > 0.55 {
        return if rng.f01() < 0.26 { FT_FERN } else { FT_BROADLEAF };
    }
    if region > 0.0 && rng.f01() < (0.16 + region * 0.28) {
        return FT_FLOWER;
    }
    if region < -0.2 && rng.f01() < 0.3 {
        return FT_SHRUB;
    }
    FT_GRASS
}

fn foliage_scale(ft: usize, rng: &mut Rng) -> f32 {
    match ft {
        FT_GRASS => rng.range(0.5, 1.1),
        FT_DEADBUSH => rng.range(0.5, 1.0),
        FT_CACTUS => rng.range(0.7, 1.6),
        FT_FERN => rng.range(0.5, 1.0),
        FT_FLOWER => rng.range(0.4, 0.8),
        FT_SHRUB => rng.range(0.6, 1.3),
        _ => {
            let u = rng.f01();
            0.9 + (2.6 - 0.9) * (u * u)
        }
    }
}

// Up-vector tilted up to `amount` radians off the radial in a random direction.
fn leaned_up(radial: [f32; 3], rng: &mut Rng, amount: f32) -> [f32; 3] {
    let mut t = cross(radial, [0.0, 1.0, 0.0]);
    if dot(t, t) < 1e-4 {
        t = cross(radial, [1.0, 0.0, 0.0]);
    }
    t = norm(t);
    let b = norm(cross(radial, t));
    let a = rng.range(0.0, TAU);
    let lean = rng.range(0.0, amount);
    let d = [
        radial[0] + (t[0] * a.cos() + b[0] * a.sin()) * lean,
        radial[1] + (t[1] * a.cos() + b[1] * a.sin()) * lean,
        radial[2] + (t[2] * a.cos() + b[2] * a.sin()) * lean,
    ];
    norm(d)
}

/// De-index a rock collision soup by transforming the shared rock proto-mesh (flat
/// x,y,z triangle soup, local space) by every instance in `rock_xforms` (12 floats /
/// instance, the MultiMesh row-major Basis+origin layout `pack` emits). Returns a flat
/// x,y,z triangle soup in the chunk's local frame, ready for ConcavePolygonShape3D.
/// Mirrors the Transform3D reconstruction voxel_chunk.gd used to do on the main thread.
pub fn rock_collision_soup(rock_xforms: &[f32], proto: &[f32]) -> Vec<f32> {
    let count = rock_xforms.len() / 12;
    let pverts = proto.len() / 3;
    let mut out = Vec::with_capacity(count * proto.len());
    for i in 0..count {
        let b = &rock_xforms[i * 12..i * 12 + 12];
        for k in 0..pverts {
            let (vx, vy, vz) = (proto[k * 3], proto[k * 3 + 1], proto[k * 3 + 2]);
            // World = Basis·v + origin, Basis columns = (b0,b4,b8),(b1,b5,b9),(b2,b6,b10).
            out.push(b[0] * vx + b[1] * vy + b[2] * vz + b[3]);
            out.push(b[4] * vx + b[5] * vy + b[6] * vz + b[7]);
            out.push(b[8] * vx + b[9] * vy + b[10] * vz + b[11]);
        }
    }
    out
}

// Append one instance transform (12 floats, MultiMesh row-major Basis + origin).
fn pack(out: &mut Vec<f32>, centroid: [f32; 3], up: [f32; 3], radial: [f32; 3], yaw: f32, scale: f32, sink: f32) {
    let mut seed_axis = [0.0f32, 0.0, 1.0];
    if dot(up, seed_axis).abs() > 0.95 {
        seed_axis = [1.0, 0.0, 0.0];
    }
    let tangent = norm(cross(seed_axis, up));
    let bitan = cross(up, tangent);
    let (c, s) = (yaw.cos(), yaw.sin());
    let x_axis = [
        tangent[0] * c + bitan[0] * s,
        tangent[1] * c + bitan[1] * s,
        tangent[2] * c + bitan[2] * s,
    ];
    let z_axis = [
        -tangent[0] * s + bitan[0] * c,
        -tangent[1] * s + bitan[1] * c,
        -tangent[2] * s + bitan[2] * c,
    ];
    let origin = [
        centroid[0] - radial[0] * sink,
        centroid[1] - radial[1] * sink,
        centroid[2] - radial[2] * sink,
    ];
    out.push(x_axis[0] * scale); out.push(up[0] * scale); out.push(z_axis[0] * scale); out.push(origin[0]);
    out.push(x_axis[1] * scale); out.push(up[1] * scale); out.push(z_axis[1] * scale); out.push(origin[1]);
    out.push(x_axis[2] * scale); out.push(up[2] * scale); out.push(z_axis[2] * scale); out.push(origin[2]);
}
