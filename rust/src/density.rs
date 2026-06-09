//! Port of `scripts/planet/density.gd`'s composition, on top of our own
//! hand-rolled noise (`crate::noise`) — no external noise crate. The layer
//! structure (continents, ridges, hills, spires, plateaus, canyons, caves) and
//! the height budget are the same; only the underlying noise basis differs, so
//! the planet's look will need re-tuning.

use crate::erosion::{self, ErosionField};
use crate::noise::{Fractal, Noise};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

// Earth-scale dramatic peaks: 900 m mountains read as a real range on the
// horizon from the ground, and from orbit you can see ridges silhouette
// against the sky. The previous 170 m budget was nearly flat. Continent +
// canyon amplitudes follow so ocean basins are deep and continents have
// genuine elevation variation, not just a thin crust of bumps.
// Relief budget. Mountains are taller and valleys deeper than the old 900/320 m so the
// ranges read as genuinely alpine — combined with the ridged-MULTIFRACTAL ridge layer
// (sharp connected crests) the silhouette is dramatic from the ground and from orbit.
// Peak rise is kept moderate (1150) so the tallest summits brush — rather than blow
// through — the cloud deck; most of the added drama comes from deeper canyons (480)
// and sharper spires, which cost no cloud clearance.
const MAX_TERRAIN_HEIGHT: f32 = 1150.0;
// 320 (was 600): full-height spires were 600 m near-cones ((1−|n|)³ is a sharp
// peak) that the biome shader painted GRASS below the snow line — the
// "unrealistically sharp huge grass hills". Real ranges come from the ridged
// multifractal layer; spires are now a moderate accent, and rarer (mask below).
const MAX_SPIRE_HEIGHT: f32 = 320.0;
const MAX_PLATEAU_RISE: f32 = 280.0;
const MAX_CANYON_DEPTH: f32 = 480.0;
const CAVE_BOTTOM_DEPTH: f32 = 420.0;

// ── Settlements ─────────────────────────────────────────────────────────────
// Deterministic placeholder cities and the roads between them, carved into the
// density itself so the terrain is genuinely FLAT where a town sits (and graded
// along a road corridor) rather than props floating on bumpy ground. Only large
// bodies get them — the moon (radius ~3300) is excluded by SETTLEMENT_MIN_RADIUS.
const SETTLEMENT_MIN_RADIUS: f32 = 10000.0;
// Towns are placed in CLUSTERS (regional hubs), not scattered planet-wide. On a
// ~70%-ocean world, evenly-spread towns each end up alone on their own islet, so
// no two share a landmass and a land-only road network can't form. Clustering a
// handful of towns onto each of several continents instead gives Rust-style
// settlement webs — multiple towns wired together by roads that never touch water.
const SETTLEMENT_REGIONS: usize = 7;    // continents/regions that get a town cluster
const CITIES_PER_REGION: usize = 5;     // towns per region → up to 35 total
const REGION_SEP_COS: f32 = 0.55;       // region centres ≥ ~57° apart (well separated)
const REGION_RADIUS_COS: f32 = 0.990;   // towns sit within ~8° of their region centre
const REGION_JITTER: f32 = 0.11;        // angular spread of towns around the centre
const CITY_MIN_SEP_COS: f32 = 0.9990;   // towns ≥ ~2.6° apart (pads never overlap)
const CITY_PAD_RADIUS: f32 = 280.0;     // flat disc radius (world units) — bigger cities
const CITY_BLEND: f32 = 560.0;          // graded skirt — long + gentle so the rim eases into
                                        // terrain instead of a sudden step where highways enter.
                                        // 560 (was 380): with up to CITY_MAX_RELIEF of height
                                        // mismatch at the rim, 380 m gave ~20° walls that read
                                        // as cliffs around the city; the longer skirt halves that.
// How strongly the pad flattens the ground beneath it: 1 = dead-flat disc, 0 = pure
// terrain. Mostly flat (buildable, so streets/buildings sit cleanly and roads meet
// the pad without a jump) but not 100%, so the town still reads as settled into the
// land rather than a stamped circle. (0.62 was too loose — the undulation broke the
// in-town roads and made the highway-edge transition jump.)
// Pushed to near-flat (was 0.82): a partially-flattened pad UNDULATES, and the
// city's pavement/streets/buildings are draped on a coarse analytic height grid that
// can't track that undulation — so they floated over the dips / poked through the
// rises. A near-flat pad (cities ARE flat) makes the draped ground match the mesh, so
// small lifts sit the foundation flush. The relief-gated siting keeps the rim gentle.
const CITY_FLATTEN: f32 = 0.95;
// Smaller settlements seeded ALONG the roads between cities, so the world reads as a
// network of connected places of varying size (the Rust-on-a-planet feel) rather
// than a few big cities in the void. Each gets a smaller flat pad.
const TOWN_PAD_RADIUS: f32 = 110.0;   // ~half a city
const TOWNS_PER_ROAD: usize = 3;      // dropped at evenly-spaced points along each road
const TOWN_MIN_SEP_COS: f32 = 0.99975; // keep towns from piling onto each other / onto cities
const ROADS_PER_CITY: usize = 4;        // connect each town to its nearest land neighbours
const CITY_MAX_HEIGHT: f32 = MAX_TERRAIN_HEIGHT * 0.5;  // keep towns off extreme peaks
// Max terrain relief (height spread) allowed over a pad footprint when siting a
// settlement. Placing towns/cities only on relatively FLAT ground means the pad
// flatten barely changes the terrain, so the rim eases in instead of stepping —
// the elegant fix for the "flattening problematic at the edges" artifact.
const CITY_MAX_RELIEF: f32 = 140.0;   // a touch looser so the bigger pads still find sites
const TOWN_MAX_RELIEF: f32 = 80.0;
// Sea sits at radius + sea_level_offset; this mirrors the project's -200 m
// (world.gd / planet sea_level_offset). Most of the planet is ocean and land
// rarely tops a few tens of metres, so towns are sited a modest margin above
// the waterline rather than on the scarce high ground.
const ASSUMED_SEA_OFFSET: f32 = -200.0;
// Low, so cities settle on the COAST (real cities grow at the waterline). Coastal
// siting is reinforced by ranking each region's candidates by altitude — see
// build_settlements — so towns cluster on lowland shores, not the scarce high ground.
const CITY_MIN_ABOVE_SEA: f32 = 25.0;
// Flat road corridor half-width. Must be several voxels wide at the road chunks'
// LOD or the marching-cubes mesh can't resolve a flat floor and the terrain bulges
// up into the (narrow) visual ribbon — the "terrain showing through" artefact. 40
// gives an 80 m flat bed, comfortably wider than the 16 m-wide ribbon.
const ROAD_HALF_WIDTH: f32 = 40.0;
const ROAD_BLEND: f32 = 80.0;           // graded verge outside the corridor
// Steepest grade the road is allowed to hold (rise/run). The profile is slope-
// limited to this so highways stay drivable instead of pitching up unusable
// ramps; where the limit forces it, the road cuts deeper / fills higher to keep
// the grade. ~0.11 ≈ 6.3°.
const MAX_ROAD_SLOPE: f32 = 0.11;
// Roads are CUT into the ground: the carved bed sits this far below the local
// terrain along a SMOOTHED grade (see Road::prof). Combined with the cross-section
// flattening, the road cuts DOWN through high spots and fills UP across dips to
// hold a gentle grade — it carves the terrain instead of riding steeply over every
// bump. The bed sits this far below the grade for a road-cut read; the visual
// ribbon drops by the same amount so it sits in the cut, not floating over it.
const ROAD_CUT_DEPTH: f32 = 6.0;
// Road grade profile: heights sampled along each road then MODERATELY smoothed so
// the centreline HUGS the large-scale terrain (rises and falls with it) while small
// humps are planed off — the road carves through those and the cross-section
// flattening (ROAD_HALF_WIDTH) cuts a flat shelf into the slope. Heavy smoothing was
// the bug: it straightened the grade into long floating fills/cuts that neither hug
// nor read as carved. Endpoints are anchored to the city pad heights.
const ROAD_PROFILE_SAMPLES: usize = 64;
const ROAD_SMOOTH_ITERS: usize = 10;
// Length (world units) of the eased ramp from the flat pad down onto the terrain
// grade beyond it, so the road leaves town gently instead of stepping off a cliff.
// 1100 (was 650): the shorter ramp still pitched the highway onto the terrain
// almost immediately past the rim — the "drops or climbs right out of the city"
// read. The longer ramp holds the pad grade further out and eases down over ~1 km.
const ROAD_PAD_BLEND: f32 = 1100.0;

pub struct City {
    pub dir: [f32; 3],   // unit direction in the planet's LOCAL frame
    pub target_r: f32,   // flattened pad radius from the planet centre
    pub pad_radius: f32, // flat-disc radius (CITY_PAD_RADIUS for cities, smaller for towns)
}

pub struct Road {
    a: [f32; 3],
    b: [f32; 3],
    n: [f32; 3],   // unit normal of the great-circle plane through a & b
    ab_cos: f32,   // dot(a, b) — cosine of the arc's subtended angle
    arc: f32,      // acos(ab_cos) — subtended angle, precomputed (used per in-corridor sample)
    // Smoothed grade: target surface radii at ROAD_PROFILE_SAMPLES+1 points evenly
    // along the arc (t = 0 at a, 1 at b). Endpoints anchored to the city pad heights.
    // The corridor flattens to this (minus the cut), so the road holds a gentle grade.
    prof: Vec<f32>,
}

/// The full settlement graph for one (seed, radius) body. Built ONCE and shared
/// (behind an `Arc`) by every `PlanetDensity` for that body — see SETTLEMENT_CACHE.
pub struct Settlements {
    cities: Vec<City>,
    roads: Vec<Road>,
    // Region (continent-cluster) centres on land — one per populated landmass.
    // Surfaced to GDScript so it can place a distinct landmark per region.
    regions: Vec<[f32; 3]>,
    city_cos_cutoff: f32,   // cheap reject: dot(dir, city.dir) below this → out of range
    road_off_cutoff: f32,   // cheap reject: |dot(dir, road.n)| above this → off the corridor
}

// `PlanetDensity::new()` runs PER CHUNK JOB on the worker pool, so settlement
// generation (hundreds of noise probes + an O(N²) road pass) must NOT re-run for
// every chunk. Build it once per (seed, radius) and hand out cheap `Arc` clones.
// Keyed by (seed, radius.to_bits()) so distinct bodies (planet vs moon, or a
// re-tuned radius) each get their own graph.
type SettlementKey = (i32, u32);
static SETTLEMENT_CACHE: OnceLock<Mutex<HashMap<SettlementKey, Arc<Settlements>>>> =
    OnceLock::new();

// Process-wide cache of fully-built `PlanetDensity` objects, keyed like the
// settlement cache. Construction is cheap once erosion/settlements are baked,
// but it still builds 11 noise fields and takes two global cache locks — and it
// ran once per chunk job on the worker pool AND once per GDScript FFI query
// (player altitude every frame). Build once per body, hand out Arc clones.
static DENSITY_CACHE: OnceLock<Mutex<HashMap<SettlementKey, Arc<PlanetDensity>>>> =
    OnceLock::new();

/// Shared, build-once density for a body. The lock is held across the first
/// build on purpose: concurrent workers block here instead of redundantly
/// re-baking erosion/settlements (those inner caches serialize anyway).
pub fn shared(seed: i32, radius: f32) -> Arc<PlanetDensity> {
    let key: SettlementKey = (seed, radius.to_bits());
    let cache = DENSITY_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut map = cache.lock().unwrap();
    if let Some(d) = map.get(&key) {
        return d.clone();
    }
    let built = Arc::new(PlanetDensity::new(seed, radius));
    map.insert(key, built.clone());
    built
}

fn settlement_cache() -> &'static Mutex<HashMap<SettlementKey, Arc<Settlements>>> {
    SETTLEMENT_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn empty_settlements() -> Arc<Settlements> {
    static EMPTY: OnceLock<Arc<Settlements>> = OnceLock::new();
    EMPTY
        .get_or_init(|| {
            Arc::new(Settlements {
                cities: Vec::new(),
                roads: Vec::new(),
                regions: Vec::new(),
                city_cos_cutoff: 1.0,
                road_off_cutoff: 0.0,
            })
        })
        .clone()
}

/// Return the shared settlement graph for this body, building it on the first
/// call (cache miss) and handing out cheap `Arc` clones thereafter. `probe` is a
/// freshly-built `PlanetDensity` whose noise fields are ready but whose own
/// `settlements` is still the empty placeholder — generation only reads its
/// noise via `base_height`/`arc_crosses_sea`, so that's exactly what's needed.
fn get_or_build_settlements(seed: i32, radius: f32, probe: &PlanetDensity) -> Arc<Settlements> {
    let key: SettlementKey = (seed, radius.to_bits());
    let mut cache = settlement_cache().lock().unwrap();
    if let Some(s) = cache.get(&key) {
        return s.clone();
    }
    let built = Arc::new(probe.build_settlements(seed));
    cache.insert(key, built.clone());
    built
}

/// Godot's `smoothstep`, including the reversed-edge case (e0 > e1) used by the
/// cave carve and the settlement skirts (e0 = outer, e1 = inner → 1 inside).
#[inline]
fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn mk(seed: i32, ft: Fractal, freq: f32, octaves: i32, lacunarity: f32, gain: f32) -> Noise {
    Noise::new(seed, freq, octaves, lacunarity, gain, ft)
}

// Cheap integer hash for deterministic settlement placement (no noise lookups).
#[inline]
fn hash_u32(mut x: u32) -> u32 {
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846ca68b);
    x ^= x >> 16;
    x
}

// Deterministic point uniformly on the unit sphere from (seed, index).
fn rand_unit(seed: i32, i: u32) -> [f32; 3] {
    let a = hash_u32((seed as u32).wrapping_add(i.wrapping_mul(0x9E3779B1)));
    let b = hash_u32(a ^ 0x68bc21eb);
    let u = a as f32 / u32::MAX as f32;
    let v = b as f32 / u32::MAX as f32;
    let z = 2.0 * u - 1.0;
    let phi = std::f32::consts::TAU * v;
    let s = (1.0 - z * z).max(0.0).sqrt();
    [s * phi.cos(), z, s * phi.sin()]
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
    // Shared, build-once settlement graph for this body (Arc-cloned from the
    // process-wide cache; empty for bodies below SETTLEMENT_MIN_RADIUS).
    settlements: Arc<Settlements>,
    // Shared, build-once global erosion field (thermal + hydraulic). Its height
    // delta is folded into `base_height`, so every consumer — sample(), settlement
    // siting, road carving — sees the weathered, river-carved surface. Empty for
    // small bodies (the moon stays sharp/cratered).
    erosion: Arc<ErosionField>,
    // Cached min/max_surface_radius() — the radial early-out band in sample_opts.
    min_bound: f32,
    max_bound: f32,
}

impl PlanetDensity {
    pub fn new(seed: i32, radius: f32) -> Self {
        use Fractal::{Fbm, Ridged};
        // Same seeds/frequencies/octaves as density.gd; the GDScript noise-type
        // distinction (Perlin vs SimplexSmooth) collapses onto our single
        // Perlin basis. Layers without a fractal type in GDScript were FBM.
        let mut s = Self {
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
            settlements: empty_settlements(),
            erosion: erosion::empty_field(),
            min_bound: 0.0,
            max_bound: 0.0,
        };
        // Bake erosion FIRST (only large bodies — the moon keeps crisp craters), so
        // settlement siting + road carving below run against the weathered surface.
        // It's built from the RAW height (no recursion) and cached process-wide, so
        // only the first chunk job for this body pays the bake cost.
        if radius >= SETTLEMENT_MIN_RADIUS {
            let probe = &s;
            s.erosion = erosion::get_or_build(seed, radius, &|d| {
                probe.base_height_raw(d[0] * radius, d[1] * radius, d[2] * radius)
            });
            s.settlements = get_or_build_settlements(seed, radius, &s);
        }
        // Cache the strict surface band AFTER erosion is set (the bounds include
        // its max rise/drop) — sample_opts early-outs against these per voxel.
        s.min_bound = s.min_surface_radius();
        s.max_bound = s.max_surface_radius();
        s
    }

    /// Terrain stats over a pad-sized footprint around a unit `dir`: centre + eight
    /// rim samples. Returns (relief = max − min, mean height). Low relief = flat
    /// ground, where a pad flattens with a negligible skirt (smooth edge). The MEAN
    /// is what pads anchor to: anchoring to the centre height perched the whole
    /// town (and every road anchored to it) on whatever local bump the centre
    /// happened to hit, floating above the rest of the footprint.
    fn pad_stats(&self, dir: [f32; 3], pad_r: f32) -> (f32, f32) {
        let ang = pad_r / self.radius;
        let mut t = cross(dir, [0.0, 1.0, 0.0]);
        if dot(t, t) < 1e-6 {
            t = cross(dir, [1.0, 0.0, 0.0]);
        }
        let tl = dot(t, t).sqrt().max(1e-6);
        let t = [t[0] / tl, t[1] / tl, t[2] / tl];
        let b = cross(dir, t);
        let sample = |o: [f32; 3]| -> f32 {
            let d = [dir[0] + o[0] * ang, dir[1] + o[1] * ang, dir[2] + o[2] * ang];
            let l = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt().max(1e-6);
            self.base_height(d[0] / l * self.radius, d[1] / l * self.radius, d[2] / l * self.radius)
        };
        let h0 = self.base_height(dir[0] * self.radius, dir[1] * self.radius, dir[2] * self.radius);
        let mut mn = h0;
        let mut mx = h0;
        let mut sum = h0;
        // 8 rim directions (4 cardinal + 4 diagonal): with only 4 probes a ridge or
        // gully crossing the pad diagonally slipped between them, siting "flat"
        // towns on broken ground — the rim cliffs. √½ for the unit diagonals.
        const D: f32 = std::f32::consts::FRAC_1_SQRT_2;
        for o in [
            t,
            [-t[0], -t[1], -t[2]],
            b,
            [-b[0], -b[1], -b[2]],
            [(t[0] + b[0]) * D, (t[1] + b[1]) * D, (t[2] + b[2]) * D],
            [(t[0] - b[0]) * D, (t[1] - b[1]) * D, (t[2] - b[2]) * D],
            [(-t[0] + b[0]) * D, (-t[1] + b[1]) * D, (-t[2] + b[2]) * D],
            [(-t[0] - b[0]) * D, (-t[1] - b[1]) * D, (-t[2] - b[2]) * D],
        ] {
            let h = sample(o);
            mn = mn.min(h);
            mx = mx.max(h);
            sum += h;
        }
        (mx - mn, sum / 9.0)
    }

    /// Pick deterministic city sites on land and connect each to its nearest
    /// land neighbours with roads. Returns the finished graph; the caller caches
    /// it process-wide (it must NOT run per chunk). Uses the already-built noise
    /// fields (via `&self`) to test land height per candidate.
    fn build_settlements(&self, seed: i32) -> Settlements {
        let min_target = self.radius + ASSUMED_SEA_OFFSET + CITY_MIN_ABOVE_SEA;
        let land_ok = |d: [f32; 3]| -> Option<f32> {
            let h = self.base_height(d[0] * self.radius, d[1] * self.radius, d[2] * self.radius);
            if self.radius + h <= min_target || h > CITY_MAX_HEIGHT {
                None
            } else {
                Some(self.radius + h)
            }
        };

        // 1. Scatter a few well-separated REGION centres on land (one per continent
        //    we want populated).
        let mut regions: Vec<[f32; 3]> = Vec::new();
        let mut ridx = 0u32;
        let mut rtries = 0u32;
        while regions.len() < SETTLEMENT_REGIONS && rtries < 6000 {
            rtries += 1;
            let d = rand_unit(seed ^ 0x0C17, ridx);
            ridx += 1;
            if land_ok(d).is_none() {
                continue;
            }
            if regions.iter().any(|r| dot(d, *r) > REGION_SEP_COS) {
                continue; // keep regions on distinct, separated landmasses
            }
            regions.push(d);
        }

        // 2. Fill each region with a tight cluster of towns. Gather many valid (on land,
        //    flat enough for a pad) candidates jittered around the region centre, then
        //    prefer the LOWEST-altitude ones — so the cluster settles on the coastal
        //    lowlands (where real cities grow) instead of the first random hillside.
        let mut cities: Vec<City> = Vec::new();
        for (k, rc) in regions.iter().enumerate() {
            let region_seed = seed ^ 0x5EED ^ ((k as i32).wrapping_mul(7919));
            let mut cands: Vec<([f32; 3], f32)> = Vec::new();
            let mut cidx = 0u32;
            let mut ctries = 0u32;
            while cands.len() < 80 && ctries < 4000 {
                ctries += 1;
                let j = rand_unit(region_seed, cidx);
                cidx += 1;
                let mut d = [
                    rc[0] + j[0] * REGION_JITTER,
                    rc[1] + j[1] * REGION_JITTER,
                    rc[2] + j[2] * REGION_JITTER,
                ];
                let l = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt().max(1e-6);
                d = [d[0] / l, d[1] / l, d[2] / l];
                if dot(d, *rc) < REGION_RADIUS_COS {
                    continue; // strayed outside the region
                }
                if land_ok(d).is_none() {
                    continue;
                }
                let (relief, mean_h) = self.pad_stats(d, CITY_PAD_RADIUS);
                if relief > CITY_MAX_RELIEF {
                    continue; // too sloped — a pad here would step at the rim
                }
                // Also gate on the SKIRT ring: flat pad ground means nothing if the
                // terrain falls off a shelf just past the rim — the pad would sit on
                // a high table with roads diving off it. Allow somewhat more relief
                // out there (the long blend absorbs it), but reject real drop-offs.
                let (skirt_relief, _) = self.pad_stats(d, CITY_PAD_RADIUS + CITY_BLEND * 0.7);
                if skirt_relief > CITY_MAX_RELIEF * 1.6 {
                    continue;
                }
                // Anchor the pad to the footprint MEAN (settled into the ground),
                // not the centre sample (perched on whatever bump it hit).
                cands.push((d, self.radius + mean_h));
            }
            // Coastal preference: lowest surface radius (closest to the waterline) first.
            cands.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
            let mut placed = 0usize;
            for (d, target_r) in cands {
                if placed >= CITIES_PER_REGION {
                    break;
                }
                if cities.iter().any(|c| dot(d, c.dir) > CITY_MIN_SEP_COS) {
                    continue; // too close to an existing town
                }
                cities.push(City { dir: d, target_r, pad_radius: CITY_PAD_RADIUS });
                placed += 1;
            }
        }

        // Road network: connect each city to its nearest ROADS_PER_CITY land
        // neighbours (Rust-style: monuments wired into a road web, not a single
        // chain). Small N, so an O(N²) nearest pass per city is fine. Edges are
        // deduped (a↔b once) and any arc crossing the ocean is dropped.
        let n = cities.len();
        let mut roads: Vec<Road> = Vec::new();
        let mut pairs: Vec<(usize, usize)> = Vec::new();
        for a in 0..n {
            // Rank neighbours of `a` by angular proximity (highest dot first).
            let mut nbrs: Vec<(f32, usize)> = (0..n)
                .filter(|&b| b != a)
                .map(|b| (dot(cities[a].dir, cities[b].dir), b))
                .collect();
            nbrs.sort_by(|p, q| q.0.partial_cmp(&p.0).unwrap_or(std::cmp::Ordering::Equal));

            let mut made = 0usize;
            for &(_, b) in &nbrs {
                if made >= ROADS_PER_CITY {
                    break;
                }
                let (lo, hi) = (a.min(b), a.max(b));
                if pairs.contains(&(lo, hi)) {
                    made += 1; // already linked (e.g. from b's pass) — counts toward degree
                    continue;
                }
                let da = cities[lo].dir;
                let db = cities[hi].dir;
                // Skip roads whose arc crosses the ocean — otherwise the flattened
                // corridor becomes a causeway over water. Keeps roads intra-continent.
                if self.arc_crosses_sea(da, db) {
                    continue;
                }
                let mut nrm = cross(da, db);
                let nl = (nrm[0] * nrm[0] + nrm[1] * nrm[1] + nrm[2] * nrm[2]).sqrt();
                if nl < 1e-5 {
                    continue;
                }
                nrm = [nrm[0] / nl, nrm[1] / nl, nrm[2] / nl];
                pairs.push((lo, hi));
                let prof = self.build_road_profile(
                    da, db, cities[lo].target_r, cities[hi].target_r, &cities);
                let ab_cos = dot(da, db);
                roads.push(Road {
                    a: da,
                    b: db,
                    n: nrm,
                    ab_cos,
                    arc: ab_cos.clamp(-1.0, 1.0).acos(),
                    prof,
                });
                made += 1;
            }
        }

        // Seed smaller TOWNS along the roads (at evenly-spaced points on each arc),
        // so the network reads as connected places of varying size rather than a few
        // big cities. They sit ON a road → already connected, and get a smaller pad.
        // Added AFTER the road graph so they don't perturb it (pads only).
        let road_count = roads.len();
        for ri in 0..road_count {
            let (ra, rb) = (roads[ri].a, roads[ri].b);
            for k in 1..=TOWNS_PER_ROAD {
                let t = k as f32 / (TOWNS_PER_ROAD as f32 + 1.0);
                let d = slerp_dir(ra, rb, t);
                if land_ok(d).is_none() {
                    continue;
                }
                let (relief, mean_h) = self.pad_stats(d, TOWN_PAD_RADIUS);
                if relief > TOWN_MAX_RELIEF {
                    continue; // too sloped for a clean town pad
                }
                let (skirt_relief, _) = self.pad_stats(d, TOWN_PAD_RADIUS + CITY_BLEND * 0.7);
                if skirt_relief > TOWN_MAX_RELIEF * 1.6 {
                    continue; // pad would sit on a shelf over a drop-off
                }
                if cities.iter().any(|c| dot(d, c.dir) > TOWN_MIN_SEP_COS) {
                    continue; // too close to an existing city/town
                }
                cities.push(City { dir: d, target_r: self.radius + mean_h, pad_radius: TOWN_PAD_RADIUS });
            }
        }

        // Cheap broad-phase reject thresholds (small-angle approximations). Uses the
        // largest pad (a city) so towns — which are smaller — are always inside it.
        let city_ang = (CITY_PAD_RADIUS + CITY_BLEND) / self.radius;
        let city_cos_cutoff = (1.0 - 0.5 * city_ang * city_ang).clamp(-1.0, 1.0);
        let road_off_cutoff = (ROAD_HALF_WIDTH + ROAD_BLEND) / self.radius;

        Settlements {
            cities,
            roads,
            regions,
            city_cos_cutoff,
            road_off_cutoff,
        }
    }

    /// True if the great-circle arc between two unit directions dips below sea
    /// level ANYWHERE along it — i.e. the road would run over open water. Strict:
    /// roads stay entirely on land (no causeways, no bridges), so each city only
    /// links to neighbours it shares a landmass with. Sampled densely (32 points)
    /// so a narrow strait between the endpoints can't slip through unnoticed.
    fn arc_crosses_sea(&self, a: [f32; 3], b: [f32; 3]) -> bool {
        let sea = self.radius + ASSUMED_SEA_OFFSET;
        let steps = 32;
        for i in 0..=steps {
            let t = i as f32 / steps as f32;
            let d = slerp_dir(a, b, t);
            let h = self.base_height(d[0] * self.radius, d[1] * self.radius, d[2] * self.radius);
            if self.radius + h < sea {
                return true;
            }
        }
        false
    }

    /// River courses traced down the eroded channels (see ErosionField). `sea_offset`
    /// is the sea level relative to `radius` (the project's −200). Returns local-frame
    /// floor points placed at the EXACT terrain surface (radius + base_height, which
    /// includes the erosion carve), per-river lengths, and a per-point width factor.
    pub fn river_polylines(
        &self,
        sea_offset: f32,
    ) -> (Vec<[f32; 3]>, Vec<u32>, Vec<f32>, Vec<[f32; 3]>, Vec<f32>) {
        let (dirs, lengths, widths, lakes) = self.erosion.river_courses(sea_offset);
        // The trace steps one ~50 m erosion cell at a time, but the full-res terrain
        // has ridges/dips well inside that span — a ribbon chorded between the raw
        // trace points spent half its length buried under those bumps (the "no
        // rivers visible" failure). Subdivide each segment and drape EVERY point on
        // the true surface so the ribbon follows the ground it actually crosses.
        const SUBDIV: usize = 4;
        let surface_point = |d: [f32; 3]| -> [f32; 3] {
            let rr = self.radius
                + self.base_height(d[0] * self.radius, d[1] * self.radius, d[2] * self.radius);
            [d[0] * rr, d[1] * rr, d[2] * rr]
        };
        let mut points: Vec<[f32; 3]> = Vec::new();
        let mut out_lengths: Vec<u32> = Vec::with_capacity(lengths.len());
        let mut out_widths: Vec<f32> = Vec::new();
        let mut base = 0usize;
        for &len in &lengths {
            let n = len as usize;
            let mut count = 0u32;
            for i in 0..n {
                let d0 = dirs[base + i];
                points.push(surface_point(d0));
                out_widths.push(widths[base + i]);
                count += 1;
                if i + 1 < n {
                    let d1 = dirs[base + i + 1];
                    for s in 1..SUBDIV {
                        let t = s as f32 / SUBDIV as f32;
                        points.push(surface_point(slerp_dir(d0, d1, t)));
                        out_widths.push(widths[base + i] + (widths[base + i + 1] - widths[base + i]) * t);
                        count += 1;
                    }
                }
            }
            out_lengths.push(count);
            base += n;
        }
        let lengths = out_lengths;
        let widths = out_widths;
        // Lake centres at their water surface, plus radii.
        let mut lake_points: Vec<[f32; 3]> = Vec::with_capacity(lakes.len());
        let mut lake_radii: Vec<f32> = Vec::with_capacity(lakes.len());
        for l in &lakes {
            let rr = self.radius + l.water_disp;
            lake_points.push([l.dir[0] * rr, l.dir[1] * rr, l.dir[2] * rr]);
            lake_radii.push(l.radius);
        }
        (points, lengths, widths, lake_points, lake_radii)
    }

    /// Final carved surface radius along a unit direction — terrain + erosion + the
    /// settlement carve (pads, roads), matching the meshed ground (caves aside, which
    /// don't affect the land surface). GDScript queries this to drape city pavement,
    /// streets and buildings onto the real ground instead of a flat disc.
    pub fn surface_radius(&self, nx: f32, ny: f32, nz: f32) -> f32 {
        let surf = self.radius
            + self.base_height(nx * self.radius, ny * self.radius, nz * self.radius);
        self.apply_settlements(surf, nx, ny, nz)
    }

    /// Region (continent-cluster) landmark anchors: each region centre projected to
    /// the terrain surface (radius + base_height) in the local frame.
    pub fn region_points(&self) -> Vec<[f32; 3]> {
        self.settlements
            .regions
            .iter()
            .map(|d| {
                let rr = self.radius
                    + self.base_height(d[0] * self.radius, d[1] * self.radius, d[2] * self.radius);
                [d[0] * rr, d[1] * rr, d[2] * rr]
            })
            .collect()
    }

    /// Build a road's smoothed grade profile: sample the terrain surface radius
    /// along the arc, then run several endpoint-anchored smoothing passes so the
    /// grade is gentle (it stops following every local bump). The ends are pinned
    /// to the two city pad heights so the road meets each town flush — no step or
    /// jump where it joins the flat pad. The corridor flattens to this grade, so
    /// where the terrain rises above it the road is a cut and where it dips below
    /// the road is a fill: a graded route carved through the landscape.
    fn build_road_profile(
        &self, a: [f32; 3], b: [f32; 3], ra: f32, rb: f32, cities: &[City],
    ) -> Vec<f32> {
        let n = ROAD_PROFILE_SAMPLES;
        let arc = dot(a, b).clamp(-1.0, 1.0).acos() * self.radius;

        // 1. The terrain height we HUG along the centreline — WITH the city-pad
        //    carve applied (passed in explicitly: self.settlements isn't populated
        //    yet while the graph is being built). Hugging the RAW terrain was the
        //    "shelf then dive" bug: just past a pad rim the raw ground can drop
        //    well below the carved skirt, so the profile held pad height out onto
        //    a shelf and then pitched down hard to the raw surface. Against the
        //    CARVED ground the profile simply rides the skirt down.
        let mut terr = vec![0.0f32; n + 1];
        for i in 0..=n {
            let t = i as f32 / n as f32;
            let d = slerp_dir(a, b, t);
            let raw = self.radius
                + self.base_height(d[0] * self.radius, d[1] * self.radius, d[2] * self.radius);
            terr[i] = city_pad_carve(self.radius, cities, raw, d);
        }

        // 2. Start from the terrain, but hold the pad height flat across each pad
        //    and ease from the pad onto the terrain grade over ROAD_PAD_BLEND, so the
        //    road leaves town level and ramps gently — no cliff at the circle, and
        //    once past the ramp it simply follows the ground (hugs).
        let plateau = if arc > 1.0 { (CITY_PAD_RADIUS / arc).clamp(0.0, 0.4) } else { 0.0 };
        let trans = if arc > 1.0 { (ROAD_PAD_BLEND / arc).clamp(0.02, 0.4) } else { 0.0 };
        let mut p = terr.clone();
        for i in 0..=n {
            let t = i as f32 / n as f32;
            let te = t.min(1.0 - t); // distance (in t) from the nearer end
            let pad_h = if t < 0.5 { ra } else { rb };
            if te <= plateau {
                p[i] = pad_h;
            } else if te <= plateau + trans {
                let f = (te - plateau) / trans;
                let s = f * f * (3.0 - 2.0 * f); // smoothstep ease
                p[i] = pad_h + (terr[i] - pad_h) * s;
            }
        }

        // 3. Moderate smoothing: plane off small humps (the road carves through those)
        //    while still tracking the broad terrain profile.
        for _ in 0..ROAD_SMOOTH_ITERS {
            let src = p.clone();
            for i in 1..n {
                p[i] = (src[i - 1] + 2.0 * src[i] + src[i + 1]) * 0.25;
            }
            p[0] = ra;
            p[n] = rb;
        }

        // 4. Slope-limit: cap rise/run between adjacent samples so the road stays
        //    drivable. Where it bites the bed is pushed into a deeper cut / taller
        //    fill to hold the grade. Endpoints stay pinned.
        let step_len = arc / n as f32;
        let max_step = MAX_ROAD_SLOPE * step_len.max(1.0);
        for _ in 0..8 {
            for i in 1..=n {
                if p[i] - p[i - 1] > max_step {
                    p[i] = p[i - 1] + max_step;
                }
            }
            for i in (0..n).rev() {
                if p[i] - p[i + 1] > max_step {
                    p[i] = p[i + 1] + max_step;
                }
            }
        }
        p
    }

    /// True if a unit direction falls on a city pad or in a road corridor — the
    /// scatter keep-out (rocks/foliage skip these so they don't punch through
    /// pavement / block roads). Uses the same broad-phase as the carve.
    pub fn in_settlement(&self, dir: [f32; 3]) -> bool {
        let st = &*self.settlements;
        if st.cities.is_empty() {
            return false;
        }
        for c in &st.cities {
            let cd = dot(dir, c.dir);
            if cd < st.city_cos_cutoff {
                continue;
            }
            let hd = self.radius * (2.0 - 2.0 * cd).max(0.0).sqrt();
            if hd < c.pad_radius {
                return true;
            }
        }
        for rd in &st.roads {
            let off = dot(dir, rd.n);
            if off.abs() > st.road_off_cutoff {
                continue;
            }
            let px = dir[0] - rd.n[0] * off;
            let py = dir[1] - rd.n[1] * off;
            let pz = dir[2] - rd.n[2] * off;
            let pl = (px * px + py * py + pz * pz).sqrt();
            if pl < 1e-5 {
                continue;
            }
            let q = [px / pl, py / pl, pz / pl];
            if dot(q, rd.a) < rd.ab_cos || dot(q, rd.b) < rd.ab_cos {
                continue; // beyond an endpoint — the pad handles the ends
            }
            let cdq = dot(dir, q);
            let hd = self.radius * (2.0 - 2.0 * cdq).max(0.0).sqrt();
            if hd < ROAD_HALF_WIDTH {
                return true;
            }
        }
        false
    }

    pub fn cities(&self) -> &[City] {
        &self.settlements.cities
    }

    pub fn city_pad_radius(&self) -> f32 {
        CITY_PAD_RADIUS
    }

    /// Road centrelines sampled at the carved road-bed height, `steps + 1` points
    /// per road as local-frame positions. The bed is `radius + base_height -
    /// ROAD_CUT_DEPTH` — the SAME height the corridor flattening targets — so a
    /// ribbon laid on these points sits exactly in the cut and follows the
    /// terrain's profile instead of floating over its bumps. Dense sampling
    /// (`steps` is large) is what lets the ribbon hug rolling ground rather than
    /// chord straight across it. Returned flat (all roads concatenated); the
    /// caller slices by `steps + 1`.
    pub fn road_polylines(&self, steps: usize) -> Vec<[f32; 3]> {
        let mut out = Vec::with_capacity(self.settlements.roads.len() * (steps + 1));
        for r in &self.settlements.roads {
            for i in 0..=steps {
                let t = i as f32 / steps as f32;
                let d = slerp_dir(r.a, r.b, t);
                // Follow the ACTUAL carved surface — base terrain run through the same
                // settlement carve the mesher applies. In the corridor this is the
                // road bed (terrain − ROAD_CUT_DEPTH); approaching a town it blends up
                // to the flat pad. So the ribbon sits in the cut where the road is
                // carved AND rises to meet the pad at the ends — never floating over a
                // bump nor buried under one (the two failure modes a base_height-only
                // sample produced). GDScript lifts it a hair so it reads above the bed.
                let surf = self.radius
                    + self.base_height(d[0] * self.radius, d[1] * self.radius, d[2] * self.radius);
                let rr = self.apply_settlements(surf, d[0], d[1], d[2]);
                out.push([d[0] * rr, d[1] * rr, d[2] * rr]);
            }
        }
        out
    }

    /// Strict upper bound on the displaced surface radius — used by chunk
    /// culling. Must over-estimate `surface_r` over all directions or the octree
    /// culls chunks holding visible peaks. Mirrors density.gd::max_surface_radius.
    /// Settlement flattening only LOWERS peaks / fills toward a mid pad height,
    /// so it never exceeds this bound.
    pub fn max_surface_radius(&self) -> f32 {
        // + erosion deposition: erosion can RAISE the surface (sediment fill), so
        // the upper bound must include the field's largest rise or culling drops
        // chunks holding deposited highs.
        self.radius + 361.0 + MAX_TERRAIN_HEIGHT + 65.0 + 6.0 + MAX_SPIRE_HEIGHT + MAX_PLATEAU_RISE
            + 150.0 + self.erosion.max_rise()
    }

    /// Strict lower bound on the surface radius (deepest possible carve).
    /// Mirrors density.gd::min_surface_radius.
    pub fn min_surface_radius(&self) -> f32 {
        // − erosion incision: carved valleys cut below the raw surface.
        self.radius - 779.0 - MAX_CANYON_DEPTH - CAVE_BOTTOM_DEPTH - self.erosion.max_drop()
    }

    /// Terrain height displacement at a point (surface_r = radius + this), BEFORE
    /// settlement flattening and cave carving but AFTER global erosion. Every
    /// consumer (sample, settlement siting, road carve) goes through here so they
    /// all agree on the weathered surface. Erosion is a zero delta on small bodies
    /// / before the field is baked, so this reduces to the raw fractal height there.
    fn base_height(&self, x: f32, y: f32, z: f32) -> f32 {
        let raw = self.base_height_raw(x, y, z);
        let r2 = x * x + y * y + z * z;
        if r2 < 1e-8 {
            return raw;
        }
        let inv_r = 1.0 / r2.sqrt();
        raw + self.erosion.delta(x * inv_r, y * inv_r, z * inv_r)
    }

    /// The RAW fractal terrain height — the procedural layers only, no erosion. The
    /// erosion bake samples THIS (calling `base_height` would recurse), and
    /// `base_height` adds the baked delta on top.
    fn base_height_raw(&self, x: f32, y: f32, z: f32) -> f32 {
        let r = (x * x + y * y + z * z).sqrt();
        if r < 0.0001 {
            return 0.0;
        }
        let inv_r = 1.0 / r;
        let (nx, ny, nz) = (x * inv_r, y * inv_r, z * inv_r);

        // Domain-warp the look-up direction along the radial.
        let w = self.warp.get_noise_3d(x, y, z) * 240.0;
        let (psx, psy, psz) = (x + nx * w, y + ny * w, z + nz * w);

        let mut continent = self.continent.get_noise_3d(psx, psy, psz);
        // Wider spread + stronger negative bias so ~65–70% of the planet sits
        // below sea level (Earth is ~71% ocean). With the bigger height budget,
        // continents now have genuine elevation variation above water instead
        // of squashed bumps barely peeking above sea.
        continent = continent * 1.5 - 0.55;

        let land_mask = smoothstep(-0.05, 0.35, continent);

        let uwx = self.uber_warp.get_noise_3d(x, y, z) * 280.0;
        let uwy = self.uber_warp.get_noise_3d(x + 131.0, y - 47.0, z + 19.0) * 280.0;
        let uwz = self.uber_warp.get_noise_3d(x - 73.0, y + 11.0, z - 233.0) * 280.0;
        let region = self.uber.get_noise_3d(x + uwx, y + uwy, z + uwz);
        // Slightly broader, lower-threshold mountain belts so ranges are more
        // prevalent and the planet reads as having real cordilleras, not isolated bumps.
        let mountain_belt = smoothstep(0.05, 0.42, region);
        let hill_belt = 1.0 - smoothstep(-0.30, 0.25, region);

        // Ridged MULTIFRACTAL ridges: detail rides the crests and fades in the valleys,
        // so ranges have sharp, connected ridgelines instead of round bumps. (Was a
        // single ridged term raised to ^2.8.)
        let ridge =
            self.ridge.ridged_multi_3d(psx, psy, psz) * land_mask * mountain_belt;

        let mut hills = self
            .uber
            .get_noise_3d(x * 2.7 + 511.0, y * 2.7 - 219.0, z * 2.7 + 83.0);
        hills *= land_mask * hill_belt;

        let detail = self.detail.get_noise_3d(x, y, z);

        let biome = self
            .biome
            .get_noise_3d(x + uwx * 1.7, y + uwy * 1.7, z + uwz * 1.7);
        let spire_mask = smoothstep(0.62, 0.80, biome) * land_mask;
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

        continent * 380.0
            + ridge * MAX_TERRAIN_HEIGHT
            + hills * 65.0
            + detail * 6.0
            + spire * MAX_SPIRE_HEIGHT
            + plateau * MAX_PLATEAU_RISE
            - canyon * MAX_CANYON_DEPTH
    }

    /// Blend the raw surface radius toward a flat city pad / graded road
    /// corridor where one is in range. Returns the (possibly) flattened radius.
    /// Cheap dot-product broad-phase rejects almost every sample instantly, so
    /// the per-sample cost away from towns is a handful of multiplies.
    fn apply_settlements(&self, surface_r: f32, nx: f32, ny: f32, nz: f32) -> f32 {
        let st = &*self.settlements;
        if st.cities.is_empty() {
            return surface_r;
        }
        let dir = [nx, ny, nz];
        // Cities and roads each contribute a (weight, target) pair; they are
        // combined as a WEIGHT-BLENDED union below, not winner-take-all. The old
        // `if w > wmax` snap meant that at a highway↔pad junction — where both
        // weights are mid-range — the target jumped between "pad height" and
        // "road grade − cut" the moment the winner flipped: a guaranteed step at
        // exactly the city rim (the cliff where highways enter town).
        let mut wc = 0.0f32; // strongest city-pad weight
        let mut tc = surface_r;
        let mut wr = 0.0f32; // strongest road-corridor weight
        let mut tr = surface_r;

        for c in &st.cities {
            let cd = dot(dir, c.dir);
            if cd < st.city_cos_cutoff {
                continue;
            }
            let hd = self.radius * (2.0 - 2.0 * cd).max(0.0).sqrt();   // ~arc distance
            let w = smoothstep(c.pad_radius + CITY_BLEND, c.pad_radius, hd);
            if w > wc {
                wc = w;
                // PARTIAL flatten, not a dead-flat disc: blend the local terrain
                // toward the pad height by CITY_FLATTEN. The town settles INTO the
                // ground — undulating gently with it and easing into the surrounds at
                // the rim — instead of a flat circle stamped on the landscape. (At the
                // centre the terrain already ≈ target_r, so downtown stays level.)
                tc = surface_r + (c.target_r - surface_r) * CITY_FLATTEN;
            }
        }

        for rd in &st.roads {
            let off = dot(dir, rd.n);   // sine of angle off the arc plane
            if off.abs() > st.road_off_cutoff {
                continue;
            }
            // Closest point on the great circle: dir projected onto the plane.
            let px = nx - rd.n[0] * off;
            let py = ny - rd.n[1] * off;
            let pz = nz - rd.n[2] * off;
            let pl = (px * px + py * py + pz * pz).sqrt();
            if pl < 1e-5 {
                continue;
            }
            let q = [px / pl, py / pl, pz / pl];
            let da = dot(q, rd.a);
            let db = dot(q, rd.b);
            // On the segment when q is at least as close to each endpoint as the
            // endpoints are to each other (both arc-angles ≤ the full arc).
            if da < rd.ab_cos || db < rd.ab_cos {
                continue;   // beyond an endpoint — the city pad handles the ends
            }
            let cdq = dot(dir, q);
            let hd = self.radius * (2.0 - 2.0 * cdq).max(0.0).sqrt();
            let w = smoothstep(ROAD_HALF_WIDTH + ROAD_BLEND, ROAD_HALF_WIDTH, hd);
            if w > wr {
                // Road height = the SMOOTHED grade at q's position along the arc, not
                // the raw terrain height there. Holding a gentle grade (anchored to
                // the city pads at the ends) is what turns the road into a cut where
                // the ground rises above it and a fill where it dips below — so it
                // carves through hills instead of riding steeply over each one, and
                // meets the towns flush. Reuse `da` (= dot(q, rd.a)) and the road's
                // precomputed arc instead of recomputing the dot + two acos here.
                let da_q = da.clamp(-1.0, 1.0).acos();
                let t = (da_q / rd.arc.max(1e-4)).clamp(0.0, 1.0);
                wr = w;
                // The cut below grade FADES OUT as the pad takes over (× 1 − wc):
                // inside town the road must meet the pad surface flush, not sit in a
                // 6 m trench ending at the rim.
                tr = sample_profile(&rd.prof, t) - ROAD_CUT_DEPTH * (1.0 - wc);
            }
        }

        // Weight-blended union: targets mix by relative strength, so the surface
        // is continuous across the pad↔road handover; overall pull toward the
        // blended target uses the stronger of the two weights.
        let wsum = wc + wr;
        if wsum <= 0.0 {
            return surface_r;
        }
        let target = (tc * wc + tr * wr) / wsum;
        surface_r + (target - surface_r) * wc.max(wr)
    }

    /// Per-direction "urban" weight (0 = wild ground, 1 = pad/road centre) — the same
    /// blend weight `apply_settlements` uses, exposed so the mesher can tag vertices for
    /// the terrain shader to read the ground as packed/trodden urban earth under a town
    /// (instead of a stamped concrete disc). Roads weigh less, so the verge is only
    /// lightly worn. Cheap dot-product broad-phase, like the carve.
    pub fn settlement_factor(&self, nx: f32, ny: f32, nz: f32) -> f32 {
        let st = &*self.settlements;
        if st.cities.is_empty() {
            return 0.0;
        }
        let dir = [nx, ny, nz];
        let mut w = 0.0f32;
        for c in &st.cities {
            let cd = dot(dir, c.dir);
            if cd < st.city_cos_cutoff {
                continue;
            }
            let hd = self.radius * (2.0 - 2.0 * cd).max(0.0).sqrt();
            w = w.max(smoothstep(c.pad_radius + CITY_BLEND, c.pad_radius, hd));
        }
        for rd in &st.roads {
            let off = dot(dir, rd.n);
            if off.abs() > st.road_off_cutoff {
                continue;
            }
            let px = nx - rd.n[0] * off;
            let py = ny - rd.n[1] * off;
            let pz = nz - rd.n[2] * off;
            let pl = (px * px + py * py + pz * pz).sqrt();
            if pl < 1e-5 {
                continue;
            }
            let q = [px / pl, py / pl, pz / pl];
            if dot(q, rd.a) < rd.ab_cos || dot(q, rd.b) < rd.ab_cos {
                continue;
            }
            let cdq = dot(dir, q);
            let hd = self.radius * (2.0 - 2.0 * cdq).max(0.0).sqrt();
            w = w.max(smoothstep(ROAD_HALF_WIDTH + ROAD_BLEND, ROAD_HALF_WIDTH, hd) * 0.7);
        }
        w
    }

    /// Density at a world-space point. Positive = solid (inside the planet).
    /// Exact (no radial early-out): callers are GDScript queries — player
    /// altitude, Newton surface-snap — where the value matters far from the
    /// surface, not just the sign. The mesher samples via `sample_opts`.
    pub fn sample(&self, x: f32, y: f32, z: f32) -> f32 {
        self.sample_exact(x, y, z, true)
    }

    /// Conservative broad-phase: could any city pad or road corridor affect a sample
    /// inside this world-space AABB? The mesher calls this ONCE per chunk and, when
    /// it returns false, samples the whole chunk via `sample_opts(.., false)` — which
    /// skips the per-voxel settlement loop entirely. That loop otherwise runs over all
    /// cities + roads for every one of the (R+3)³ voxels in every chunk in the world,
    /// even the vast majority nowhere near a town. Errs toward `true` (a false negative
    /// would let terrain bulge up through a pad); a false positive just keeps the exact
    /// path. Cheap: a handful of point-in-sphere tests per city/road, once per chunk.
    pub fn settlements_near(&self, lo: [f32; 3], hi: [f32; 3]) -> bool {
        let st = &*self.settlements;
        if st.cities.is_empty() {
            return false;
        }
        let cc = [(lo[0] + hi[0]) * 0.5, (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5];
        let hx = (hi[0] - lo[0]) * 0.5;
        let hy = (hi[1] - lo[1]) * 0.5;
        let hz = (hi[2] - lo[2]) * 0.5;
        let cr = (hx * hx + hy * hy + hz * hz).sqrt(); // chunk bounding-sphere radius
        let within = |p: [f32; 3], reach: f32| -> bool {
            let dx = cc[0] - p[0];
            let dy = cc[1] - p[1];
            let dz = cc[2] - p[2];
            dx * dx + dy * dy + dz * dz <= reach * reach
        };
        for c in &st.cities {
            let p = [c.dir[0] * c.target_r, c.dir[1] * c.target_r, c.dir[2] * c.target_r];
            if within(p, cr + c.pad_radius + CITY_BLEND) {
                return true;
            }
        }
        // Sample each road's carved centreline; each point's reach covers the corridor
        // plus the half-gap back to the previous sample, so the whole arc is covered.
        let steps = 24usize;
        for rd in &st.roads {
            let mut prev: Option<[f32; 3]> = None;
            for i in 0..=steps {
                let t = i as f32 / steps as f32;
                let d = slerp_dir(rd.a, rd.b, t);
                let rr = sample_profile(&rd.prof, t);
                let p = [d[0] * rr, d[1] * rr, d[2] * rr];
                let seg = match prev {
                    Some(q) => {
                        let dx = p[0] - q[0];
                        let dy = p[1] - q[1];
                        let dz = p[2] - q[2];
                        0.5 * (dx * dx + dy * dy + dz * dz).sqrt()
                    }
                    None => 0.0,
                };
                prev = Some(p);
                if within(p, cr + ROAD_HALF_WIDTH + ROAD_BLEND + seg) {
                    return true;
                }
            }
        }
        false
    }

    /// Density at a world-space point, with the option to skip the settlement carve.
    /// `with_settlement = false` is used by the mesher for chunks `settlements_near`
    /// has proved are clear of every pad/road — there the carve is a guaranteed no-op,
    /// so the per-voxel city/road loop is pure overhead. Positive = solid.
    pub fn sample_opts(&self, x: f32, y: f32, z: f32, with_settlement: bool) -> f32 {
        // Radial early-out: outside the strict surface band the SIGN of the density
        // is already decided (no peak reaches above max_bound; no carve — canyon,
        // cave, erosion — cuts below min_bound), so skip the ~40 noise octaves and
        // return a sign-correct pseudo-distance with the same radial slope (−1) the
        // real field has. Marching cubes only emits geometry in sign-crossing cells,
        // which all lie strictly inside the band, so the mesh is bit-identical; only
        // far-from-surface samples (most of a coarse chunk's volume) take this path.
        let r2 = x * x + y * y + z * z;
        if r2 > self.max_bound * self.max_bound {
            return self.max_bound - r2.sqrt(); // definitely air
        }
        if r2 < self.min_bound * self.min_bound {
            return self.min_bound - r2.sqrt(); // definitely solid (positive)
        }
        self.sample_exact(x, y, z, with_settlement)
    }

    /// Full density evaluation, no radial early-out. The player's altitude query
    /// (`-density` ≈ height above the LOCAL terrain) goes through here so it stays
    /// exact even far above the max-peak shell, where `sample_opts`' fast path
    /// would report distance to the shell instead of to the ground below.
    pub fn sample_exact(&self, x: f32, y: f32, z: f32, with_settlement: bool) -> f32 {
        let r = (x * x + y * y + z * z).sqrt();
        if r < 0.0001 {
            return self.radius;
        }
        let inv_r = 1.0 / r;
        let (nx, ny, nz) = (x * inv_r, y * inv_r, z * inv_r);

        let height = self.base_height(x, y, z);
        let mut surface_r = self.radius + height;
        if with_settlement {
            surface_r = self.apply_settlements(surface_r, nx, ny, nz);
        }
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

#[inline]
fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

// The city-pad part of the settlement carve, against an explicit city list — the
// same weight/target formula `apply_settlements` uses for pads. Used while the
// graph is still being BUILT (road profiles need the carved ground near pads
// before `self.settlements` exists).
fn city_pad_carve(planet_r: f32, cities: &[City], surface_r: f32, dir: [f32; 3]) -> f32 {
    let mut w = 0.0f32;
    let mut target = surface_r;
    for c in cities {
        let cd = dot(dir, c.dir);
        let hd = planet_r * (2.0 - 2.0 * cd).max(0.0).sqrt();
        let ww = smoothstep(c.pad_radius + CITY_BLEND, c.pad_radius, hd);
        if ww > w {
            w = ww;
            target = surface_r + (c.target_r - surface_r) * CITY_FLATTEN;
        }
    }
    surface_r + (target - surface_r) * w
}

// Linear-interpolate a road grade profile at t ∈ [0, 1] (0 = a, 1 = b).
fn sample_profile(prof: &[f32], t: f32) -> f32 {
    if prof.is_empty() {
        return 0.0;
    }
    let n = prof.len() - 1;
    let f = (t.clamp(0.0, 1.0)) * n as f32;
    let i = (f.floor() as usize).min(n);
    let j = (i + 1).min(n);
    prof[i] + (prof[j] - prof[i]) * (f - i as f32)
}

// Spherical interpolation between two unit directions, renormalised.
fn slerp_dir(a: [f32; 3], b: [f32; 3], t: f32) -> [f32; 3] {
    let d = dot(a, b).clamp(-1.0, 1.0);
    let omega = d.acos();
    if omega < 1e-4 {
        return a;
    }
    let so = omega.sin();
    let wa = ((1.0 - t) * omega).sin() / so;
    let wb = (t * omega).sin() / so;
    let r = [
        a[0] * wa + b[0] * wb,
        a[1] * wa + b[1] * wb,
        a[2] * wa + b[2] * wb,
    ];
    let l = (r[0] * r[0] + r[1] * r[1] + r[2] * r[2]).sqrt().max(1e-6);
    [r[0] / l, r[1] / l, r[2] / l]
}

#[inline]
fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    // The radial early-out in `sample_opts` must NEVER disagree in sign with the
    // exact field — a sign flip would move marching-cubes geometry. Sweep random
    // directions across the whole radial range (deep rock → orbit) on a small body
    // (radius < SETTLEMENT_MIN_RADIUS, so no slow erosion/settlement bake).
    #[test]
    fn early_out_sign_matches_exact() {
        let d = PlanetDensity::new(1337, 4000.0);
        let mut mismatches = 0;
        for i in 0..20_000u32 {
            let dir = rand_unit(7, i);
            // Radii from well inside the planet to well above the peak shell.
            let r = 1500.0 + (hash_u32(i ^ 0xABCD) as f32 / u32::MAX as f32) * 6000.0;
            let (x, y, z) = (dir[0] * r, dir[1] * r, dir[2] * r);
            let fast = d.sample_opts(x, y, z, true);
            let exact = d.sample_exact(x, y, z, true);
            if (fast > 0.0) != (exact > 0.0) {
                mismatches += 1;
            }
        }
        assert_eq!(mismatches, 0, "early-out changed the density sign");
    }
}
