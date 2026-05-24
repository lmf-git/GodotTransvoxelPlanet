# Transvoxel Planetary Terrain — Godot 4.7 Test

A No Man's Sky / Star Citizen-style voxel planet built from scratch in pure GDScript.
Whole-planet smooth terrain with caves, ridged mountains, biomes, water oceans,
polar caps, an animated atmosphere, and a stationary sun the planet **orbits**
in real time (axial tilt drives a real day/night cycle and seasons).

## Run it

Open the folder in Godot 4.7 (Forward+). Press F5.

```
WASD          move forward / back / strafe
Space / Shift up / down (in flight)
Q / E         roll
Left Alt      boost (×6 speed)
F             toggle FLIGHT ↔ WALK
Tab           wireframe debug draw
Esc           release / recapture mouse
```

The HUD shows chunk count, triangle count, altitude, mode, and the current
day-of-year + time-of-day phases.

## Architecture

```
scripts/planet/
  density.gd           SDF: sphere + domain-warped fbm + ridged mountains + caves
  transvoxel_tables.gd Marching-cubes regular-cell lookup tables (public domain)
  chunk_mesher.gd      Worker-thread MC mesher; shared per-axis edge cache
  voxel_chunk.gd       Per-chunk Node3D — mesh + (optional) collision; safe
                       lifecycle via a RefCounted result holder polled by the
                       main thread (no `self.call_deferred` race on free)
  planet.gd            Octree LOD streaming in the planet's LOCAL frame, so
                       LOD still works correctly when the planet is orbiting
                       through world space
scripts/player/
  flight_player.gd     6-DOF CharacterBody3D, FLIGHT/WALK modes, third-person
                       SpringArm camera; parented to the planet system so it
                       travels with the planet
scripts/world/
  world.gd             Builds the solar system: fixed Star + orbiting+spinning
                       PlanetSystem (Planet + Atmosphere + Water); updates the
                       sun direction in atmosphere/water shaders each frame
shaders/
  terrain.gdshader     Object-space triplanar biomes — equator jungle, mid
                       grass/dirt, polar caps; snow line drops toward poles
                       and rises at the equator; rock on steep slopes
  atmosphere.gdshader  Inverted sphere, Rayleigh + Henyey-Greenstein Mie
  water.gdshader       Animated wave normals, Fresnel reflectance, sun specular
main.gd / main.tscn    Entry point + HUD
```

## Solar system

```
World (Node3D)
 ├── WorldEnvironment       (dark sky, ACES tonemap, glow)
 ├── Star (Node3D, fixed at world origin)
 │   ├── SunLight           (DirectionalLight3D, points at the planet)
 │   └── SunVisual          (unshaded glowing sphere)
 └── PlanetSystem (Node3D, ORBITS the star, SPINS on its axis)
     ├── Planet             (octree-streamed voxel terrain)
     ├── Atmosphere         (inverted-sphere shader)
     ├── Water              (sphere at sea level)
     └── Player             (re-parented here by main.gd)
```

Two motions drive the cycles:

* **Orbital motion** — `PlanetSystem` revolves around `Star` at
  `orbit_radius` once every `orbit_period_sec` (the "year").
* **Axial rotation** — `PlanetSystem` spins on its tilted axis once every
  `day_length_sec` (the "day").

Axial tilt (`axial_tilt_deg`, 23.5° by default) combined with the orbit drives
the seasons — the snow line moves with `polar_t` × `equator_t` in the terrain
shader, so a hemisphere tilted toward the sun sees its snow recede.

**Floating-point note:** at `orbit_radius` 60 km the world coordinates stay
well inside single-precision float comfort. For real AU-scale orbits you'd
want a floating-origin system; out of scope here.

## How LOD works

Every frame, `planet.gd` walks an octree rooted at coarse cells that tile the
planet's bounding cube **in the planet's LOCAL frame** (so the streaming still
works after the planet has orbited). The camera's world position is converted
to local coordinates first.

For each node, if `distance(camera_local, node_center)` is below
`node_size * lod_factor` (default 2.4) and the node still has finer detail
left (`lod > 0`), the node subdivides — children are visited instead.
Otherwise the node becomes a leaf and owns a `VoxelChunk` meshed at that
resolution.

Nodes whose bounding sphere never intersects the planet shell
`[min_surface_radius, max_surface_radius]` are pruned early.

Stale chunks (not visited for ~30 frames) are freed. The grace period lets
subdivided children finish meshing on background threads before the parent
disappears, hiding the "hole" pop-through.

## Marching cubes + crack-free LOD via boundary density resampling

This implementation handles the **regular-cell** half of Eric Lengyel's
Transvoxel algorithm — cell-by-cell marching cubes with a per-axis edge cache
for shared vertices and smooth shading. **There are no skirts.** LOD-seam
cracks are eliminated by a Transvoxel-equivalent technique:
**boundary density resampling**.

When a chunk has a *coarser* neighbour on one of its 6 faces, the chunk's
boundary samples on that face are replaced by linear / bilinear interpolation
of the "coarse-aligned" sample positions (every-other corner in fine chunk
coordinates). The marching cubes pass then sees a boundary density that's
identical to what the coarse neighbour sees, so the iso-surface lines up
exactly — no crack, no hidden geometry.

Lengyel's transition-cell tables achieve the same end result with ~12 KB of
hand-crafted lookup data; resampling the density grid produces the same
outcome with about 60 lines of code and no constants. The trade-off: a single
fine boundary cell becomes a slightly distorted approximation of the coarse
neighbour's surface on that face, but the visible result is seamless.

**Re-mesh on neighbour-LOD change.** Each frame `planet.gd` computes a 6-bit
"coarser-mask" per leaf chunk by looking up the same-LOD vs. coarser-LOD
neighbour in the chunk dictionary. When a chunk's mask changes (camera moves,
LOD frontier shifts), the chunk is re-meshed with the new mask, throttled by
`max_new_chunks_per_tick`. The previous mesh stays live until the new one is
ready, so transitions never show a hole.

## Threading model

Each chunk's density sampling + MC pass runs as a `WorkerThreadPool` task.
The worker **does not reference `self`** — it only writes to a shared
`_MeshResultHolder` (a `RefCounted`). The chunk polls the holder on
`_process`. This eliminates the previous crash where the worker would call
`self.call_deferred(...)` on a chunk that had been freed mid-flight.

The holder lives as long as the worker's closure holds it. When the chunk is
freed, our reference drops; the worker still has its reference via the
closure, finishes safely, the holder is GC'd. No dangling pointers.

`max_new_chunks_per_tick` (default 4) bounds the generation budget per frame
so the main thread never stalls.

## Tuning knobs

On `world` (so `get_node("World").xxx = ...`):

* `orbit_radius` — distance between sun and planet. Keep ≤ 100 km for
  comfort; beyond that, float precision starts to bite without a floating
  origin.
* `orbit_period_sec` — seconds per "year".
* `day_length_sec` — seconds per axial rotation.
* `axial_tilt_deg` — angle between spin axis and orbital normal.
* `sea_level_offset` — sea level relative to `planet_radius` (negative
  means oceans fill depressions below the mean surface).
* `sun_radius`, `sun_color`, `sun_energy` — sun visual + lighting.

On `world.planet` (`get_node("World/PlanetSystem/Planet").xxx`):

* `base_chunk_size` — smallest chunk side, world units. 32 default.
* `max_lod` — root depth; root size = `base_chunk_size * 2^max_lod`.
* `voxel_resolution` — cells per axis per chunk. 16 default.
* `lod_factor` — subdivide aggression. Default 2.4.
* `collision_lod_max` — build collision for chunks at this LOD or below.
* `stale_tolerance` — frames a chunk can be unvisited before being freed.

On `world.terrain_mat` (`set_shader_parameter`):

* `polar_cap_latitude` — `|dot(radial, axis)|` above which snow dominates.
* `snow_altitude`, `snow_fade` — base mid-latitude snow line.
* `equator_warmth` — how much the snow line is raised at the equator.

## Optimisations and addressed limitations

* **Crack-free LOD via boundary density resampling** — see the "Marching
  cubes + crack-free LOD" section above. No skirts, no transition-cell
  tables, no visible seams.
* **Floating origin** — `world.gd` tracks a 64-bit-double origin offset and
  recentres the scene when the camera drifts past
  `floating_origin_threshold`. Math is done in doubles and only collapsed
  to a Vector3 (32-bit components) AFTER subtracting the offset, so AU-scale
  orbits keep full chunk-coordinate precision.
* **Underwater rendering** — water shader is now `cull_disabled` so the
  surface is visible from below. When the camera drops below sea level,
  `world.gd` flips the WorldEnvironment fog to a deep-blue exponential tint
  and dampens saturation. The toggle only fires on state change, not every
  frame.
* **Scatter (rocks)** — `scripts/world/scatter.gd` builds a deterministic
  rock transform list from a chunk's MC mesh (filtered by slope and
  altitude), and each chunk owns a `MultiMeshInstance3D` pointing at the
  single shared rock mesh + material. Active only on chunks at LOD ≤
  `scatter_lod_max` (default 1) to keep the high-LOD distance cheap.
* **Collision-shape pooling** — each chunk reuses its existing
  `ConcavePolygonShape3D` across re-meshes via `set_faces()`, instead of
  creating a fresh shape resource each time. The physics server sees the
  shape mutate in place.

## Remaining trade-offs

* **Scatter is rocks only** for now — grass/foliage would be a separate
  multi-mesh class with an animated wave shader. Same hashing approach.
* **Skirts code is dormant** in `chunk_mesher.gd` — kept for reference
  behind a `skirts=true` input flag (default off). Boundary resampling
  superseded it; toggle on only if you want to A/B compare.
