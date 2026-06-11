//! Baked global erosion field — the project's bridge between "infinite procedural
//! voxel planet" and "Earth-like, weathered terrain".
//!
//! The planet has no global heightmap (it's meshed per chunk), so we can't run a
//! live GPU raindrop pass over one. Instead we bake a moderate-resolution global
//! heightfield ONCE per (seed, radius), run real terrain-aging passes on it on the
//! CPU, and expose the result as a height DELTA the per-chunk density adds on top
//! of its raw fractal height. Fine detail still comes from the procedural noise;
//! this supplies the macro structure that noise alone can't: smoothed talus
//! slopes (thermal weathering) and connected, downhill-carved river valleys
//! (hydraulic / droplet erosion).
//!
//! Grid is equirectangular in object space (pole = +Y, matching the planet's spin
//! axis / terrain shader). Longitude wraps; latitude clamps at the poles. The
//! pole singularity of equirect over-weights polar cells slightly, which is
//! acceptable for a macro modifier blended under the procedural detail.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

// Grid resolution SCALES WITH RADIUS to hold a roughly constant ~50 m cell, so
// rivers/talus bake at the same physical detail whatever the planet's size. (A fixed
// 512×256 was tuned for radius ~4000; once the body grew to radius 24000 those cells
// became ~290 m and the macro erosion washed out.) Width is clamped to ERO_MAX_W so a
// huge body can't blow up bake time / memory — at the cap, cells just grow past 50 m.
// 3072×1536 ≈ 4.7 M cells ≈ 49 m cells at radius 24000.
const ERO_TARGET_CELL_M: f32 = 50.0;
const ERO_MIN_W: usize = 256;
const ERO_MAX_W: usize = 3072;

// Equirect grid dimensions (even width so longitude wraps cleanly; 2:1 height).
fn ero_dims(radius: f32) -> (usize, usize) {
    let target = (std::f32::consts::TAU * radius / ERO_TARGET_CELL_M).round();
    let mut w = (target.max(0.0) as usize).clamp(ERO_MIN_W, ERO_MAX_W);
    w &= !1usize;
    (w, w / 2)
}

// Thermal weathering (talus): sharp slopes shed material downhill until they
// settle near the talus angle (~35°). Run as a few relaxation sweeps.
const THERMAL_ITERS: usize = 10;
const TALUS_TAN: f32 = 0.70; // tan(~35°) — max stable height/run before material slides

// Hydraulic (droplet) erosion — the river-valley carver. Droplet COUNT scales with
// the cell count (constant ~1.07 droplets/cell, matching the old 140 000 over 512×256)
// so the drainage network stays as dense as the grid grows. The pass runs as a fixed
// number of independent realizations summed together — fixed (not core-count) so the
// bake is bit-identical on every machine, but spread across that many OS threads for
// speed. Each realization holds a private height+flow grid (≈ REALIZATIONS × 2 × grid
// of transient memory — ~300 MB at the 3072-wide cap).
const DROPLET_DENSITY: f32 = 1.07;
const EROSION_REALIZATIONS: usize = 8;
const MAX_LIFETIME: usize = 34;
const INERTIA: f32 = 0.05; // 0 = water turns straight downhill, 1 = keeps its heading
const SEDIMENT_CAP: f32 = 4.0;
const MIN_SLOPE: f32 = 0.01;
const DEPOSIT_RATE: f32 = 0.30;
const ERODE_RATE: f32 = 0.35;
const EVAPORATE: f32 = 0.02;
const GRAVITY: f32 = 4.0;
// Final delta is scaled by this — keeps the macro carve in a sane metre range
// relative to the height budget (peaks lowered / valleys cut by up to ~a couple
// hundred metres) without overwhelming the procedural relief.
const EROSION_STRENGTH: f32 = 1.0;
// River incision: the droplet pass carves channels but the macro grid leaves them
// too shallow to read. So we additionally cut the terrain along the DRAINAGE
// network (the normalised flow field) — deeper where more water flows — folding it
// into the height delta so rivers become real carved valleys and the water ribbons
// sit in them. (Folded into `delta`, so the density + culling bounds pick it up for
// free.)
const RIVER_INCISION: f32 = 60.0;     // max channel depth (metres) at full flow
const RIVER_INCISION_LO: f32 = 0.05;  // normalised flow where incision begins
const RIVER_INCISION_HI: f32 = 0.40;  // flow where it reaches full depth

pub struct ErosionField {
    w: usize, // equirect grid dimensions (chosen per radius by ero_dims)
    h: usize,
    delta: Vec<f32>, // eroded − raw, metres, row-major [y*w + x]
    // Per-cell water flow accumulation from the droplet pass, normalised 0..1.
    // High = a persistent channel → where rivers run.
    flow: Vec<f32>,
    // Eroded surface height displacement (raw + delta), metres. Kept so rivers can
    // be traced downhill along the SAME surface the density produces.
    height: Vec<f32>,
    // Extremes of `delta` (metres): largest deposition rise and largest erosion
    // drop. The density widens its surface-radius bounds by these so chunk culling
    // stays conservative now that erosion can move the surface either way.
    max_rise: f32,
    max_drop: f32,
}

// River tracing parameters. (Tracing runs at QUERY time on the cached field, so
// these can be tuned without invalidating the on-disk bake.)
// 160 (was 64): on a 24 km-radius planet 64 rivers worldwide meant you almost
// never encountered one — the "no rivers anywhere" read.
const MAX_RIVERS: usize = 160;
// Minimum (normalised) flow for a highland cell to spawn a river. Headwaters carry
// LOW flow (it accumulates DOWNSTREAM toward the mouth) and the field is normalised
// by the max — a downstream spike — so this must be small or almost no source
// qualifies (the "no rivers at all" bug at the old 0.10). We then sort candidates by
// flow and take the wettest, well-spaced ones.
const RIVER_SOURCE_FLOW: f32 = 0.008;
const RIVER_TRACE_STEPS: usize = 260; // max cells a river is followed downhill
const RIVER_SRC_SPACING: usize = 6; // min cells between two river sources (de-clutter)
// Lakes: when a river stalls in an inland basin (gradient ~0, still above sea) the
// water pools. We drop a lake disc there, sized by the flow that arrived.
const LAKE_MIN_ALT: f32 = 30.0; // basin floor must sit this far above sea to be a lake
const LAKE_RISE: f32 = 8.0; // water surface above the basin floor
const LAKE_MIN_RADIUS: f32 = 45.0;
const LAKE_MAX_RADIUS: f32 = 170.0;

/// An inland lake: pooled water where a river stalled. `dir` is the unit centre
/// direction, `water_disp` the surface height as a displacement (radius + this),
/// `radius` the disc radius in world units.
pub struct Lake {
    pub dir: [f32; 3],
    pub water_disp: f32,
    pub radius: f32,
}

// One field per (seed, radius), built once and shared (the density is rebuilt per
// chunk job, so the bake must NOT re-run each time — same pattern as Settlements).
type Key = (i32, u32);
static CACHE: OnceLock<Mutex<HashMap<Key, Arc<ErosionField>>>> = OnceLock::new();

fn cache() -> &'static Mutex<HashMap<Key, Arc<ErosionField>>> {
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The shared no-op field (zero delta / flow) used by bodies that skip erosion.
pub fn empty_field() -> Arc<ErosionField> {
    static EMPTY: OnceLock<Arc<ErosionField>> = OnceLock::new();
    EMPTY
        .get_or_init(|| {
            Arc::new(ErosionField {
                w: 0,
                h: 0,
                delta: Vec::new(),
                flow: Vec::new(),
                height: Vec::new(),
                max_rise: 0.0,
                max_drop: 0.0,
            })
        })
        .clone()
}

// ── Disk cache ───────────────────────────────────────────────────────────────
// The bake (full heightfield probe + thermal sweeps + millions of droplets) is
// deterministic per (seed, radius, terrain formula), yet re-ran on EVERY launch
// while all chunk workers blocked on it. Persist the finished field to disk
// (Godot's user:// dir, handed in via `set_cache_dir` before the first job) and
// reload it on later runs. The header stores a FINGERPRINT of the raw height
// function — 64 deterministic probes hashed — so editing the terrain noise or
// constants in density.rs invalidates the cache instead of loading stale data.

static CACHE_DIR: OnceLock<PathBuf> = OnceLock::new();

/// Set the directory for the on-disk erosion cache (first call wins). Called
/// from GDScript with the globalized user:// path before any chunk job runs.
pub fn set_cache_dir(path: &str) {
    if !path.is_empty() {
        let _ = CACHE_DIR.set(PathBuf::from(path));
    }
}

const DISK_MAGIC: u32 = 0x45524F42; // "EROB"
const DISK_VERSION: u32 = 1; // bump when the format or bake params change

// FNV-1a over the raw height at 64 fixed directions. Any change to the terrain
// formula (noise basis, layer constants, seeds wiring) shifts these bits and
// retires the cached bake automatically.
fn height_fingerprint<F: Fn([f32; 3]) -> f32>(height_at: &F) -> u64 {
    let mut fp: u64 = 0xcbf2_9ce4_8422_2325;
    for i in 0..64u32 {
        let z = -1.0 + 2.0 * ((i as f32 + 0.5) / 64.0);
        let a = (i as f32 * 0.618_034).fract() * std::f32::consts::TAU;
        let s = (1.0 - z * z).max(0.0).sqrt();
        let v = height_at([s * a.cos(), z, s * a.sin()]);
        fp ^= v.to_bits() as u64;
        fp = fp.wrapping_mul(0x0000_0100_0000_01b3);
    }
    fp
}

fn disk_path(seed: i32, radius: f32) -> Option<PathBuf> {
    CACHE_DIR
        .get()
        .map(|d| d.join(format!("erosion_{}_{:08x}_v{}.bin", seed, radius.to_bits(), DISK_VERSION)))
}

fn read_u32(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(b[off..off + 4].try_into().unwrap())
}

fn read_grid(b: &[u8], off: usize, n: usize) -> Vec<f32> {
    b[off..off + n * 4]
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
        .collect()
}

// Layout (little-endian): magic u32 | version u32 | fingerprint u64 | w u32 |
// h u32 | max_rise f32 | max_drop f32 | delta [w*h f32] | flow | height.
fn load_from_disk(path: &PathBuf, fp: u64, radius: f32) -> Option<ErosionField> {
    let b = std::fs::read(path).ok()?;
    if b.len() < 32 || read_u32(&b, 0) != DISK_MAGIC || read_u32(&b, 4) != DISK_VERSION {
        return None;
    }
    if u64::from_le_bytes(b[8..16].try_into().unwrap()) != fp {
        return None; // terrain formula changed since this bake
    }
    let w = read_u32(&b, 16) as usize;
    let h = read_u32(&b, 20) as usize;
    if (w, h) != ero_dims(radius) {
        return None; // grid sizing rules changed
    }
    let n = w * h;
    if b.len() != 32 + 3 * n * 4 {
        return None; // truncated / corrupt
    }
    Some(ErosionField {
        w,
        h,
        delta: read_grid(&b, 32, n),
        flow: read_grid(&b, 32 + n * 4, n),
        height: read_grid(&b, 32 + 2 * n * 4, n),
        max_rise: f32::from_le_bytes(b[24..28].try_into().unwrap()),
        max_drop: f32::from_le_bytes(b[28..32].try_into().unwrap()),
    })
}

// Best-effort save (a failure just means re-baking next launch). Atomic via
// temp-file + rename so a crash mid-write can't leave a truncated cache.
fn save_to_disk(path: &PathBuf, f: &ErosionField, fp: u64) {
    let n = f.w * f.h;
    let mut b: Vec<u8> = Vec::with_capacity(32 + 3 * n * 4);
    b.extend_from_slice(&DISK_MAGIC.to_le_bytes());
    b.extend_from_slice(&DISK_VERSION.to_le_bytes());
    b.extend_from_slice(&fp.to_le_bytes());
    b.extend_from_slice(&(f.w as u32).to_le_bytes());
    b.extend_from_slice(&(f.h as u32).to_le_bytes());
    b.extend_from_slice(&f.max_rise.to_le_bytes());
    b.extend_from_slice(&f.max_drop.to_le_bytes());
    for grid in [&f.delta, &f.flow, &f.height] {
        for v in grid.iter() {
            b.extend_from_slice(&v.to_le_bytes());
        }
    }
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = path.with_extension("tmp");
    if std::fs::write(&tmp, &b).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}

/// Shared erosion field for this body, loaded from the disk cache when a valid
/// bake exists, baked (then saved) otherwise. `height_at` maps a unit direction
/// to the RAW (un-eroded) terrain height in metres — the density's
/// `base_height_raw`. Must not itself read the erosion field (no recursion).
pub fn get_or_build<F: Fn([f32; 3]) -> f32 + Sync>(
    seed: i32,
    radius: f32,
    height_at: &F,
) -> Arc<ErosionField> {
    let key: Key = (seed, radius.to_bits());
    let mut c = cache().lock().unwrap();
    if let Some(f) = c.get(&key) {
        return f.clone();
    }
    let fp = height_fingerprint(height_at);
    let path = disk_path(seed, radius);
    if let Some(p) = &path {
        if let Some(loaded) = load_from_disk(p, fp, radius) {
            let f = Arc::new(loaded);
            c.insert(key, f.clone());
            return f;
        }
    }
    let built = Arc::new(ErosionField::bake(seed, radius, height_at));
    if let Some(p) = &path {
        save_to_disk(p, &built, fp);
    }
    c.insert(key, built.clone());
    built
}

#[inline]
fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

// Deterministic xorshift PRNG so the bake is identical across runs / chunk jobs.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u32 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        (x >> 32) as u32
    }
    fn f01(&mut self) -> f32 {
        self.next() as f32 / u32::MAX as f32
    }
}

impl ErosionField {
    fn bake<F: Fn([f32; 3]) -> f32 + Sync>(seed: i32, radius: f32, height_at: &F) -> ErosionField {
        let (w, h) = ero_dims(radius);

        // 1. Sample the raw heightfield over the sphere (equirect). This is the
        //    dominant cost (every cell is a full fractal probe), so fan it across
        //    the worker cores with scoped threads — each thread fills a disjoint
        //    band of rows, no locking. Falls back to one band if parallelism is
        //    unavailable.
        let mut raw = vec![0.0f32; w * h];
        let threads = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1)
            .clamp(1, 16);
        let rows_per = h.div_ceil(threads);
        std::thread::scope(|s| {
            for (band, chunk) in raw.chunks_mut(rows_per * w).enumerate() {
                let y0 = band * rows_per;
                s.spawn(move || {
                    for (local, cell) in chunk.iter_mut().enumerate() {
                        let iy = y0 + local / w;
                        let ix = local % w;
                        let lat = ((iy as f32 + 0.5) / h as f32 - 0.5) * std::f32::consts::PI;
                        let lon = (ix as f32 / w as f32) * std::f32::consts::TAU;
                        let (clat, slat) = (lat.cos(), lat.sin());
                        *cell = height_at([clat * lon.cos(), slat, clat * lon.sin()]);
                    }
                });
            }
        });

        // 2. Thermal weathering — relax slopes steeper than the talus angle. The
        //    stable height step between horizontally-adjacent cells is the cell's
        //    arc width × tan(talus). (Latitude rows shrink toward the poles; we use
        //    the equatorial width as a single conservative threshold.) Run as a
        //    parallel GATHER (each cell's new height computed from the read-only
        //    previous sweep), ping-ponging two buffers — no per-sweep allocation and
        //    no scatter races, identical numerics to the old scatter formulation.
        let cell_w = std::f32::consts::TAU * radius / w as f32;
        let talus_step = cell_w * TALUS_TAN;
        let mut a = raw.clone();
        let mut b = vec![0.0f32; w * h];
        for _ in 0..THERMAL_ITERS {
            thermal_gather(&a, &mut b, w, h, talus_step);
            std::mem::swap(&mut a, &mut b);
        }
        let post_thermal = a;

        // 3. Hydraulic erosion — droplets flow downhill, carving channels into the
        //    relaxed field and depositing on the flats. Run in parallel realizations
        //    (see run_droplets) and summed.
        let droplets = (DROPLET_DENSITY * (w * h) as f32) as usize;
        let (hgt, mut flow) = run_droplets(&post_thermal, w, h, droplets, seed, radius);

        // 4. Normalise the flow (drainage accumulation) to 0..1, then build the delta
        //    the density adds on top of raw — INCLUDING a channel incision along the
        //    drainage network so rivers read as carved valleys.
        let fmax = flow.iter().copied().fold(0.0f32, f32::max).max(1e-6);
        for f in flow.iter_mut() {
            *f = (*f / fmax).clamp(0.0, 1.0);
        }
        let mut delta = vec![0.0f32; w * h];
        let mut max_rise = 0.0f32;
        let mut max_drop = 0.0f32;
        let inc_span = (RIVER_INCISION_HI - RIVER_INCISION_LO).max(1e-4);
        for i in 0..w * h {
            let mut d = (hgt[i] - raw[i]) * EROSION_STRENGTH;
            // Cut a channel proportional to how much water drains through here.
            let t = ((flow[i] - RIVER_INCISION_LO) / inc_span).clamp(0.0, 1.0);
            d -= RIVER_INCISION * (t * t * (3.0 - 2.0 * t));
            delta[i] = d;
            max_rise = max_rise.max(d);
            max_drop = max_drop.max(-d);
        }

        ErosionField {
            w,
            h,
            delta,
            flow,
            height: hgt,
            max_rise,
            max_drop,
        }
    }

    /// Raw grids for GPU consumption: (w, h, flow 0..1, delta metres).
    /// Empty (w = h = 0) on the no-erosion field.
    pub fn maps(&self) -> (usize, usize, &[f32], &[f32]) {
        (self.w, self.h, &self.flow, &self.delta)
    }

    /// Largest deposition rise the field adds (metres, ≥ 0).
    pub fn max_rise(&self) -> f32 {
        self.max_rise
    }

    /// Largest erosion drop the field cuts (metres, ≥ 0).
    pub fn max_drop(&self) -> f32 {
        self.max_drop
    }

    /// Height delta (metres) to add to the raw terrain height at a unit direction.
    pub fn delta(&self, nx: f32, ny: f32, nz: f32) -> f32 {
        if self.delta.is_empty() {
            return 0.0;
        }
        self.bilerp(&self.delta, nx, ny, nz)
    }

    /// Trace river courses down the eroded channels. Starting from the highest-flow
    /// highland cells (well-spaced so they don't bunch up), each river follows the
    /// surface steepest-descent cell-to-cell until it reaches the sea or runs into a
    /// basin. Returns, per river, a polyline of unit DIRECTIONS plus a 0..1 width
    /// factor per point (from flow, so rivers widen downstream). The caller turns
    /// each direction into a floor point at the EXACT terrain surface (sampling the
    /// full-resolution density), so the water sits on the real mesh rather than this
    /// coarse grid's smoothed height. `sea_disp` is the sea surface as a height
    /// displacement (sea_radius − radius). Empty on the no-erosion field.
    ///
    /// Output: (dirs, lengths, widths) — dirs/widths concatenated across rivers,
    /// `lengths[i]` points in river i. The caller slices by `lengths`.
    pub fn river_courses(&self, sea_disp: f32) -> (Vec<[f32; 3]>, Vec<u32>, Vec<f32>, Vec<Lake>) {
        let mut dirs: Vec<[f32; 3]> = Vec::new();
        let mut lengths: Vec<u32> = Vec::new();
        let mut widths: Vec<f32> = Vec::new();
        let mut lakes: Vec<Lake> = Vec::new();
        if self.height.is_empty() {
            return (dirs, lengths, widths, lakes);
        }
        let w = self.w;
        let h = self.h;

        // Rank candidate sources: highland cells (clear of the sea) carrying flow.
        let mut cand: Vec<(f32, usize, usize)> = Vec::new();
        for y in 2..h - 2 {
            for x in 0..w {
                let i = y * w + x;
                if self.height[i] > sea_disp + 100.0 && self.flow[i] > RIVER_SOURCE_FLOW {
                    cand.push((self.flow[i], x, y));
                }
            }
        }
        cand.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));

        let mut used: Vec<(usize, usize)> = Vec::new();
        for (_, sx, sy) in cand {
            if lengths.len() >= MAX_RIVERS {
                break;
            }
            // Space sources out (toroidal in x) so rivers don't all share a headwater.
            if used.iter().any(|&(ux, uy)| {
                let dx = ((sx as i32 - ux as i32).abs()).min(w as i32 - (sx as i32 - ux as i32).abs());
                let dy = (sy as i32 - uy as i32).abs();
                dx < RIVER_SRC_SPACING as i32 && dy < RIVER_SRC_SPACING as i32
            }) {
                continue;
            }

            // Trace steepest descent from this cell.
            let mut fx = sx as f32 + 0.5;
            let mut fy = sy as f32 + 0.5;
            let mut river: Vec<[f32; 3]> = Vec::new();
            let mut wfac: Vec<f32> = Vec::new();
            // (fx, fy, floor height, arriving flow) if the river stalled in a basin.
            let mut stalled: Option<(f32, f32, f32, f32)> = None;
            for _ in 0..RIVER_TRACE_STEPS {
                let (hh, gx, gy) = sample_grid(&self.height, w, h, fx, fy);
                if hh <= sea_disp {
                    break; // reached the ocean
                }
                river.push(dir_from_grid(fx, fy, w, h));
                let fl = sample_grid(&self.flow, w, h, fx, fy).0;
                wfac.push(fl.clamp(0.0, 1.0));
                // Steepest descent = move against the gradient.
                let glen = (gx * gx + gy * gy).sqrt();
                if glen < 1e-4 {
                    stalled = Some((fx, fy, hh, fl)); // basin / flat — water pools → lake
                    break;
                }
                fx += -gx / glen;
                fy += -gy / glen;
                fx = fx.rem_euclid(w as f32);
                if fy < 1.0 || fy > (h - 2) as f32 {
                    break;
                }
            }
            if river.len() >= 4 {
                used.push((sx, sy));
                lengths.push(river.len() as u32);
                dirs.extend_from_slice(&river);
                widths.extend_from_slice(&wfac);
                // Pool a lake where the river died inland, sized by the flow that got
                // there. Skip lakes that overlap one already placed.
                if let Some((lx, ly, lh, lflow)) = stalled {
                    if lh > sea_disp + LAKE_MIN_ALT {
                        let dir = dir_from_grid(lx, ly, w, h);
                        let radius = LAKE_MIN_RADIUS
                            + (LAKE_MAX_RADIUS - LAKE_MIN_RADIUS) * lflow.clamp(0.0, 1.0);
                        let near = lakes.iter().any(|l| {
                            let d = dir[0] * l.dir[0] + dir[1] * l.dir[1] + dir[2] * l.dir[2];
                            d > 0.9999
                        });
                        if !near {
                            lakes.push(Lake {
                                dir,
                                water_disp: lh + LAKE_RISE,
                                radius,
                            });
                        }
                    }
                }
            }
        }
        (dirs, lengths, widths, lakes)
    }

    // Bilinear sample of a grid at a unit direction (lon wraps, lat clamps).
    fn bilerp(&self, grid: &[f32], nx: f32, ny: f32, nz: f32) -> f32 {
        let lat = ny.clamp(-1.0, 1.0).asin();
        let mut lon = nz.atan2(nx);
        if lon < 0.0 {
            lon += std::f32::consts::TAU;
        }
        let fx = lon / std::f32::consts::TAU * self.w as f32;
        let fy = (lat / std::f32::consts::PI + 0.5) * self.h as f32 - 0.5;
        sample_grid(grid, self.w, self.h, fx, fy).0
    }
}

// ── grid helpers ─────────────────────────────────────────────────────────────

// Fractional grid cell (fx, fy) → unit direction in object space (inverse of the
// equirect mapping used to bake the field).
fn dir_from_grid(fx: f32, fy: f32, w: usize, h: usize) -> [f32; 3] {
    let lon = fx / w as f32 * std::f32::consts::TAU;
    let lat = ((fy + 0.5) / h as f32 - 0.5) * std::f32::consts::PI;
    let (clat, slat) = (lat.cos(), lat.sin());
    [clat * lon.cos(), slat, clat * lon.sin()]
}

#[inline]
fn wrap_x(x: i32, w: usize) -> usize {
    (((x % w as i32) + w as i32) % w as i32) as usize
}

#[inline]
fn clamp_y(y: i32, h: usize) -> usize {
    y.clamp(0, h as i32 - 1) as usize
}

// Bilinear height + gradient (d/dx, d/dy in cell units) at fractional (fx, fy).
fn sample_grid(grid: &[f32], w: usize, h: usize, fx: f32, fy: f32) -> (f32, f32, f32) {
    let x0 = fx.floor() as i32;
    let y0 = fy.floor() as i32;
    let tx = fx - x0 as f32;
    let ty = fy - y0 as f32;
    let i = |x: i32, y: i32| -> f32 { grid[clamp_y(y, h) * w + wrap_x(x, w)] };
    let h00 = i(x0, y0);
    let h10 = i(x0 + 1, y0);
    let h01 = i(x0, y0 + 1);
    let h11 = i(x0 + 1, y0 + 1);
    let height = lerp(lerp(h00, h10, tx), lerp(h01, h11, tx), ty);
    let gx = lerp(h10 - h00, h11 - h01, ty);
    let gy = lerp(h01 - h00, h11 - h10, tx);
    (height, gx, gy)
}

// Add `amt` to a grid, distributed bilinearly across the 4 cells around (fx, fy).
fn add_bilerp(grid: &mut [f32], w: usize, h: usize, fx: f32, fy: f32, amt: f32) {
    let x0 = fx.floor() as i32;
    let y0 = fy.floor() as i32;
    let tx = fx - x0 as f32;
    let ty = fy - y0 as f32;
    grid[clamp_y(y0, h) * w + wrap_x(x0, w)] += amt * (1.0 - tx) * (1.0 - ty);
    grid[clamp_y(y0, h) * w + wrap_x(x0 + 1, w)] += amt * tx * (1.0 - ty);
    grid[clamp_y(y0 + 1, h) * w + wrap_x(x0, w)] += amt * (1.0 - tx) * ty;
    grid[clamp_y(y0 + 1, h) * w + wrap_x(x0 + 1, w)] += amt * tx * ty;
}

// One thermal-weathering sweep, GATHER form: `dst[c]` is computed purely from the
// read-only `src`, so the sweep parallelises over row bands with no scatter races. A
// cell sheds a quarter of its over-talus excess to every LOWER 4-neighbour and
// receives a quarter of each HIGHER neighbour's excess — algebraically identical to
// the old scatter sweep (each pair moves once), but allocation-free (the caller
// ping-pongs two buffers) and multi-threaded.
fn thermal_gather(src: &[f32], dst: &mut [f32], w: usize, h: usize, talus_step: f32) {
    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
        .clamp(1, 16);
    let rows_per = h.div_ceil(threads);
    std::thread::scope(|s| {
        for (band, chunk) in dst.chunks_mut(rows_per * w).enumerate() {
            let y0 = band * rows_per;
            s.spawn(move || {
                for (local, cell) in chunk.iter_mut().enumerate() {
                    let y = y0 + local / w;
                    let x = local % w;
                    let c = src[y * w + x];
                    let nb = [
                        src[y * w + wrap_x(x as i32 - 1, w)],
                        src[y * w + wrap_x(x as i32 + 1, w)],
                        src[clamp_y(y as i32 - 1, h) * w + x],
                        src[clamp_y(y as i32 + 1, h) * w + x],
                    ];
                    let mut delta = 0.0f32;
                    for &n in &nb {
                        let out = c - n;
                        if out > talus_step {
                            delta -= (out - talus_step) * 0.25; // shed to a lower neighbour
                        }
                        let inc = n - c;
                        if inc > talus_step {
                            delta += (inc - talus_step) * 0.25; // receive from a higher neighbour
                        }
                    }
                    *cell = c + delta;
                }
            });
        }
    });
}

// The hydraulic pass: EROSION_REALIZATIONS independent droplet simulations, each on a
// private clone of the post-thermal field with its own deterministic RNG, run in
// parallel and then summed (height deltas + flow). The fixed realization count keeps
// the bake bit-identical on every machine; splitting the droplets across them is the
// speed-up. Cross-realization channel reinforcement is lost vs. one serial pass, but
// the explicit flow-driven incision (step 4 of bake) supplies the channel depth and
// the summed flow captures the full drainage network.
fn run_droplets(
    base: &[f32], w: usize, h: usize, droplets: usize, seed: i32, radius: f32,
) -> (Vec<f32>, Vec<f32>) {
    let per = droplets.div_ceil(EROSION_REALIZATIONS);
    let mut results: Vec<(Vec<f32>, Vec<f32>)> = Vec::with_capacity(EROSION_REALIZATIONS);
    std::thread::scope(|s| {
        let mut handles = Vec::with_capacity(EROSION_REALIZATIONS);
        for rzn in 0..EROSION_REALIZATIONS {
            handles.push(s.spawn(move || {
                let mut hgt = base.to_vec();
                let mut flow = vec![0.0f32; w * h];
                let mut rng = Rng(
                    ((seed as u64) << 1)
                        ^ 0x9E3779B97F4A7C15
                        ^ radius.to_bits() as u64
                        ^ (rzn as u64).wrapping_mul(0xD1B54A32D192ED03),
                );
                for _ in 0..per {
                    simulate_droplet(&mut hgt, &mut flow, w, h, &mut rng);
                }
                for i in 0..w * h {
                    hgt[i] -= base[i]; // height → delta vs the shared base
                }
                (hgt, flow)
            }));
        }
        for handle in handles {
            results.push(handle.join().unwrap());
        }
    });
    let mut hgt = base.to_vec();
    let mut flow = vec![0.0f32; w * h];
    for (d, f) in &results {
        for i in 0..w * h {
            hgt[i] += d[i];
            flow[i] += f[i];
        }
    }
    (hgt, flow)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Disk round-trip must reproduce the field exactly (bit-identical grids), and
    // a fingerprint mismatch (terrain formula changed) must reject the file.
    #[test]
    fn disk_cache_round_trip() {
        let radius = 256.0 * ERO_TARGET_CELL_M / std::f32::consts::TAU; // → minimum grid
        let (w, h) = ero_dims(radius);
        let n = w * h;
        let field = ErosionField {
            w,
            h,
            delta: (0..n).map(|i| (i as f32).sin()).collect(),
            flow: (0..n).map(|i| (i as f32 * 0.7).cos().abs()).collect(),
            height: (0..n).map(|i| i as f32 * 0.001 - 3.0).collect(),
            max_rise: 12.5,
            max_drop: 33.25,
        };
        let dir = std::env::temp_dir().join("transvoxel_ero_test");
        let path = dir.join("round_trip.bin");
        save_to_disk(&path, &field, 0xDEAD_BEEF);

        let loaded = load_from_disk(&path, 0xDEAD_BEEF, radius).expect("load failed");
        assert_eq!(loaded.w, field.w);
        assert_eq!(loaded.h, field.h);
        assert_eq!(loaded.delta, field.delta);
        assert_eq!(loaded.flow, field.flow);
        assert_eq!(loaded.height, field.height);
        assert_eq!(loaded.max_rise, field.max_rise);
        assert_eq!(loaded.max_drop, field.max_drop);

        // Wrong fingerprint (terrain code changed) → cache must be rejected.
        assert!(load_from_disk(&path, 0x1234, radius).is_none());
        let _ = std::fs::remove_file(&path);
    }
}

// Trace one water droplet down the field, eroding/depositing as it goes and
// accumulating its path into `flow`. Standard inertial droplet model.
fn simulate_droplet(hgt: &mut [f32], flow: &mut [f32], w: usize, h: usize, rng: &mut Rng) {
    let mut px = rng.f01() * w as f32;
    // Keep the start a row off each pole so the droplet has somewhere to flow.
    let mut py = 1.0 + rng.f01() * (h as f32 - 3.0);
    let mut dx = 0.0f32;
    let mut dy = 0.0f32;
    let mut speed = 1.0f32;
    let mut water = 1.0f32;
    let mut sediment = 0.0f32;

    for _ in 0..MAX_LIFETIME {
        let (old_h, gx, gy) = sample_grid(hgt, w, h, px, py);
        // Blend the previous heading with the downhill gradient.
        dx = dx * INERTIA - gx * (1.0 - INERTIA);
        dy = dy * INERTIA - gy * (1.0 - INERTIA);
        let len = (dx * dx + dy * dy).sqrt();
        if len < 1e-4 {
            break; // pit / flat — stop (any carried sediment just stays)
        }
        dx /= len;
        dy /= len;

        let drop_x = px;
        let drop_y = py;
        px += dx;
        py += dy;
        px = px.rem_euclid(w as f32); // longitude wraps
        if py < 1.0 || py > (h - 2) as f32 {
            break; // ran off a pole
        }

        let (new_h, _, _) = sample_grid(hgt, w, h, px, py);
        let dh = new_h - old_h;

        flow[clamp_y(drop_y as i32, h) * w + wrap_x(drop_x as i32, w)] += water;

        // Carrying capacity scales with downhill steepness, speed and water.
        let capacity = (-dh).max(MIN_SLOPE) * speed * water * SEDIMENT_CAP;

        if sediment > capacity || dh > 0.0 {
            // Too much load (or running uphill) → deposit.
            let deposit = if dh > 0.0 {
                dh.min(sediment) // fill the rise it just climbed
            } else {
                (sediment - capacity) * DEPOSIT_RATE
            };
            sediment -= deposit;
            add_bilerp(hgt, w, h, drop_x, drop_y, deposit);
        } else {
            // Capacity to spare → erode (never cut more than the drop's own step).
            let erode = ((capacity - sediment) * ERODE_RATE).min(-dh);
            sediment += erode;
            add_bilerp(hgt, w, h, drop_x, drop_y, -erode);
        }

        // Downhill (dh < 0) accelerates; uphill decelerates. Then water evaporates.
        speed = (speed * speed - dh * GRAVITY).max(0.0).sqrt();
        water *= 1.0 - EVAPORATE;
        if water < 0.01 {
            break;
        }
    }
}
