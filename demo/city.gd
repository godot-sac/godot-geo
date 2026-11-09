## City view: a GeoTerrain package with its layers (water, ground detail, trees, buildings, roads), sun, sky, haze, a free camera and named camera
## bookmarks (demo/places.json) for comparing the picture with places you know.
##   <godot> --path . res://demo/city.tscn [-- --package <dir>] [--place <id>]
##   <godot> --path . res://demo/city.tscn -- --tour --out <dir>   (one PNG per bookmark + stats.json, then quits)
##   <godot> --path . res://demo/city.tscn -- --check [--report x.json] | --bench x.json   (see city_check.gd)
## Package: --package, else res://terrain/uskudar_10km, res://terrain/uskudar, then the Üsküdar test package.
## Controls: right mouse + WASD / Q E, Shift = fast, wheel = speed; Tab = bookmark list, 1-9 / 0 = bookmarks,
## PgUp / PgDn = previous / next, G = drop to 2 m above ground, F = walk (stops at walls), F3 = info,
## F12 = screenshot (user://).
extends Node3D

const PACKAGES := ["res://terrain/uskudar_10km", "res://terrain/uskudar", "res://tests/data/uskudar_small"]
const PLACES_FILE := "res://demo/places.json"
const CityCheck := preload("res://demo/city_check.gd")
const SUN_ELEVATION := 35.0
const SUN_AZIMUTH := 220.0  # from true north, clockwise: early afternoon, sun in the south-west

## Bookmarks inside the loaded package.
var places: Array[Dictionary] = []
var current := -1
var walking := false
var _speed := 150.0
var _checker: RefCounted

@onready var terrain: GeoTerrain = $GeoTerrain
@onready var camera: Camera3D = $Camera
@onready var sun: DirectionalLight3D = $Sun
@onready var info: Label = $HUD/Info
@onready var place_label: Label = $HUD/Place
@onready var place_list: ItemList = $HUD/PlaceList


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_place_sun()
	var t0 := Time.get_ticks_msec()
	terrain.ground_detail = float(_arg(args, "--detail", str(terrain.ground_detail)))
	var pkg := _arg(args, "--package", "")
	terrain.collision_buildings = true  # the walker (F) stops at walls
	for p: String in ([pkg] if not pkg.is_empty() else PACKAGES):
		if FileAccess.file_exists(p.path_join("terrain.json")):
			terrain.package_path = p
			break
	if not terrain.is_loaded():
		push_error("No terrain package; build one with tools/build_terrain.py (see docs/city.md).")
		return
	print("package %s loaded in %d ms" % [terrain.package_path, Time.get_ticks_msec() - t0])
	$HUD/Attribution.text = "\n".join(terrain.attribution())
	camera.far = maxf(terrain.package.size_m * 3.0, 20000.0)
	_load_places()
	place_list.item_selected.connect(func(i: int) -> void: _go_to(i))
	var out := _arg(args, "--out", "")
	if "--check" in args or "--bench" in args:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		_checker = CityCheck.new(self)  # kept: a RefCounted freed after _ready would never resume its awaits
		if "--check" in args:
			_checker.run_check.call_deferred(_arg(args, "--report", ""))
		else:
			_checker.run_bench.call_deferred(_arg(args, "--bench", "user://city_bench.json"))
		return
	if "--tour" in args:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		_tour.call_deferred(out if not out.is_empty() else "user://city_tour")
		return
	var start := _arg(args, "--place", "")
	var idx := places.find_custom(func(p: Dictionary) -> bool: return p.id == start)
	_go_to(idx if idx >= 0 else 0)


func _arg(args: PackedStringArray, flag: String, default: String) -> String:
	var i := args.find(flag)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else default


func _place_sun() -> void:
	var el := deg_to_rad(SUN_ELEVATION)
	var az := deg_to_rad(SUN_AZIMUTH)
	var to_sun := Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))  # Godot axes: +X east, -Z north
	sun.basis = Basis.looking_at(-to_sun, Vector3.UP)


func _load_places() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(PLACES_FILE))
	if not data is Dictionary:
		push_error("%s is not valid JSON" % PLACES_FILE)
		return
	for p: Dictionary in data.places:
		var g := terrain.geodetic_to_global(p.lat, p.lon, 0.0)
		if is_nan(terrain.height_at(g.x, g.z)):
			continue  # outside this package
		places.append(p)
		place_list.add_item("%d  %s" % [(places.size()) % 10, p.name])


## Camera for bookmark `i`: looking along its heading / pitch at the point target_height above the ground.
func _go_to(i: int) -> void:
	if i < 0 or i >= places.size():
		return
	current = i
	walking = false
	var p := places[i]
	var g := terrain.geodetic_to_global(p.lat, p.lon, 0.0)
	var target := Vector3(g.x, terrain.height_at(g.x, g.z) + float(p.target_height), g.z)
	var hdg := deg_to_rad(float(p.heading))
	var pit := deg_to_rad(float(p.pitch))
	var dir := Vector3(sin(hdg) * cos(pit), sin(pit), -cos(hdg) * cos(pit))
	var pos := target - dir * float(p.distance)
	var ground := terrain.height_at(pos.x, pos.z)
	if not is_nan(ground):
		pos.y = maxf(pos.y, ground + 3.0)
	camera.global_position = pos
	camera.look_at(target, Vector3.UP)
	place_label.text = "%s\n%s" % [p.name, p.note]
	place_list.select(i)


func _tour(out_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	var stats := {"package": terrain.package_path, "places": {}}
	for i in places.size():
		_go_to(i)
		var t_build := Time.get_ticks_msec()
		for l in terrain.layers():
			if l.has_method(&"build_all_around"):
				l.build_all_around(terrain.to_package_local(camera.global_position))
		var build_ms := Time.get_ticks_msec() - t_build
		for f in 30:
			await get_tree().process_frame
		var t0 := Time.get_ticks_usec()
		var frames := 60
		for f in frames:
			await get_tree().process_frame
		var ms := (Time.get_ticks_usec() - t0) / 1000.0 / frames
		get_viewport().get_texture().get_image().save_png(out_dir.path_join("%s.png" % places[i].id))
		stats.places[places[i].id] = {
			"name": places[i].name,
			"frame_ms": snappedf(ms, 0.01),
			"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			"layer_build_ms": build_ms,
			"layers": _layer_counts(),
		}
	stats["video_mem_mb"] = snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1)
	var f := FileAccess.open(out_dir.path_join("stats.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(stats, "  "))
	print(JSON.stringify(stats, "  "))
	get_tree().quit()


## Instances per layer around the camera (trees, buildings, ...), for reports and the F3 line.
func _layer_counts() -> Dictionary:
	var out := {}
	for l in terrain.layers():
		if l is GeoTreeLayer:
			out["trees"] = l.tree_count
		elif l is GeoBuildingLayer:
			out["buildings"] = l.buildings_drawn
		elif l is GeoRoadLayer:
			out["roads_near"] = l.painted()
			out["bridges"] = l.bridges
	return out


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		camera.rotate_y(-event.relative.x * 0.003)
		camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * 0.003)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: _speed *= 1.25
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: _speed /= 1.25
	elif event is InputEventKey and event.pressed and not event.echo:
		var k: Key = event.keycode
		if k >= KEY_0 and k <= KEY_9:
			_go_to((k - KEY_1 + 10) % 10)
		elif k == KEY_PAGEDOWN:
			_go_to(posmod(current + 1, places.size()))
		elif k == KEY_PAGEUP:
			_go_to(posmod(current - 1, places.size()))
		elif k == KEY_TAB:
			place_list.visible = not place_list.visible
		elif k == KEY_G:
			_drop_to_ground()
		elif k == KEY_F:
			walking = not walking
			if walking:
				_speed = 10.0
				_drop_to_ground()
		elif k == KEY_F3:
			info.visible = not info.visible
		elif k == KEY_F12:
			var path := "user://city_%s.png" % Time.get_datetime_string_from_system().replace(":", "-")
			get_viewport().get_texture().get_image().save_png(path)
			print("screenshot: %s" % path.get_file())


## Walking: the step from `before` to the camera's new position, shortened where a 0.4 m sphere at eye height would
## hit a building (GeoTerrain.collision_buildings) or the terrain.
func _walk_from(before: Vector3) -> void:
	var step := camera.global_position - before
	step.y = 0.0
	camera.global_position = before
	if step.is_zero_approx():
		return
	var sphere := SphereShape3D.new()
	sphere.radius = 0.4
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis.IDENTITY, before)
	q.motion = step
	var safe := get_world_3d().direct_space_state.cast_motion(q)
	if safe.size() != 2 or safe[0] >= 1.0:
		camera.global_position = before + step
		return
	# Stop 10 cm short of the wall: a sphere left touching it (within the physics margin) would pass through on the
	# next step.
	camera.global_position = before + step.normalized() * maxf(step.length() * safe[0] - 0.1, 0.0)


func _drop_to_ground() -> void:
	var p := camera.global_position
	var h := terrain.height_at(p.x, p.z)
	if not is_nan(h):
		camera.global_position.y = h + 2.0


func _process(delta: float) -> void:
	if not terrain.is_loaded():
		return
	var dir := Vector3(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	var mult := 5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
	var before := camera.global_position
	camera.translate(dir * _speed * mult * delta)
	if walking:
		_walk_from(before)
		_drop_to_ground()
	if not info.visible:
		return
	var p := camera.global_position
	var g := terrain.global_to_geodetic(p)
	var ground := terrain.height_at(p.x, p.z)
	var w := terrain.water_at(p.x, p.z)
	info.text = "%.5f° N  %.5f° E   %s   h %.0f m (WGS84)   above ground %s%s\nspeed %.0f m/s   %d fps" % [
		g[0], g[1], GeoMath.geodetic_to_mgrs(g[0], g[1], 4), g[2],
		"-" if is_nan(ground) else "%.0f m" % (p.y - ground), "  (water)" if w > 0.5 else "",
		_speed, Engine.get_frames_per_second()]
