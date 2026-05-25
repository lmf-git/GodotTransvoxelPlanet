extends Node3D

## Entry point. Builds the solar system (sun + orbiting planet system), spawns
## the player as a child of the planet system so they travel with the orbit,
## and wires the planet's chunk streamer to the player's camera.

const PLANET_RADIUS    : float = 4000.0
const ATMOSPHERE_RADIUS: float = 4520.0
const SPAWN_ALTITUDE   : float = 1900.0   # safely above the highest possible terrain (max surface now ≈ +1576 m with spires/plateaus)

var world  : PlanetaryWorld
var player : FlightPlayer
var hud_label : Label
var fps_label : Label
var time_label: Label

var _wireframe : bool = false


func _ready() -> void:
	world = PlanetaryWorld.new()
	world.planet_radius = PLANET_RADIUS
	world.atmosphere_radius = ATMOSPHERE_RADIUS
	world.name = "World"
	add_child(world)

	player = FlightPlayer.new()
	player.name = "Player"
	# Parent to the PlanetSystem so the player travels with the orbit.
	world.planet_system.add_child(player)
	# Spawn over the equator on the SUNLIT side. The star is at the world
	# origin and the planet orbits out toward +X, so the planet's lit hemisphere
	# faces -X (back toward the sun); the +X face is night. Spawning at -X puts
	# the player over daylit, varied-biome terrain instead of a dark hemisphere
	# that reads as empty void. Expressed in the PlanetSystem local frame.
	player.position = Vector3(-(PLANET_RADIUS + SPAWN_ALTITUDE), 0, 0)
	# look_at uses GLOBAL coordinates and aims the node's -Z at the target.
	# Target = planet center. Up = world up (perpendicular to the +X view dir).
	player.look_at(world.planet_system.global_position, Vector3.UP)

	# Hand the planet reference to the player for gravity/altitude queries.
	player.set_planet(world.planet)
	# Hand the player's camera to the planet for LOD streaming.
	world.planet.set_camera(player.get_viewport().get_camera_3d())

	_build_hud()
	world.planet.stats_changed.connect(_on_planet_stats)
	player.mode_changed.connect(_on_mode_changed)


func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	add_child(canvas)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.position = Vector2(14, 12)
	canvas.add_child(vbox)

	hud_label  = _make_label("")
	fps_label  = _make_label("")
	time_label = _make_label("")
	vbox.add_child(hud_label)
	vbox.add_child(fps_label)
	vbox.add_child(time_label)

	var help := _make_label("")
	help.text = "[WASD] move  [Space/Shift] up-down  [Q/E] roll  [LAlt] boost  [F] flight/walk  [C] clouds  [`] wireframe  [Esc] release mouse"
	help.modulate = Color(1, 1, 1, 0.75)
	vbox.add_child(help)


func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.add_theme_constant_override("shadow_outline_size", 2)
	return l


func _process(_dt: float) -> void:
	fps_label.text = "FPS  %d" % Engine.get_frames_per_second()
	# Time of day / year readouts (phases in [0, 1]).
	var day_t := fposmod(world._spin_phase / TAU, 1.0)
	var year_t := fposmod(world._orbit_phase / TAU, 1.0)
	time_label.text = "Day  %d%% (length %.0fs)   Year  %d%% (length %.0fs)   Tilt %.1f°" % [
		int(day_t * 100.0), world.day_length_sec,
		int(year_t * 100.0), world.orbit_period_sec,
		world.axial_tilt_deg
	]


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_wireframe"):
		_wireframe = not _wireframe
		var debug := Viewport.DEBUG_DRAW_WIREFRAME if _wireframe else Viewport.DEBUG_DRAW_DISABLED
		get_viewport().debug_draw = debug
	# [C] toggles the volumetric cloud deck.
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_C:
		world.toggle_clouds()


func _on_planet_stats(active: int, pending: int, tris: int, lod_violations: int) -> void:
	var alt := world.planet.altitude_above_surface(player.global_position)
	hud_label.text = "Chunks %d (+%d pending)   Tris %s   2:1 violations %d   Altitude %.0f m   Mode %s" % [
		active, pending, _comma(tris), lod_violations, alt,
		"FLIGHT" if player.mode == FlightPlayer.Mode.FLIGHT else "WALK"
	]


func _on_mode_changed(_m: String) -> void:
	pass


func _comma(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c == 3 and i > 0 and s[i - 1].is_valid_int():
			out = "," + out
			c = 0
	return out
