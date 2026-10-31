## Phase 2 view: a GeoTerrain package with sun, sky and haze, a free camera and a readout of where the camera is.
##   <godot> --path . res://demo/terrain_view.tscn                     (free camera)
##   <godot> --path . res://demo/terrain_view.tscn -- --out <dir>      (saves one PNG per view, then quits)
## Package: res://terrain/ankara (build it with tools/build_terrain.py), else the small test package.
## Controls: right mouse + WASD / Q E, Shift = fast, wheel = speed, 1-6 = views, G = drop to 2 m above ground,
## F = walk on the ground.
extends Node3D

const PACKAGES := ["res://terrain/ankara", "res://tests/data/ankara_small"]
const SUN_ELEVATION := 24.0
const SUN_AZIMUTH := 235.0  # from true north, clockwise: the sun stands in the south-west

## name -> [camera position, look-at target]; views marked in GROUND_VIEWS take Y as height above ground.
var views := {
	"overview": [Vector3(-2000, 14000, 24000), Vector3(0, 900, -3000)],
	"city": [Vector3(3500, 2600, 7500), Vector3(-500, 900, -1500)],
	"hills_east": [Vector3(9000, 350, 12000), Vector3(14000, 1500, 19000)],
	"valley": [Vector3(-3000, 80, 3000), Vector3(-9000, 900, -6000)],
	"low_city": [Vector3(1200, 150, 1500), Vector3(-1500, 850, -1800)],
	"top_down": [Vector3(0, 9000, 0.01), Vector3(0, 0, 0)],
}
const GROUND_VIEWS := ["hills_east", "valley", "low_city"]

var out_dir := ""
var walking := false
var _speed := 300.0

@onready var terrain: GeoTerrain = $GeoTerrain
@onready var camera: Camera3D = $Camera
@onready var sun: DirectionalLight3D = $Sun
@onready var info: Label = $HUD/Info


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	if i >= 0 and i + 1 < args.size():
		out_dir = args[i + 1]
	_place_sun()
	var t0 := Time.get_ticks_msec()
	for p: String in PACKAGES:
		if FileAccess.file_exists(p.path_join("terrain.json")):
			terrain.package_path = p
			break
	if not terrain.is_loaded():
		push_error("No terrain package; build one with tools/build_terrain.py (see README).")
		return
	var load_ms := Time.get_ticks_msec() - t0
	print("package %s loaded in %d ms" % [terrain.package_path, load_ms])
	if terrain.package.size_m < 10000.0:  # small test package: scale the views down
		for k: String in views:
			views[k] = [views[k][0] * 0.09, views[k][1] * 0.09]
	$HUD/Attribution.text = "\n".join(terrain.attribution())
	camera.far = terrain.package.size_m * 4.0
	if out_dir.is_empty():
		_set_view("city")
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		DirAccess.make_dir_recursive_absolute(out_dir)
		_capture_all.call_deferred()


func _place_sun() -> void:
	var el := deg_to_rad(SUN_ELEVATION)
	var az := deg_to_rad(SUN_AZIMUTH)
	# Direction towards the sun in Godot axes (+X east, -Z north).
	var to_sun := Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
	sun.basis = Basis.looking_at(-to_sun, Vector3.UP if absf(to_sun.y) < 0.99 else Vector3.FORWARD)


func _set_view(name: String) -> void:
	var v: Array = views[name]
	var pos: Vector3 = v[0]
	if name in GROUND_VIEWS:
		pos.y += terrain.height_at(pos.x, pos.z)
	camera.global_position = pos
	camera.look_at(v[1], Vector3.UP if name != "top_down" else Vector3.FORWARD)


func _capture_all() -> void:
	var stats := {}
	for name: String in views:
		_set_view(name)
		for i in 20:
			await get_tree().process_frame
		var t0 := Time.get_ticks_usec()
		var frames := 60
		for i in frames:
			await get_tree().process_frame
		var ms := (Time.get_ticks_usec() - t0) / 1000.0 / frames
		get_viewport().get_texture().get_image().save_png(out_dir.path_join("%s.png" % name))
		var backend := terrain.get_child(0, true) as GeoCdlodBackend
		stats[name] = {
			"frame_ms": snappedf(ms, 0.01),
			"nodes": backend.selected.size() if backend else 0,
			"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		}
	stats["video_mem_mb"] = snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1)
	var f := FileAccess.open(out_dir.path_join("stats.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(stats, "  "))
	print(JSON.stringify(stats, "  "))
	get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		camera.rotate_y(-event.relative.x * 0.003)
		camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * 0.003)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: _speed *= 1.25
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: _speed /= 1.25
	elif event is InputEventKey and event.pressed and not event.echo:
		var names := views.keys()
		var n: int = event.keycode - KEY_1
		if n >= 0 and n < names.size():
			walking = false
			_set_view(names[n])
		elif event.keycode == KEY_G:
			_drop_to_ground()
		elif event.keycode == KEY_F:
			walking = not walking
			if walking:
				_speed = 10.0
				_drop_to_ground()


func _drop_to_ground() -> void:
	var p := camera.global_position
	var h := terrain.height_at(p.x, p.z)
	if not is_nan(h):
		camera.global_position.y = h + 2.0


func _process(delta: float) -> void:
	if not terrain.is_loaded():
		return
	if out_dir.is_empty():
		var dir := Vector3(
			float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
			float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
			float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
		var mult := 5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
		camera.translate(dir * _speed * mult * delta)
		if walking:
			_drop_to_ground()
	var p := camera.global_position
	var g := terrain.global_to_geodetic(p)
	var ground := terrain.height_at(p.x, p.z)
	var backend := terrain.get_child(0, true) as GeoCdlodBackend
	info.text = "%.5f° N  %.5f° E   h %.0f m (WGS84)   above ground %s\nspeed %.0f m/s   nodes %d   %d fps" % [
		g[0], g[1], g[2], "-" if is_nan(ground) else "%.0f m" % (p.y - ground), _speed,
		backend.selected.size() if backend else 0, Engine.get_frames_per_second()]
