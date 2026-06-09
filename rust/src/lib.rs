use godot::prelude::*;
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex, OnceLock};

mod density;
mod erosion;
mod mesher;
mod noise;
mod scatter;
mod tables;

use mesher::MeshData;

struct TransvoxelNative;

#[gdextension]
unsafe impl ExtensionLibrary for TransvoxelNative {}

struct Job {
    id: i64,
    seed: i32,
    radius: f32,
    origin: [f32; 3],
    size: f32,
    resolution: usize,
    coarser_mask: i32,
    pc: [f32; 3],
    want_collision: bool,
    want_scatter: bool,   // generate rock/foliage transforms in the worker (near chunks only)
    want_foliage: bool,   // include foliage (false for airless bodies)
    want_scatter_collision: bool, // also de-index a rock collision soup (closest LOD only)
    sea_offset: f32,      // sea level relative to radius — scatter skips submerged ground
}

// Shared rock proto-mesh (flat x,y,z triangle soup, local space), registered once by
// GDScript via `set_rock_proto`. The worker transforms it by each rock instance to
// build the chunk's rock collision soup — keeping GDScript the single source of the
// mesh geometry while moving the per-vertex transform off the main thread.
static ROCK_PROTO: OnceLock<Vec<f32>> = OnceLock::new();

struct Shared {
    input: Mutex<VecDeque<Job>>,
    input_cv: Condvar,
    output: Mutex<HashMap<i64, MeshData>>,
}

// One process-wide worker pool shared by EVERY NativeTerrain (planet AND moon).
// Each instance used to spawn its own `available_parallelism()` workers, so two
// bodies meant 2× cores of threads all contending — oversubscription that adds
// context-switching without adding throughput (meshing is CPU-bound, so the
// useful worker count is the core count). A single shared pool, keyed by the
// globally-unique chunk instance ids, fixes that. The pool lives for the whole
// process and its workers are daemons (no shutdown/join needed for a game).
static POOL: OnceLock<Arc<Shared>> = OnceLock::new();

fn pool() -> &'static Arc<Shared> {
    POOL.get_or_init(|| {
        let shared = Arc::new(Shared {
            input: Mutex::new(VecDeque::new()),
            input_cv: Condvar::new(),
            output: Mutex::new(HashMap::new()),
        });
        let n = std::thread::available_parallelism()
            .map(|x| x.get())
            .unwrap_or(4)
            .max(1);
        for _ in 0..n {
            let s = shared.clone();
            std::thread::spawn(move || worker_loop(s));
        }
        shared
    })
}

// Pure-Rust worker. Never touches the Godot API, so running it off the main
// thread is sound (the gap-prone part was calling gdext from a worker — here
// only submit/poll/take run on the main thread).
fn worker_loop(shared: Arc<Shared>) {
    loop {
        let job = {
            let mut q = shared.input.lock().unwrap();
            while q.is_empty() {
                q = shared.input_cv.wait(q).unwrap();
            }
            q.pop_front().unwrap()
        };
        let density = density::shared(job.seed, job.radius);
        let mut mesh = mesher::build(
            job.origin, job.size, job.resolution, job.coarser_mask, job.pc,
            job.want_collision, &density,
        );
        // Prop scatter, computed HERE on the worker (was a per-triangle main-thread
        // pass in GDScript — the streaming hitch). Only near chunks ask for it.
        if job.want_scatter && !mesh.indices.is_empty() {
            let cs = scatter_seed(job.origin);
            let sd = scatter::build(
                &mesh.positions, &mesh.normals, &mesh.indices,
                job.radius, job.sea_offset, cs, job.want_foliage,
                &|d| density.in_settlement(d),
            );
            // Rock collision soup, built here on the worker (closest LOD only) by
            // transforming the registered proto-mesh — off the main thread.
            if job.want_scatter_collision && !sd.rocks.is_empty() {
                if let Some(proto) = ROCK_PROTO.get() {
                    mesh.rock_collision_faces = scatter::rock_collision_soup(&sd.rocks, proto);
                }
            }
            mesh.rock_xforms = sd.rocks;
            mesh.foliage_xforms = sd.foliage;
        }
        shared.output.lock().unwrap().insert(job.id, mesh);
    }
}

// Deterministic per-chunk scatter seed from the chunk origin (FNV-1a over the bits),
// so scatter is stable across runs and regardless of when the chunk meshes.
fn scatter_seed(origin: [f32; 3]) -> u32 {
    let mut h: u32 = 0x811C_9DC5;
    for c in origin {
        h ^= c.to_bits();
        h = h.wrapping_mul(0x0100_0193);
    }
    h | 1
}

/// Native voxel chunk generator. Hand-rolled density + marching-cubes mesher
/// (no algorithm crates), meshed on the shared `POOL`. GDScript submits jobs and
/// polls/takes finished meshes — all Godot interaction stays on the main thread.
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct NativeTerrain {
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for NativeTerrain {
    fn init(base: Base<RefCounted>) -> Self {
        let _ = pool(); // make sure the shared worker pool is running
        Self { base }
    }
}

#[godot_api]
impl NativeTerrain {
    /// Load-confirmation sentinel (main.gd self-test).
    #[func]
    fn ping(&self) -> i64 {
        42
    }

    /// Set the on-disk cache directory for the erosion bake (GDScript passes the
    /// globalized user:// path). Must be called before the first chunk job for
    /// the cache to be used on this run; first call wins, later calls no-op.
    #[func]
    fn set_cache_dir(&self, path: GString) {
        erosion::set_cache_dir(&path.to_string());
    }

    /// Register the shared rock proto-mesh (a de-indexed triangle soup in the rock's
    /// local space) ONCE. The worker transforms it by each rock instance to build the
    /// closest-LOD chunks' rock collision soup, so GDScript still owns the geometry but
    /// the per-vertex transform no longer runs on the main thread. First call wins
    /// (the proto is constant); later calls are ignored.
    #[func]
    fn set_rock_proto(&self, faces: PackedVector3Array) {
        let mut flat: Vec<f32> = Vec::with_capacity(faces.len() * 3);
        for v in faces.as_slice() {
            flat.push(v.x);
            flat.push(v.y);
            flat.push(v.z);
        }
        let _ = ROCK_PROTO.set(flat);
    }

    /// Diagnostic: sample the surface radius over a lat/long grid (Newton-solve
    /// the iso-surface along each direction) and return (min, mean, max). Lets
    /// GDScript compare against the sea sphere radius to set the sea level
    /// exactly instead of guessing the continental bias.
    #[func]
    fn surface_radius_stats(&self, seed: i64, radius: f64) -> Vector3 {
        let density = density::shared(seed as i32, radius as f32);
        let r0 = radius as f32;
        let mut mn = f32::INFINITY;
        let mut mx = f32::NEG_INFINITY;
        let mut sum = 0.0f32;
        let mut cnt = 0u32;
        let n = 64i32;
        for i in 0..n {
            let lat = (-0.5 + (i as f32 + 0.5) / n as f32) * std::f32::consts::PI;
            let (sl, cl) = (lat.sin(), lat.cos());
            for j in 0..(2 * n) {
                let lon = (j as f32 / (2 * n) as f32) * std::f32::consts::TAU;
                let dir = (cl * lon.cos(), sl, cl * lon.sin());
                let mut r = r0;
                for _ in 0..12 {
                    r += density.sample(dir.0 * r, dir.1 * r, dir.2 * r);
                }
                mn = mn.min(r);
                mx = mx.max(r);
                sum += r;
                cnt += 1;
            }
        }
        Vector3::new(mn, sum / cnt as f32, mx)
    }

    /// Queue a chunk to be meshed on the thread pool. `id` is the GDScript
    /// chunk's instance id (so the result can be routed back). `coarser_mask`
    /// bits mark faces whose neighbour is coarser (bit 0 -X … 5 +Z).
    /// `build_collision` makes the worker also emit a de-indexed triangle-soup
    /// (`collision_faces`) ready for ConcavePolygonShape3D — only for the near
    /// chunks that need it, so the main thread no longer gathers it per-index.
    #[func]
    fn submit_chunk(
        &self,
        id: i64,
        seed: i64,
        radius: f64,
        origin: Vector3,
        size: f64,
        resolution: i64,
        coarser_mask: i64,
        planet_center: Vector3,
        build_collision: bool,
        want_scatter: bool,
        want_foliage: bool,
        want_scatter_collision: bool,
        sea_offset: f64,
    ) {
        let job = Job {
            id,
            seed: seed as i32,
            radius: radius as f32,
            origin: [origin.x, origin.y, origin.z],
            size: size as f32,
            resolution: resolution.max(1) as usize,
            coarser_mask: coarser_mask as i32,
            pc: [planet_center.x, planet_center.y, planet_center.z],
            want_collision: build_collision,
            want_scatter,
            want_foliage,
            want_scatter_collision,
            sea_offset: sea_offset as f32,
        };
        let p = pool();
        p.input.lock().unwrap().push_back(job);
        p.input_cv.notify_one();
    }

    /// Single source of truth for the planet's density, shared with GDScript so
    /// `DensityField` (player altitude / surface-snap queries) samples the EXACT
    /// field the mesher uses — no more hand-kept GDScript copy that can drift.
    #[func]
    fn density_sample(&self, seed: i64, radius: f64, p: Vector3) -> f64 {
        let density = density::shared(seed as i32, radius as f32);
        density.sample(p.x, p.y, p.z) as f64
    }

    /// (min_surface_radius, max_surface_radius) for the given planet — the strict
    /// bounds the octree uses for chunk culling. Returned as a Vector2 so the
    /// GDScript side can cache both from one call.
    #[func]
    fn density_bounds(&self, seed: i64, radius: f64) -> Vector2 {
        let density = density::shared(seed as i32, radius as f32);
        Vector2::new(density.min_surface_radius(), density.max_surface_radius())
    }

    /// Deterministic placeholder settlements for this body — the same city pads
    /// and road corridors that `PlanetDensity` flattens into the terrain, handed
    /// to GDScript so it can drop building/road visuals exactly on the flat ground.
    /// Returns { centers: PackedVector3Array (local-frame pad centres),
    /// roads: PackedVector3Array (endpoint pairs a0,b0,a1,b1,…), pad_radius }.
    #[func]
    fn settlement_data(&self, seed: i64, radius: f64) -> VarDictionary {
        let density = density::shared(seed as i32, radius as f32);
        let mut centers: Vec<Vector3> = Vec::new();
        let mut pad_radii: Vec<f32> = Vec::new();
        for c in density.cities() {
            centers.push(Vector3::new(
                c.dir[0] * c.target_r,
                c.dir[1] * c.target_r,
                c.dir[2] * c.target_r,
            ));
            pad_radii.push(c.pad_radius);
        }
        // Road centrelines sampled at the carved road-bed height: `road_steps`
        // points per road, all roads concatenated. GDScript slices by `road_steps`
        // and lays a ribbon along each polyline so the road conforms to the ground
        // it was carved into (instead of a straight pad-to-pad ramp floating over
        // hills). Sampled densely (was 24) so the ribbon actually hugs rolling
        // terrain — at 24 a long road chorded straight across every hill; 96 keeps
        // each segment short enough to track the surface and the cut beneath it.
        let road_steps: usize = 96;
        let pts = density.road_polylines(road_steps);
        let road_points: Vec<Vector3> =
            pts.iter().map(|p| Vector3::new(p[0], p[1], p[2])).collect();

        let mut dict = VarDictionary::new();
        dict.set("centers", PackedVector3Array::from(centers.as_slice()));
        dict.set("pad_radii", PackedFloat32Array::from(pad_radii.as_slice()));
        dict.set("road_points", PackedVector3Array::from(road_points.as_slice()));
        dict.set("road_steps", (road_steps + 1) as i64);
        dict.set("pad_radius", density.city_pad_radius() as f64);  // legacy: the city pad size
        dict
    }

    /// River courses traced down the baked erosion channels. `sea_offset` is the
    /// sea level relative to `radius` (the project's −200). Returns
    /// { points: PackedVector3Array (local-frame channel-floor points, all rivers
    ///   concatenated), lengths: PackedInt32Array (points per river), widths:
    ///   PackedFloat32Array (0..1 per point — flow, so rivers widen downstream) }.
    /// Empty for bodies without erosion (the moon).
    #[func]
    fn river_data(&self, seed: i64, radius: f64, sea_offset: f64) -> VarDictionary {
        let density = density::shared(seed as i32, radius as f32);
        let (pts, lens, widths, lake_pts, lake_radii) = density.river_polylines(sea_offset as f32);
        let points: Vec<Vector3> = pts.iter().map(|p| Vector3::new(p[0], p[1], p[2])).collect();
        let lengths: Vec<i32> = lens.iter().map(|&l| l as i32).collect();
        let lakes: Vec<Vector3> = lake_pts.iter().map(|p| Vector3::new(p[0], p[1], p[2])).collect();

        let mut dict = VarDictionary::new();
        dict.set("points", PackedVector3Array::from(points.as_slice()));
        dict.set("lengths", PackedInt32Array::from(lengths.as_slice()));
        dict.set("widths", PackedFloat32Array::from(widths.as_slice()));
        dict.set("lakes", PackedVector3Array::from(lakes.as_slice()));
        dict.set("lake_radii", PackedFloat32Array::from(lake_radii.as_slice()));
        dict
    }

    /// Batch surface-radius query: for each unit direction in `dirs`, the final
    /// carved surface radius (terrain + erosion + settlement carve). Builds the
    /// density once and samples all directions, so GDScript can drape a town's
    /// pavement / streets / buildings onto the real ground in a single call.
    #[func]
    fn surface_radii(&self, seed: i64, radius: f64, dirs: PackedVector3Array) -> PackedFloat32Array {
        let density = density::shared(seed as i32, radius as f32);
        let mut out: Vec<f32> = Vec::with_capacity(dirs.len());
        for d in dirs.as_slice() {
            let len = d.length();
            let n = if len > 1e-6 { *d / len } else { *d };
            out.push(density.surface_radius(n.x, n.y, n.z));
        }
        PackedFloat32Array::from(out.as_slice())
    }

    /// Region (continent-cluster) landmark anchors — one per populated landmass,
    /// projected to the terrain surface in the planet's local frame. GDScript drops
    /// a distinct placeholder monument at each so different regions read apart.
    #[func]
    fn region_data(&self, seed: i64, radius: f64) -> PackedVector3Array {
        let density = density::shared(seed as i32, radius as f32);
        let pts: Vec<Vector3> = density
            .region_points()
            .iter()
            .map(|p| Vector3::new(p[0], p[1], p[2]))
            .collect();
        PackedVector3Array::from(pts.as_slice())
    }

    /// Drain ALL finished meshes in a single call. Returns an Array of
    /// Dictionaries, each = { id, positions, normals, indices, empty }. One lock
    /// + one FFI hop for the whole batch (vs a poll + a take-per-chunk round-trip
    /// every frame) — meaningful when hundreds of chunks stream in at once.
    #[func]
    fn take_all_ready(&self) -> VarArray {
        let drained: Vec<(i64, MeshData)> = {
            let mut map = pool().output.lock().unwrap();
            map.drain().collect()
        };
        let mut out = VarArray::new();
        for (id, m) in drained {
            let mut dict = mesh_to_dict(m);
            dict.set("id", id);
            out.push(&dict.to_variant());
        }
        out
    }
}

/// Marshal a finished mesh into a Godot dictionary
/// { positions, normals: PackedVector3Array, indices: PackedInt32Array, empty }.
/// `PackedArray::from(&[T])` is a single memcpy; the flat f32 triples are packed
/// into Vec<Vector3> in pure Rust first (no FFI), then handed over in one bulk
/// copy — vs the old per-element `arr[i] = …`, which cost one bounds-checked FFI
/// write per vertex (thousands per chunk on the main thread).
fn mesh_to_dict(m: MeshData) -> VarDictionary {
    let vcount = m.positions.len() / 3;
    let mut pv: Vec<Vector3> = Vec::with_capacity(vcount);
    let mut nv: Vec<Vector3> = Vec::with_capacity(vcount);
    for i in 0..vcount {
        pv.push(Vector3::new(
            m.positions[3 * i], m.positions[3 * i + 1], m.positions[3 * i + 2],
        ));
        nv.push(Vector3::new(
            m.normals[3 * i], m.normals[3 * i + 1], m.normals[3 * i + 2],
        ));
    }
    let mut dict = VarDictionary::new();
    dict.set("positions", PackedVector3Array::from(pv.as_slice()));
    dict.set("normals", PackedVector3Array::from(nv.as_slice()));
    dict.set("indices", PackedInt32Array::from(m.indices.as_slice()));
    dict.set("empty", m.indices.is_empty());
    if !m.collision_faces.is_empty() {
        let fcount = m.collision_faces.len() / 3;
        let mut cf: Vec<Vector3> = Vec::with_capacity(fcount);
        for i in 0..fcount {
            cf.push(Vector3::new(
                m.collision_faces[3 * i],
                m.collision_faces[3 * i + 1],
                m.collision_faces[3 * i + 2],
            ));
        }
        dict.set("collision_faces", PackedVector3Array::from(cf.as_slice()));
    }
    // Scatter transform buffers (12 floats / instance, MultiMesh layout). Rocks in
    // one buffer; foliage split into one buffer per type ("fol_0".."fol_8"). Only
    // present for near chunks that asked for scatter; empty ones are simply omitted.
    if !m.rock_xforms.is_empty() {
        dict.set("rock_xforms", PackedFloat32Array::from(m.rock_xforms.as_slice()));
    }
    // Per-vertex urban factor → vertex colour, INVERTED into R (R = 1 − urban, G/B/A
    // unused/1). The inversion makes the safe default win: a chunk with no colour array
    // gets COLOR = white (R = 1) ⇒ urban = 1 − R = 0, so the terrain shader only paints
    // urban ground where it's explicitly told to. Emitted only for chunks that actually
    // touch a settlement, so the wild majority carry no extra array.
    if m.urban.iter().any(|&u| u > 1e-4) {
        let mut cols: Vec<Color> = Vec::with_capacity(m.urban.len());
        for &u in &m.urban {
            cols.push(Color::from_rgba(1.0 - u, 0.0, 0.0, 1.0));
        }
        dict.set("colors", PackedColorArray::from(cols.as_slice()));
    }
    // Worker-built rock collision soup (flat f32 triples → Vector3 triangle soup),
    // present only for the closest-LOD chunks that requested it.
    if !m.rock_collision_faces.is_empty() {
        let fc = m.rock_collision_faces.len() / 3;
        let mut rc: Vec<Vector3> = Vec::with_capacity(fc);
        for i in 0..fc {
            rc.push(Vector3::new(
                m.rock_collision_faces[3 * i],
                m.rock_collision_faces[3 * i + 1],
                m.rock_collision_faces[3 * i + 2],
            ));
        }
        dict.set("rock_collision_faces", PackedVector3Array::from(rc.as_slice()));
    }
    for (i, f) in m.foliage_xforms.iter().enumerate() {
        if !f.is_empty() {
            dict.set(format!("fol_{}", i), PackedFloat32Array::from(f.as_slice()));
        }
    }
    dict
}
