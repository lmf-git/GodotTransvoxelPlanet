use godot::prelude::*;
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex, OnceLock};

mod density;
mod mesher;
mod noise;
mod tables;

use density::PlanetDensity;
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
}

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
        let density = PlanetDensity::new(job.seed, job.radius);
        let mesh = mesher::build(
            job.origin, job.size, job.resolution, job.coarser_mask, job.pc,
            job.want_collision, &density,
        );
        shared.output.lock().unwrap().insert(job.id, mesh);
    }
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

    /// Diagnostic: sample the surface radius over a lat/long grid (Newton-solve
    /// the iso-surface along each direction) and return (min, mean, max). Lets
    /// GDScript compare against the sea sphere radius to set the sea level
    /// exactly instead of guessing the continental bias.
    #[func]
    fn surface_radius_stats(&self, seed: i64, radius: f64) -> Vector3 {
        let density = PlanetDensity::new(seed as i32, radius as f32);
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
        let density = PlanetDensity::new(seed as i32, radius as f32);
        density.sample(p.x, p.y, p.z) as f64
    }

    /// (min_surface_radius, max_surface_radius) for the given planet — the strict
    /// bounds the octree uses for chunk culling. Returned as a Vector2 so the
    /// GDScript side can cache both from one call.
    #[func]
    fn density_bounds(&self, seed: i64, radius: f64) -> Vector2 {
        let density = PlanetDensity::new(seed as i32, radius as f32);
        Vector2::new(density.min_surface_radius(), density.max_surface_radius())
    }

    /// Deterministic placeholder settlements for this body — the same city pads
    /// and road corridors that `PlanetDensity` flattens into the terrain, handed
    /// to GDScript so it can drop building/road visuals exactly on the flat ground.
    /// Returns { centers: PackedVector3Array (local-frame pad centres),
    /// roads: PackedVector3Array (endpoint pairs a0,b0,a1,b1,…), pad_radius }.
    #[func]
    fn settlement_data(&self, seed: i64, radius: f64) -> VarDictionary {
        let density = PlanetDensity::new(seed as i32, radius as f32);
        let mut centers: Vec<Vector3> = Vec::new();
        for c in density.cities() {
            centers.push(Vector3::new(
                c.dir[0] * c.target_r,
                c.dir[1] * c.target_r,
                c.dir[2] * c.target_r,
            ));
        }
        // Road centrelines sampled at terrain height: `road_steps` points per
        // road, all roads concatenated. GDScript slices by `road_steps` and lays a
        // ribbon along each polyline so the road conforms to the ground it was
        // carved into (instead of a straight pad-to-pad ramp floating over hills).
        let road_steps: usize = 24;
        let pts = density.road_polylines(road_steps);
        let road_points: Vec<Vector3> =
            pts.iter().map(|p| Vector3::new(p[0], p[1], p[2])).collect();

        let mut dict = VarDictionary::new();
        dict.set("centers", PackedVector3Array::from(centers.as_slice()));
        dict.set("road_points", PackedVector3Array::from(road_points.as_slice()));
        dict.set("road_steps", (road_steps + 1) as i64);
        dict.set("pad_radius", density.city_pad_radius() as f64);
        dict
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
    dict
}
