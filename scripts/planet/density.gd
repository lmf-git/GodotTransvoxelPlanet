class_name DensityField
extends RefCounted

## Planetary signed-distance field — a thin delegator to the Rust mesher's
## density (`NativeTerrain.density_sample`). Positive = solid, negative = empty.
##
## The full noise composition (continents, ridges, biomes, caves, …) lives ONCE,
## in `rust/src/density.rs`. That's the field the mesher actually triangulates,
## so routing the player's altitude / surface-snap queries to the SAME function
## guarantees they agree with the visible terrain. Previously this script kept a
## hand-ported GDScript copy of the whole formula, which silently drifted from
## the Rust version and made altitude queries disagree with the mesh.
##
## Sampling is one FFI call; the only callers are player gravity/altitude and the
## Newton surface-snap (a handful of samples per physics frame), so the overhead
## is negligible. The bounds are constants, fetched once and cached.

var radius     : float = 24000.0   # overwritten by _init; matches main.gd's real scale
var world_seed : int   = 1337

var _native : Object
var _min_r  : float = 0.0
var _max_r  : float = 0.0


# `native` is the shared NativeTerrain instance (Planet passes its own). When it
# is null (extension failed to load — nothing meshes anyway) we fall back to a
# plain sphere so player queries don't crash.
func _init(planet_radius: float = 24000.0, seed_in: int = 1337, native: Object = null) -> void:
	radius = planet_radius
	world_seed = seed_in
	_native = native
	if _native != null:
		var b : Vector2 = _native.call("density_bounds", world_seed, radius)
		_min_r = b.x
		_max_r = b.y
	else:
		# Matches density.rs's max/min_surface_radius constants for the fallback
		# (no-erosion bounds: 361+1150+65+6+600+280+150 up, 779+480+420 down).
		_max_r = radius + 2612.0
		_min_r = radius - 1679.0


## Density at world-space point p. Positive = solid.
func sample(p: Vector3) -> float:
	if _native == null:
		return radius - p.length()   # bare sphere fallback
	return _native.call("density_sample", world_seed, radius, p)


## Strict upper-bound surface radius (chunk culling). Cached constant.
func max_surface_radius() -> float:
	return _max_r


## Strict lower-bound surface radius (deepest carve). Cached constant.
func min_surface_radius() -> float:
	return _min_r
