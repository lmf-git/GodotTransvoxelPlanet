use godot::prelude::*;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

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
}

struct Shared {
    input: Mutex<VecDeque<Job>>,
    input_cv: Condvar,
    output: Mutex<HashMap<i64, MeshData>>,
    shutdown: AtomicBool,
}

// Pure-Rust worker. Never touches the Godot API, so running it off the main
// thread is sound (the gap-prone part was calling gdext from a worker — here
// only submit/poll/take run on the main thread).
fn worker_loop(shared: Arc<Shared>) {
    loop {
        let job = {
            let mut q = shared.input.lock().unwrap();
            while q.is_empty() && !shared.shutdown.load(Ordering::Relaxed) {
                q = shared.input_cv.wait(q).unwrap();
            }
            if shared.shutdown.load(Ordering::Relaxed) {
                return;
            }
            q.pop_front().unwrap()
        };
        let density = PlanetDensity::new(job.seed, job.radius);
        let mesh = mesher::build(
            job.origin, job.size, job.resolution, job.coarser_mask, job.pc, &density,
        );
        shared.output.lock().unwrap().insert(job.id, mesh);
    }
}

/// Native voxel chunk generator. Hand-rolled density + marching-cubes mesher
/// (no algorithm crates), meshed on an internal thread pool. GDScript submits
/// jobs and polls/takes finished meshes — all Godot interaction stays on the
/// main thread.
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct NativeTerrain {
    base: Base<RefCounted>,
    shared: Arc<Shared>,
    workers: Vec<JoinHandle<()>>,
}

#[godot_api]
impl IRefCounted for NativeTerrain {
    fn init(base: Base<RefCounted>) -> Self {
        let shared = Arc::new(Shared {
            input: Mutex::new(VecDeque::new()),
            input_cv: Condvar::new(),
            output: Mutex::new(HashMap::new()),
            shutdown: AtomicBool::new(false),
        });
        let n = std::thread::available_parallelism()
            .map(|x| x.get())
            .unwrap_or(4)
            .max(1);
        let mut workers = Vec::with_capacity(n);
        for _ in 0..n {
            let s = shared.clone();
            workers.push(std::thread::spawn(move || worker_loop(s)));
        }
        Self { base, shared, workers }
    }
}

impl Drop for NativeTerrain {
    fn drop(&mut self) {
        self.shared.shutdown.store(true, Ordering::Relaxed);
        self.shared.input_cv.notify_all();
        for w in self.workers.drain(..) {
            let _ = w.join();
        }
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
        };
        self.shared.input.lock().unwrap().push_back(job);
        self.shared.input_cv.notify_one();
    }

    /// Drain ALL finished meshes in a single call. Returns an Array of
    /// Dictionaries, each = the `take_result` payload plus an `"id"` key. This
    /// replaces the per-chunk poll_ready_ids → take_result(id) round-trip (two
    /// FFI hops + two lock acquisitions per chunk, every frame) with one lock
    /// and one FFI hop for the whole batch — meaningful when hundreds of chunks
    /// stream in at once. `poll_ready_ids`/`take_result` are kept for callers
    /// that still want the granular path.
    #[func]
    fn take_all_ready(&self) -> VarArray {
        let drained: Vec<(i64, MeshData)> = {
            let mut map = self.shared.output.lock().unwrap();
            map.drain().collect()
        };
        let mut out = VarArray::new();
        for (id, m) in drained {
            let mut dict = VarDictionary::new();
            dict.set("id", id);
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
            dict.set("positions", PackedVector3Array::from(pv.as_slice()));
            dict.set("normals", PackedVector3Array::from(nv.as_slice()));
            dict.set("indices", PackedInt32Array::from(m.indices.as_slice()));
            dict.set("empty", m.indices.is_empty());
            out.push(&dict.to_variant());
        }
        out
    }

    /// Instance ids of chunks whose mesh is ready. Call `take_result(id)` for
    /// each to retrieve and clear it.
    #[func]
    fn poll_ready_ids(&self) -> PackedInt64Array {
        let map = self.shared.output.lock().unwrap();
        let mut arr = PackedInt64Array::new();
        arr.resize(map.len());
        for (i, k) in map.keys().enumerate() {
            arr[i] = *k;
        }
        arr
    }

    /// Retrieve + remove a finished mesh by id. Returns
    /// { positions, normals: PackedVector3Array, indices: PackedInt32Array,
    /// empty: bool }. `empty=true` if the id wasn't ready (shouldn't happen if
    /// taken right after poll_ready_ids).
    #[func]
    fn take_result(&self, id: i64) -> VarDictionary {
        let mesh = self.shared.output.lock().unwrap().remove(&id);
        let mut dict = VarDictionary::new();
        match mesh {
            Some(m) => {
                // Marshal in bulk. `PackedArray::from(&[T])` is a single memcpy;
                // the old per-element `arr[i] = …` did one bounds-checked FFI
                // write per vertex — thousands of FFI hops per chunk on the main
                // thread, which is what starved the framerate. We pack the flat
                // f32 triples into Vec<Vector3> in pure Rust first (no FFI), then
                // hand the whole slice over once.
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
                dict.set("positions", PackedVector3Array::from(pv.as_slice()));
                dict.set("normals", PackedVector3Array::from(nv.as_slice()));
                dict.set("indices", PackedInt32Array::from(m.indices.as_slice()));
                dict.set("empty", m.indices.is_empty());
            }
            None => {
                dict.set("empty", true);
            }
        }
        dict
    }
}
