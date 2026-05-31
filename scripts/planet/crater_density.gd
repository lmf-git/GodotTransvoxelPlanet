class_name CraterDensity
extends RefCounted

## Moon-like signed-distance field: spherical body with deterministic impact
## craters and a thin layer of rolling fbm dust. Same interface as
## `DensityField` (sample, max_surface_radius, min_surface_radius) so it
## plugs into Planet via `Planet.set_density()`.
##
## Crater profile (per impact, centered at unit-vector C on the sphere):
##                ┌── ejecta rim (slight bump)
##   surface ────┤   ┌── floor (depressed)
##               │   │
##                ──┐ ┌──
##                  └─┘
##                bowl
##
## We sum contributions from N crater seeds. Each seed is placed at a random
## direction on the unit sphere with a random radius drawn from a power-law
## distribution (lots of small craters, a few huge ones). The depth/rim
## profile uses smoothstep so it stays C1-continuous (no mesh creases).

const MAX_CRATER_DEPTH : float = 220.0   # tallest possible rim → deepest possible floor
const DUST_AMP         : float = 28.0    # surface "dust" / micro-relief

var radius     : float = 1100.0
var world_seed : int   = 42
var crater_count : int = 220        # how many craters we evaluate per sample
var _craters     : Array = []        # PackedFloat32Array-like: [cx, cy, cz, radius, depth, rim_height, ...] flat

var _dust  : FastNoiseLite
var _wobble: FastNoiseLite           # low-frequency body deformation (slight oblateness etc.)


func _init(p_radius: float = 1100.0, p_seed: int = 42, p_crater_count: int = 220) -> void:
	radius = p_radius
	world_seed = p_seed
	crater_count = p_crater_count
	_build_noises()
	_seed_craters()


func _build_noises() -> void:
	_dust = FastNoiseLite.new()
	_dust.seed = world_seed
	_dust.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_dust.fractal_type = FastNoiseLite.FRACTAL_FBM
	_dust.frequency = 0.0035
	_dust.fractal_octaves = 5
	_dust.fractal_lacunarity = 2.1
	_dust.fractal_gain = 0.5

	_wobble = FastNoiseLite.new()
	_wobble.seed = world_seed + 17
	_wobble.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_wobble.frequency = 0.0006
	_wobble.fractal_octaves = 3


# Power-law radius distribution: r = r_min * (r_max / r_min) ^ u
# where u ∈ [0, 1] and u→0 favours small craters.
func _seed_craters() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed + 9001
	_craters.clear()
	var r_min := radius * 0.005      # ≈ 5 m for a 1000 m moon
	var r_max := radius * 0.32       # huge basins
	for _i in crater_count:
		# Uniform-on-sphere direction.
		var z := rng.randf_range(-1.0, 1.0)
		var phi := rng.randf_range(0.0, TAU)
		var sxy := sqrt(max(1.0 - z * z, 0.0))
		var dir := Vector3(sxy * cos(phi), z, sxy * sin(phi))

		var u := rng.randf()
		var cr := r_min * pow(r_max / r_min, pow(u, 3.5))  # bias toward small
		# Deeper craters for larger impacts.
		var depth := minf(cr * 0.22, MAX_CRATER_DEPTH)
		var rim   := depth * 0.30
		_craters.append(dir.x); _craters.append(dir.y); _craters.append(dir.z)
		_craters.append(cr); _craters.append(depth); _craters.append(rim)


## Density at p. Positive = solid moon rock, negative = empty.
func sample(p: Vector3) -> float:
	var r := p.length()
	if r < 0.0001:
		return radius
	var n := p / r

	# Base displaced surface: slight oblate wobble + dust noise.
	var wobble := _wobble.get_noise_3dv(n * 100.0) * 18.0
	var dust := _dust.get_noise_3dv(p) * DUST_AMP

	var surface_offset := wobble + dust

	# Crater contributions. Each crater's signed effect:
	#   depth*falloff(x) is subtracted (dig the bowl)
	#   rim*rim_profile(x) is added  (raise the rim around the edge)
	# where x = angular distance / crater_angular_radius (∈ [0, ~1.5]).
	# `_craters` holds exactly `crater_count` craters × 6 floats (see _seed_craters),
	# so the count is already known — no need to re-derive it by integer-dividing
	# the flat array length on every sample (this runs millions of times while
	# meshing). Using crater_count directly also drops the integer-division warning.
	var stride := 6
	var i := 0
	for _ci in crater_count:
		var cx : float = _craters[i + 0]
		var cy : float = _craters[i + 1]
		var cz : float = _craters[i + 2]
		var cr : float = _craters[i + 3]    # crater radius (world units along great circle)
		var depth : float = _craters[i + 4]
		var rim_h : float = _craters[i + 5]
		i += stride
		# Dot product = cos(angle). Angular distance = acos(dot). For small
		# angles we can use 1 - dot as a cheap distance proxy; combined with
		# the cr scale we get a sane normalised distance.
		var d_cos := n.x * cx + n.y * cy + n.z * cz
		if d_cos < 0.4:
			# Crater is on the far side; cannot affect this point.
			continue
		var ang := acos(clampf(d_cos, -1.0, 1.0))   # angular distance, radians
		var arc_dist := ang * radius                # world-units distance on the sphere
		var x := arc_dist / cr                      # 0 at centre, 1 at crater edge

		# Bowl: depressed inside (x < 1), zero outside.
		var bowl_t := 1.0 - smoothstep(0.0, 1.0, x)   # 1 at centre, 0 at edge
		# Steeper near the edge (eases at the centre).
		bowl_t = bowl_t * bowl_t
		surface_offset -= depth * bowl_t

		# Rim: a thin bump centered just outside the bowl.
		if x > 0.9 and x < 1.6:
			var rim_t := 1.0 - absf((x - 1.15) / 0.25)
			rim_t = clampf(rim_t, 0.0, 1.0)
			surface_offset += rim_h * smoothstep(0.0, 1.0, rim_t)

	var surface_r := radius + surface_offset
	return surface_r - r


func max_surface_radius() -> float:
	# Worst case: rim_h max ≈ 0.30 * MAX_CRATER_DEPTH ≈ 66, plus wobble (18) +
	# dust (28). Round up generously.
	return radius + MAX_CRATER_DEPTH * 0.4 + 80.0


func min_surface_radius() -> float:
	# Worst case: a big crater depth = MAX_CRATER_DEPTH = 220, plus wobble
	# and dust on the bottom.
	return radius - MAX_CRATER_DEPTH - 80.0
