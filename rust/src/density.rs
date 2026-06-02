//! Port of `scripts/planet/density.gd`'s composition, on top of our own
//! hand-rolled noise (`crate::noise`) — no external noise crate. The layer
//! structure (continents, ridges, hills, spires, plateaus, canyons, caves) and
//! the height budget are the same; only the underlying noise basis differs, so
//! the planet's look will need re-tuning.

use crate::noise::{Fractal, Noise};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

// Earth-scale dramatic peaks: 900 m mountains read as a real range on the
// horizon from the ground, and from orbit you can see ridges silhouette
// against the sky. The previous 170 m budget was nearly flat. Continent +
// canyon amplitudes follow so ocean basins are deep and continents have
// genuine elevation variation, not just a thin crust of bumps.
const MAX_TERRAIN_HEIGHT: f32 = 900.0;
const MAX_SPIRE_HEIGHT: f32 = 520.0;
const MAX_PLATEAU_RISE: f32 = 280.0;
const MAX_CANYON_DEPTH: f32 = 320.0;
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
const SETTLEMENT_REGIONS: usize = 6;    // continents/regions that get a town cluster
const CITIES_PER_REGION: usize = 4;     // towns per region → up to 24 total
const REGION_SEP_COS: f32 = 0.55;       // region centres ≥ ~57° apart (well separated)
const REGION_RADIUS_COS: f32 = 0.990;   // towns sit within ~8° of their region centre
const REGION_JITTER: f32 = 0.11;        // angular spread of towns around the centre
const CITY_MIN_SEP_COS: f32 = 0.9990;   // towns ≥ ~2.6° apart (pads never overlap)
const CITY_PAD_RADIUS: f32 = 240.0;     // flat disc radius (world units)
const CITY_BLEND: f32 = 220.0;          // graded skirt outside the pad
const ROADS_PER_CITY: usize = 4;        // connect each town to its nearest land neighbours
const CITY_MAX_HEIGHT: f32 = MAX_TERRAIN_HEIGHT * 0.5;  // keep towns off extreme peaks
// Sea sits at radius + sea_level_offset; this mirrors the project's -200 m
// (world.gd / planet sea_level_offset). Most of the planet is ocean and land
// rarely tops a few tens of metres, so towns are sited a modest margin above
// the waterline rather than on the scarce high ground.
const ASSUMED_SEA_OFFSET: f32 = -200.0;
const CITY_MIN_ABOVE_SEA: f32 = 60.0;
const ROAD_HALF_WIDTH: f32 = 26.0;      // flat road corridor half-width
const ROAD_BLEND: f32 = 70.0;           // graded verge outside the corridor

pub struct City {
    pub dir: [f32; 3],   // unit direction in the planet's LOCAL frame
    pub target_r: f32,   // flattened pad radius from the planet centre
}

pub struct Road {
    a: [f32; 3],
    b: [f32; 3],
    n: [f32; 3],   // unit normal of the great-circle plane through a & b
    ab_cos: f32,   // dot(a, b) — cosine of the arc's subtended angle
}

/// The full settlement graph for one (seed, radius) body. Built ONCE and shared
/// (behind an `Arc`) by every `PlanetDensity` for that body — see SETTLEMENT_CACHE.
pub struct Settlements {
    cities: Vec<City>,
    roads: Vec<Road>,
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
        };
        if radius >= SETTLEMENT_MIN_RADIUS {
            s.settlements = get_or_build_settlements(seed, radius, &s);
        }
        s
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

        // 2. Fill each region with a tight cluster of towns, all on land and a
        //    little apart, by jittering directions around the region centre.
        let mut cities: Vec<City> = Vec::new();
        for (k, rc) in regions.iter().enumerate() {
            let mut placed = 0usize;
            let mut cidx = 0u32;
            let mut ctries = 0u32;
            let region_seed = seed ^ 0x5EED ^ ((k as i32).wrapping_mul(7919));
            while placed < CITIES_PER_REGION && ctries < 4000 {
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
                let target_r = match land_ok(d) {
                    Some(r) => r,
                    None => continue,
                };
                if cities
                    .iter()
                    .any(|c| dot(d, c.dir) > CITY_MIN_SEP_COS)
                {
                    continue; // too close to an existing town
                }
                cities.push(City { dir: d, target_r });
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
                roads.push(Road {
                    a: da,
                    b: db,
                    n: nrm,
                    ab_cos: dot(da, db),
                });
                made += 1;
            }
        }

        // Cheap broad-phase reject thresholds (small-angle approximations).
        let city_ang = (CITY_PAD_RADIUS + CITY_BLEND) / self.radius;
        let city_cos_cutoff = (1.0 - 0.5 * city_ang * city_ang).clamp(-1.0, 1.0);
        let road_off_cutoff = (ROAD_HALF_WIDTH + ROAD_BLEND) / self.radius;

        Settlements {
            cities,
            roads,
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

    pub fn cities(&self) -> &[City] {
        &self.settlements.cities
    }

    pub fn city_pad_radius(&self) -> f32 {
        CITY_PAD_RADIUS
    }

    /// Road centrelines sampled at the terrain surface height, `steps + 1` points
    /// per road as local-frame positions (`dir * (radius + base_height)`). This is
    /// the SAME height the corridor flattening targets, so a ribbon laid on these
    /// points sits exactly on the flattened road and follows the terrain's profile.
    /// Returned flat (all roads concatenated); the caller slices by `steps + 1`.
    pub fn road_polylines(&self, steps: usize) -> Vec<[f32; 3]> {
        let mut out = Vec::with_capacity(self.settlements.roads.len() * (steps + 1));
        for r in &self.settlements.roads {
            for i in 0..=steps {
                let t = i as f32 / steps as f32;
                let d = slerp_dir(r.a, r.b, t);
                let h = self.base_height(d[0] * self.radius, d[1] * self.radius, d[2] * self.radius);
                let rr = self.radius + h;
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
        self.radius + 361.0 + MAX_TERRAIN_HEIGHT + 65.0 + 6.0 + MAX_SPIRE_HEIGHT + MAX_PLATEAU_RISE
            + 150.0
    }

    /// Strict lower bound on the surface radius (deepest possible carve).
    /// Mirrors density.gd::min_surface_radius.
    pub fn min_surface_radius(&self) -> f32 {
        self.radius - 779.0 - MAX_CANYON_DEPTH - CAVE_BOTTOM_DEPTH
    }

    /// The raw terrain height displacement at a point (surface_r = radius + this),
    /// BEFORE settlement flattening and cave carving. Factored out so settlement
    /// generation can probe the surface height at candidate sites.
    fn base_height(&self, x: f32, y: f32, z: f32) -> f32 {
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
        let mut wmax = 0.0f32;
        let mut target = surface_r;

        for c in &st.cities {
            let cd = dot(dir, c.dir);
            if cd < st.city_cos_cutoff {
                continue;
            }
            let hd = self.radius * (2.0 - 2.0 * cd).max(0.0).sqrt();   // ~arc distance
            let w = smoothstep(CITY_PAD_RADIUS + CITY_BLEND, CITY_PAD_RADIUS, hd);
            if w > wmax {
                wmax = w;
                target = c.target_r;
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
            if w > wmax {
                // Road height FOLLOWS the terrain along its centreline (the surface
                // height at the closest on-arc point `q`) rather than a straight
                // pad-to-pad ramp. Flattening only the cross-section means the road
                // hugs the ground's rise and fall instead of cutting a deep notch
                // through hills / bridging valleys on a dead-straight grade.
                wmax = w;
                target = self.radius
                    + self.base_height(q[0] * self.radius, q[1] * self.radius, q[2] * self.radius);
            }
        }

        surface_r + (target - surface_r) * wmax
    }

    /// Density at a world-space point. Positive = solid (inside the planet).
    pub fn sample(&self, x: f32, y: f32, z: f32) -> f32 {
        let r = (x * x + y * y + z * z).sqrt();
        if r < 0.0001 {
            return self.radius;
        }
        let inv_r = 1.0 / r;
        let (nx, ny, nz) = (x * inv_r, y * inv_r, z * inv_r);

        let height = self.base_height(x, y, z);
        let mut surface_r = self.radius + height;
        surface_r = self.apply_settlements(surface_r, nx, ny, nz);
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
