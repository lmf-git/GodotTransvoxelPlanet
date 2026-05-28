class_name DensityField
extends RefCounted

## Planetary signed-distance field.
## Positive = solid rock, negative = empty space, zero = isosurface.
##
## Composition:
##   1. Base sphere SDF (radius - |p|)
##   2. Continental height (low-frequency noise on the unit sphere)
##   3. Mountain ridges (ridged multifractal, masked by continents)
##   4. Surface detail (high-frequency fbm)
##   5. Cave network (subtractive 3D worley-ish fbm below the surface)
##
## All `sample()` calls are pure functions of (p, seed) so they can run on any
## thread without locking. FastNoiseLite is thread-safe for reads in Godot 4.

const PLANET_RADIUS_DEFAULT : float = 4000.0
# Scaled down ~3.5× for the 24 km planet — keeps mountains visible from a
# distance without dominating the horizon. Both the Rust mesher and this
# script MUST agree (Rust meshes the surface; this script is what the
# player's altitude / surface-snap queries hit), so update density.rs in
# lockstep with any change here.
const MAX_TERRAIN_HEIGHT    : float = 170.0   # tallest possible mountain peak above mean radius
const MAX_SPIRE_HEIGHT      : float = 120.0   # how tall the dramatic NMS-style pinnacles can get
const MAX_PLATEAU_RISE      : float = 65.0    # how high a mesa top can sit above the local base
const MAX_CANYON_DEPTH      : float = 75.0    # how deep a slot canyon can cut
const CAVE_BOTTOM_DEPTH     : float = 110.0
const SEA_LEVEL_OFFSET      : float = -12.0   # terrain "0" sits this far above mean sea level

var radius          : float = PLANET_RADIUS_DEFAULT
var world_seed      : int   = 1337
var enable_caves    : bool  = true

var _n_continent : FastNoiseLite
var _n_ridge     : FastNoiseLite
var _n_detail    : FastNoiseLite
var _n_warp      : FastNoiseLite
var _n_cave      : FastNoiseLite
# "Uber" turbulence — chaotic mid-frequency layer that breaks the regularity
# of the ridge/detail combo so mountains aren't all the same shape. Domain-
# warped by a second noise so its features curve and braid instead of running
# in straight bands.
var _n_uber      : FastNoiseLite
var _n_uber_warp : FastNoiseLite
# Extra "alien" layers driving NMS-style regional drama:
#   _n_spire    — high-freq ridged noise that turns into thin pinnacles in
#                 the spire-belt regions.
#   _n_terrace  — mid-freq fbm quantised into plateau steps for mesa biomes.
#   _n_canyon   — ridged warp that cuts narrow slot-canyon grooves into the
#                 surface (subtracted from height).
#   _n_biome    — picks WHICH alien mode (spires vs plateaus vs canyons vs
#                 nothing) dominates in any given region of the planet.
var _n_spire    : FastNoiseLite
var _n_terrace  : FastNoiseLite
var _n_canyon   : FastNoiseLite
var _n_biome    : FastNoiseLite


func _init(planet_radius: float = PLANET_RADIUS_DEFAULT, seed_in: int = 1337) -> void:
	radius = planet_radius
	world_seed = seed_in
	_build_noises()


func _build_noises() -> void:
	_n_continent = FastNoiseLite.new()
	_n_continent.seed = world_seed
	_n_continent.noise_type = FastNoiseLite.TYPE_PERLIN
	_n_continent.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_continent.frequency = 0.00022          # slightly higher → smaller, more numerous continents
	_n_continent.fractal_octaves = 6
	_n_continent.fractal_lacunarity = 2.1
	_n_continent.fractal_gain = 0.55

	_n_ridge = FastNoiseLite.new()
	_n_ridge.seed = world_seed + 17
	_n_ridge.noise_type = FastNoiseLite.TYPE_PERLIN
	_n_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_n_ridge.frequency = 0.00085              # sharper mountain ranges
	_n_ridge.fractal_octaves = 7
	_n_ridge.fractal_lacunarity = 2.2
	_n_ridge.fractal_gain = 0.58

	_n_detail = FastNoiseLite.new()
	_n_detail.seed = world_seed + 41
	_n_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	# Wavelength ~600 m. Anything finer aliases at coarse LODs (root voxel
	# ≈ 256 m), which (a) explodes the tri count when viewed from space
	# and (b) makes every distant chunk read as "rocky" to the biome
	# shader because the aliased normals all look like cliff faces.
	_n_detail.frequency = 0.0017
	_n_detail.fractal_octaves = 2
	_n_detail.fractal_lacunarity = 2.0
	_n_detail.fractal_gain = 0.5

	_n_warp = FastNoiseLite.new()
	_n_warp.seed = world_seed + 113
	_n_warp.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_warp.frequency = 0.00035
	_n_warp.fractal_octaves = 2

	_n_cave = FastNoiseLite.new()
	_n_cave.seed = world_seed + 257
	_n_cave.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_cave.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_cave.frequency = 0.0055
	_n_cave.fractal_octaves = 3
	_n_cave.fractal_lacunarity = 2.1
	_n_cave.fractal_gain = 0.55

	# "Uber" is a low-frequency REGION mask, not another height layer. It
	# decides what kind of place this is — flat steppe, rolling hills, dramatic
	# mountain belt, plateau. Keeping it low-frequency (huge features) avoids
	# aliasing at coarse LODs and stops the surface from feeling uniformly
	# noisy across the whole planet.
	_n_uber = FastNoiseLite.new()
	_n_uber.seed = world_seed + 619
	_n_uber.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_uber.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_uber.frequency = 0.00045
	_n_uber.fractal_octaves = 3
	_n_uber.fractal_lacunarity = 2.0
	_n_uber.fractal_gain = 0.5

	_n_uber_warp = FastNoiseLite.new()
	_n_uber_warp.seed = world_seed + 733
	_n_uber_warp.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_uber_warp.frequency = 0.00028
	_n_uber_warp.fractal_octaves = 2

	# ── "Alien" / NMS-style regional layers ────────────────────────────────
	# These all live at LOW frequencies — high-freq features alias badly at
	# coarse LODs (different chunks resolve them very differently → seams
	# and wildly different look on adjacent LODs), and sharp gradients make
	# everything register as "cliff slope" to the biome shader, blanket-
	# coating the surface in rock. We keep features BIG and smooth.
	_n_spire = FastNoiseLite.new()
	_n_spire.seed = world_seed + 829
	_n_spire.noise_type = FastNoiseLite.TYPE_PERLIN
	_n_spire.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_n_spire.frequency = 0.0011        # wavelength ≈ 900 m — big rock buttes, not needles
	_n_spire.fractal_octaves = 3
	_n_spire.fractal_lacunarity = 2.1
	_n_spire.fractal_gain = 0.55

	_n_terrace = FastNoiseLite.new()
	_n_terrace.seed = world_seed + 911
	_n_terrace.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_terrace.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_terrace.frequency = 0.0009
	_n_terrace.fractal_octaves = 3
	_n_terrace.fractal_lacunarity = 2.0
	_n_terrace.fractal_gain = 0.5

	_n_canyon = FastNoiseLite.new()
	_n_canyon.seed = world_seed + 977
	_n_canyon.noise_type = FastNoiseLite.TYPE_PERLIN
	_n_canyon.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_n_canyon.frequency = 0.0008
	_n_canyon.fractal_octaves = 3
	_n_canyon.fractal_lacunarity = 2.0
	_n_canyon.fractal_gain = 0.5

	# Biome-mode picker — slow noise that decides which alien layer (spires
	# vs. plateaus vs. canyons) is active in each planetary region.
	_n_biome = FastNoiseLite.new()
	_n_biome.seed = world_seed + 1031
	_n_biome.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_biome.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_biome.frequency = 0.00018
	_n_biome.fractal_octaves = 3
	_n_biome.fractal_lacunarity = 2.0
	_n_biome.fractal_gain = 0.5


## Density at world-space point p. Positive = solid.
func sample(p: Vector3) -> float:
	var r := p.length()
	if r < 0.0001:
		return radius  # singular point at planet center is fully solid

	# Domain-warp the look-up direction so continents have organic shapes.
	var n := p / r
	var w := _n_warp.get_noise_3dv(p) * 240.0
	var ps := p + n * w  # warp along radial — keeps the field roughly radial-symmetric

	# Continental shelf: broad land vs ocean. We push the bias slightly
	# NEGATIVE rather than the small positive bias we used to have — the
	# added regional layers (ridge, hills, spires, plateaus) all contribute
	# positive height once they're masked in, which dragged the mean terrain
	# altitude above sea level globally and hid the oceans. A -0.12 bias
	# brings the mean back below sea level so water actually rises above the
	# terrain in continent-noise minima.
	var continent := _n_continent.get_noise_3dv(ps)        # [-1, 1]
	# Push the mean continental height modestly BELOW sea level so ocean basins
	# form (water sphere sits at planet_radius + sea_level_offset = 12 m below
	# mean radius) without drowning the whole planet. Combined with mountains
	# now being a rarer biome (less global positive height), low continents
	# flood into seas while the highlands stay dry land.
	continent = continent * 1.1 - 0.15

	# Ridges only over land — mountains rise from the continents.
	var land_mask := smoothstep(-0.05, 0.35, continent)

	# Regional mountain mask. Domain-warped low-frequency noise picks out big
	# mountain BELTS instead of letting ridges march evenly over every
	# continent. `mountain_belt` in [0, 1] — 0 = flat steppe / hills, 1 = full
	# dramatic mountains. The smoothstep covers a wide enough range to make
	# whole continents feel mountainous rather than restricting it to a few
	# rare bands.
	var uber_warp_v := Vector3(
		_n_uber_warp.get_noise_3d(p.x, p.y, p.z),
		_n_uber_warp.get_noise_3d(p.x + 131.0, p.y - 47.0, p.z + 19.0),
		_n_uber_warp.get_noise_3d(p.x - 73.0, p.y + 11.0, p.z - 233.0)) * 280.0
	var region := _n_uber.get_noise_3dv(p + uber_warp_v)   # [-1, 1]
	# Mountains are now a MINORITY biome, not ~half the land. Raising the
	# smoothstep window means only the strongest regional peaks (region > ~0.45)
	# read as full mountains; everything else stays gentle. This is the main
	# lever against "the whole near side is steep grey rock" — most terrain is
	# now rolling hills / plains where grass + latitude biomes can show.
	var mountain_belt := smoothstep(0.10, 0.50, region)
	# Inverse mask — calm rolling hills cover the wide middle band of `region`.
	var hill_belt := 1.0 - smoothstep(-0.30, 0.25, region)

	var ridge := absf(_n_ridge.get_noise_3dv(ps))          # [0, 1]
	ridge = 1.0 - ridge
	ridge = pow(ridge, 2.8)
	ridge *= land_mask * mountain_belt

	# Rolling hills — broad warp-based undulation, active in non-mountain land.
	# Uses the SAME uber field shifted (cheaper than another FastNoiseLite).
	var hills := _n_uber.get_noise_3d(p.x * 2.7 + 511.0, p.y * 2.7 - 219.0, p.z * 2.7 + 83.0)
	hills *= land_mask * hill_belt

	# Fine detail blends in at all altitudes — but heavily attenuated. High-
	# amplitude detail noise is what makes EVERY vertex register as a "steep
	# slope" to the biome shader (gradient near 1 everywhere), painting the
	# whole planet rock-grey. ±10 m at this wavelength leaves the surface
	# crinkled-not-jagged.
	var detail := _n_detail.get_noise_3dv(p)               # [-1, 1]

	# ── Alien / NMS-style regional layers ──────────────────────────────────
	# `_n_biome` picks ONE alien mode per region. The three masks are
	# disjoint by construction — each band of biome lights up exactly one of
	# (spire | plateau | canyon) and the rest of the surface stays plain.
	# Land-gating keeps spires from growing out of the ocean.
	var biome := _n_biome.get_noise_3dv(p + uber_warp_v * 1.7)   # [-1, 1]
	# Spires are the single rockiest feature (steep buttes → cliff normals).
	# Keep them a rare, special-place biome rather than a common one.
	var spire_mask   := smoothstep(0.55, 0.74, biome) * land_mask
	var plateau_mask := smoothstep(-0.05, 0.15, biome) * (1.0 - smoothstep(0.30, 0.45, biome)) * land_mask
	var canyon_mask  := (1.0 - smoothstep(-0.45, -0.25, biome)) * land_mask

	# Spires: ridged noise → SOFTLY sharpened so crests turn into broad rock
	# buttes rather than razor pinnacles. A high pow() exponent makes the
	# gradient near each crest near-vertical, which (a) blows up the biome
	# slope check (everything reads "cliff" → rock) and (b) inflates the
	# triangle count when LOD-sampled. pow ~3 keeps the buttes shaped but
	# their flanks gentle enough to grow grass.
	var spire_raw := absf(_n_spire.get_noise_3dv(p))         # [0, 1]
	var spire := pow(clampf(1.0 - spire_raw, 0.0, 1.0), 3.0) # [0, 1]
	spire *= spire_mask

	# Plateaus: smooth fbm, quantised into 3 tiers (was 5 — fewer cliff
	# edges means more visible flat tops). The smoothstep on the fractional
	# part is also widened so each cliff fades over a fatter band — that's
	# what lets the biome shader see "flat" on top of each mesa instead of
	# reading every plateau as one continuous cliff face.
	var terr_raw := _n_terrace.get_noise_3dv(p) * 0.5 + 0.5  # [0, 1]
	var terr_tiers := 3.0
	var terr_scaled := terr_raw * terr_tiers
	var terr_step := floorf(terr_scaled)
	var terr_frac := terr_scaled - terr_step
	var terr_smoothed := terr_step + smoothstep(0.30, 0.70, terr_frac)
	var plateau := (terr_smoothed / terr_tiers) * plateau_mask

	# Canyons: gentle pow → broader cuts with shallower walls. Same logic as
	# spires: sharp canyon walls = rocky everywhere.
	var canyon_raw := absf(_n_canyon.get_noise_3dv(ps))      # [0, 1]
	var canyon := pow(clampf(1.0 - canyon_raw, 0.0, 1.0), 2.0) * canyon_mask

	# Height contributions:
	#   continent : ±260 — valleys + uplift (now with a negative bias)
	#   ridge     :  0..MAX_TERRAIN_HEIGHT — peaks in mountain belts
	#   hills     : ±50  — rolling hills in calm regions
	#   detail    : ±5   — fine variation, kept tiny so slopes stay flat
	#   spire     :  0..MAX_SPIRE_HEIGHT — buttes in alien spire belts
	#   plateau   :  0..MAX_PLATEAU_RISE — mesa decks
	#   canyon    :  0..MAX_CANYON_DEPTH — subtracted to dig slot canyons
	# Max additive ≈ 260 + 600 + 50 + 5 + 420 + 220 = 1555 m.
	var height := (
		continent * 75.0
		+ ridge * MAX_TERRAIN_HEIGHT
		+ hills * 14.0
		+ detail * 1.5
		+ spire * MAX_SPIRE_HEIGHT
		+ plateau * MAX_PLATEAU_RISE
		- canyon * MAX_CANYON_DEPTH
	)

	var surface_r := radius + height
	# Distance from p to the displaced surface (positive inside the planet).
	var d := surface_r - r

	# Caves: only carve below the surface and above the deep core.
	if enable_caves and d > 8.0 and d < CAVE_BOTTOM_DEPTH:
		var cave_v := _n_cave.get_noise_3dv(p)  # [-1, 1]
		# Stretch caves into tunnel-like ribbons with a second noise lookup at offset.
		var cave_v2 := _n_cave.get_noise_3d(p.x * 1.7 + 91.0, p.y * 0.6 - 13.0, p.z * 1.7 + 47.0)
		var tunnel := absf(cave_v) + absf(cave_v2) * 0.7
		# When `tunnel` is small (noise crosses zero), carve.
		var carve_amount := smoothstep(0.34, 0.12, tunnel) * 28.0
		# Taper near the surface and core so caves don't break the crust or core.
		var depth_fade := smoothstep(8.0, 32.0, d) * smoothstep(CAVE_BOTTOM_DEPTH, CAVE_BOTTOM_DEPTH - 80.0, d)
		d -= carve_amount * depth_fade

	return d


## Approximate surface gradient (for normals) via central differences.
## Used when MC's interpolated normals look poor at low LOD.
func gradient(p: Vector3, h: float = 1.0) -> Vector3:
	var dx := sample(p + Vector3(h, 0, 0)) - sample(p - Vector3(h, 0, 0))
	var dy := sample(p + Vector3(0, h, 0)) - sample(p - Vector3(0, h, 0))
	var dz := sample(p + Vector3(0, 0, h)) - sample(p - Vector3(0, 0, h))
	# Density is positive inside; the *outward* surface normal is the negative gradient.
	return Vector3(-dx, -dy, -dz).normalized()


## Cheap upper-bound radius of the displaced surface — used by chunk culling.
## Must be a strict upper bound on `surface_r` over all (p), otherwise the
## octree culls chunks that contain visible terrain and the player sees
## "noise shifting" as mountaintops pop in / out.
## Derivation (with current height formula):
##    height ≤ continent*250 + ridge*MAX_TERRAIN_HEIGHT*0.75 + detail*26
##          ≤ 250 + 450 + 26 = 726
## plus a safety margin.
func max_surface_radius() -> float:
	# Strict upper bound on `height`. Continent post-bias max is 0.95*75 ≈ 71.
	# Plus ridge + hills + detail + spire + plateau + safety margin (~50).
	# Undershooting pops mountaintops in/out, so keep generous.
	return radius + 71.0 + MAX_TERRAIN_HEIGHT + 14.0 + 1.5 + MAX_SPIRE_HEIGHT + MAX_PLATEAU_RISE + 50.0


## Cheap lower-bound radius (for the deepest possible carve).
func min_surface_radius() -> float:
	# Continent post-bias min is -1.25*75 ≈ -94 m. Plus canyon carving down
	# to MAX_CANYON_DEPTH and cave carving below surface.
	return radius - 94.0 - MAX_CANYON_DEPTH - CAVE_BOTTOM_DEPTH
