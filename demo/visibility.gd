## Visibility demo: line of sight to the point under the mouse and a viewshed overlay around an observer.
##   <godot> --path . res://demo/visibility.tscn [-- --package <dir>]
##   <godot> --path . res://demo/visibility.tscn -- --check [--report x.json] [--out <dir>]
## Package: --package, else res://terrain/ankara, else the small test package.
## Mouse: left click = place the observer on the ground (GeoTerrain.raycast from the camera), the line of sight runs to
## the point under the cursor (cyan up to the first obstruction, yellow beyond it; the viewshed overlay is green /
## red). Right mouse + WASD / Q E = fly, Shift = fast, wheel = speed.
## Keys: V viewshed, C clear it, [ ] radius, PgUp / PgDn observer height, T target height, R refraction
## (0 / 0.13 / 0.25), F3 info panel, F12 screenshot (user://).
## --check: fixed scenario around the package centre (viewshed timing, lines of sight on a ring, viewshed against
## line of sight); prints a JSON report, exits 0 if plausible, 1 if not.
extends Node3D

const PACKAGES := ["res://terrain/ankara", "res://tests/data/ankara_small"]
const REFRACTIONS := [0.0, 0.13, 0.25]
const VISIBLE_COLOR := Color(0.2, 0.9, 1.0)  # line colours stand out against the green / red overlay
const BLOCKED_COLOR := Color(1.0, 0.85, 0.1)

var observer := Vector3.ZERO  # ground point; the eye is observer_height above it
var observer_height := 10.0
var target_height := 2.0
var radius := 3000.0
var refraction_index := 0
var resolution := 256
var los: Dictionary = {}
var target := Vector3.INF
var viewshed_ms := -1.0
var viewshed_visible := -1.0
var show_info := true
var _speed := 300.0
var _task := -1
var _task_result: Image
var _task_observer := Vector3.ZERO
var _task_radius := 0.0
var _task_started := 0
var _checking := false

@onready var terrain: GeoTerrain = $GeoTerrain
@onready var camera: Camera3D = $Camera
@onready var info: Label = $HUD/Info
@onready var help: Label = $HUD/Help
var _lines: MeshInstance3D
var _marker: MeshInstance3D
var _hit_marker: MeshInstance3D


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var pkg := _arg(args, "--package", "")
	var paths: Array = [pkg] if not pkg.is_empty() else PACKAGES
	for p: String in paths:
		if FileAccess.file_exists(p.path_join("terrain.json")):
			terrain.package_path = p
			break
	if not terrain.is_loaded():
		push_error("No terrain package; build one with tools/build_terrain.py (see README).")
		get_tree().quit(1)
		return
	$HUD/Attribution.text = "\n".join(terrain.attribution())
	var size := terrain.package.size_m
	radius = clampf(size * 0.15, 500.0, 5000.0)
	camera.far = size * 4.0
	_setup_meshes()
	_place_observer(Vector3.ZERO)
	camera.global_position = observer + Vector3(-radius * 0.6, radius * 0.5, radius * 0.9)
	camera.look_at(observer, Vector3.UP)
	if "--check" in args:
		_check.call_deferred(_arg(args, "--report", ""), _arg(args, "--out", ""))


func _arg(args: PackedStringArray, key: String, default: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else default


func _setup_meshes() -> void:
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.vertex_color_use_as_albedo = true
	line_mat.no_depth_test = true
	line_mat.render_priority = 1
	_lines = MeshInstance3D.new()
	_lines.mesh = ImmediateMesh.new()
	_lines.material_override = line_mat
	add_child(_lines)
	_marker = _sphere(Color(0.2, 0.6, 1.0))
	_hit_marker = _sphere(BLOCKED_COLOR)


func _sphere(color: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.5
	s.height = 1.0
	m.mesh = s
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.no_depth_test = true
	m.material_override = mat
	add_child(m)
	return m


func _eye() -> Vector3:
	return observer + Vector3(0.0, observer_height, 0.0)


func _place_observer(p: Vector3) -> void:
	var h := terrain.height_at(p.x, p.z)
	if is_nan(h):
		return
	observer = Vector3(p.x, h, p.z)
	los = {}


func _refraction() -> float:
	return REFRACTIONS[refraction_index]


# --- viewshed (worker thread) ----------------------------------------------------------------------------------

func start_viewshed() -> void:
	if _task >= 0:
		return
	_task_observer = _eye()
	_task_radius = radius
	_task_started = Time.get_ticks_usec()
	var eye := terrain.to_package_local(_task_observer)
	var pkg := terrain.package
	var r := radius
	var th := target_height
	var res := resolution
	var k := _refraction()
	_task = WorkerThreadPool.add_task(func(): _task_result = GeoVisibility.viewshed(pkg, eye, r, th, res, k))


func _finish_viewshed() -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	viewshed_ms = (Time.get_ticks_usec() - _task_started) / 1000.0
	var img := _task_result
	var vis := 0
	var inside := 0
	var data := img.get_data()
	for i in range(0, data.size(), 2):
		if data[i + 1] > 0:
			inside += 1
			if data[i] > 0:
				vis += 1
	viewshed_visible = float(vis) / maxi(inside, 1)
	terrain.set_overlay(GeoVisibility.viewshed_colors(img), terrain.viewshed_rect(_task_observer, _task_radius))
	print("viewshed r=%.0f m res=%d: %.0f ms, %.1f %% visible" % [_task_radius, resolution, viewshed_ms,
			viewshed_visible * 100.0])


# --- frame -------------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not terrain.is_loaded():
		return
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		_finish_viewshed()
	var dir := Vector3(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	camera.translate(dir * _speed * (5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0) * delta)
	var hit := {} if _checking else _cursor_hit()
	if hit.get("hit", false):
		target = hit.position
		var t := target + Vector3(0.0, target_height, 0.0)
		los = terrain.line_of_sight(_eye(), t, _refraction())
	_draw()
	_update_info()


func _cursor_hit() -> Dictionary:
	var mouse := get_viewport().get_mouse_position()
	return terrain.raycast(camera.project_ray_origin(mouse), camera.project_ray_normal(mouse))


func _draw() -> void:
	var im := _lines.mesh as ImmediateMesh
	im.clear_surfaces()
	var eye := _eye()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(Color(0.2, 0.6, 1.0))
	im.surface_add_vertex(observer)
	im.surface_add_vertex(eye)
	if not los.is_empty():
		var t := target + Vector3(0.0, target_height, 0.0)
		im.surface_set_color(VISIBLE_COLOR)
		im.surface_add_vertex(eye)
		im.surface_add_vertex(los.point)
		if not los.visible:
			im.surface_set_color(BLOCKED_COLOR)
			im.surface_add_vertex(los.point)
			im.surface_add_vertex(t)
		im.surface_set_color(Color(1, 1, 1, 0.8))
		im.surface_add_vertex(target)
		im.surface_add_vertex(t)
	im.surface_end()
	var scale := func(p: Vector3) -> float: return maxf(camera.global_position.distance_to(p) * 0.008, 1.0)
	_marker.global_position = eye
	_marker.scale = Vector3.ONE * scale.call(eye)
	_hit_marker.visible = not los.is_empty() and not los.visible
	if _hit_marker.visible:
		_hit_marker.global_position = los.point
		_hit_marker.scale = Vector3.ONE * scale.call(los.point)


func _update_info() -> void:
	help.visible = show_info
	info.visible = show_info
	if not show_info:
		return
	var g := terrain.global_to_geodetic(observer)
	var lines := PackedStringArray()
	lines.append("observer %s  %.5f, %.5f  ground %.0f m (WGS84)  eye +%.0f m  |  target +%.1f m  |  refraction k = %.2f" % [
			GeoMath.geodetic_to_mgrs(g[0], g[1]), g[0], g[1], g[2], observer_height, target_height, _refraction()])
	if not los.is_empty():
		var tg := terrain.global_to_geodetic(target)
		var d := _eye().distance_to(target + Vector3(0.0, target_height, 0.0))
		if los.visible:
			lines.append("cursor %s  %.0f m: VISIBLE, clearance %.1f m" % [GeoMath.geodetic_to_mgrs(tg[0], tg[1]), d,
					los.clearance])
		else:
			lines.append("cursor %s  %.0f m: BLOCKED at %.0f m (%.1f m below the line at worst)" % [
					GeoMath.geodetic_to_mgrs(tg[0], tg[1]), d, los.distance, -los.clearance])
		if los.partial:
			lines.append("  part of the line is outside the package (not tested)")
	if _task >= 0:
		lines.append("viewshed r %.0f m: computing..." % radius)
	elif viewshed_ms >= 0.0:
		lines.append("viewshed r %.0f m, %d px: %.0f ms, %.1f %% visible" % [_task_radius, resolution, viewshed_ms,
				viewshed_visible * 100.0])
	else:
		lines.append("viewshed radius %.0f m (V)" % radius)
	lines.append("%d fps" % Engine.get_frames_per_second())
	info.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		camera.rotate_y(-event.relative.x * 0.003)
		camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * 0.003)
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				var hit := _cursor_hit()
				if hit.hit:
					_place_observer(hit.position)
			MOUSE_BUTTON_WHEEL_UP:
				_speed *= 1.25
			MOUSE_BUTTON_WHEEL_DOWN:
				_speed /= 1.25
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_V:
				start_viewshed()
			KEY_C:
				terrain.clear_overlay()
				viewshed_ms = -1.0
			KEY_BRACKETLEFT:
				radius = maxf(radius / 1.25, 200.0)
			KEY_BRACKETRIGHT:
				radius = minf(radius * 1.25, terrain.package.size_m)
			KEY_PAGEUP:
				observer_height = minf(observer_height * 1.5, 2000.0)
			KEY_PAGEDOWN:
				observer_height = maxf(observer_height / 1.5, 1.0)
			KEY_T:
				target_height = 0.0 if target_height >= 10.0 else (2.0 if target_height < 2.0 else 10.0)
			KEY_R:
				refraction_index = (refraction_index + 1) % REFRACTIONS.size()
			KEY_F3:
				show_info = not show_info
			KEY_F12:
				_screenshot(OS.get_user_data_dir())


func _screenshot(dir: String) -> String:
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("visibility_%s.png" % Time.get_datetime_string_from_system().replace(":", "-"))
	get_viewport().get_texture().get_image().save_png(path)
	print("screenshot: ", path)
	return path


# --- --check ------------------------------------------------------------------------------------------------------

func _check(report_path: String, out_dir: String) -> void:
	_checking = true
	var report := {"package": terrain.package_path, "radius_m": radius, "observer_height_m": observer_height,
			"target_height_m": target_height, "resolution": resolution}
	var problems: PackedStringArray = []
	# Viewshed on the worker thread, as interactively.
	start_viewshed()
	while _task >= 0:
		await get_tree().process_frame
		if WorkerThreadPool.is_task_completed(_task):
			_finish_viewshed()
	report.viewshed_ms = snappedf(viewshed_ms, 0.1)
	report.viewshed_visible = snappedf(viewshed_visible, 0.001)
	if viewshed_visible <= 0.0 or viewshed_visible >= 1.0:
		problems.append("viewshed is all visible or all hidden")
	# Lines of sight to a ring of targets, and the viewshed at the same places.
	var img := _task_result
	var cell := 2.0 * radius / resolution
	var eye := _eye()
	var t0 := Time.get_ticks_usec()
	var count := 0
	var visible := 0
	var agree := 0
	for ring: float in [0.3, 0.6, 0.9]:
		for k in 36:
			var a := TAU * k / 36.0
			var p := observer + Vector3(cos(a), 0.0, sin(a)) * radius * ring
			# Snap to the pixel centre the viewshed judged.
			var col := floori((p.x - (eye.x - radius)) / cell)
			var row := floori((p.z - (eye.z - radius)) / cell)
			p = Vector3(eye.x - radius + (col + 0.5) * cell, 0.0, eye.z - radius + (row + 0.5) * cell)
			var h := terrain.height_at(p.x, p.z)
			if is_nan(h):
				continue
			var r := terrain.line_of_sight(eye, Vector3(p.x, h + target_height, p.z), _refraction())
			count += 1
			if r.visible:
				visible += 1
			if r.visible == (img.get_pixel(col, row).r > 0.5):
				agree += 1
	var los_ms := (Time.get_ticks_usec() - t0) / 1000.0
	report.line_of_sight = {"count": count, "visible": visible, "ms_each": snappedf(los_ms / maxi(count, 1), 0.01),
			"agree_with_viewshed": snappedf(float(agree) / maxi(count, 1), 0.001)}
	if count < 50:
		problems.append("too few lines of sight inside the package")
	elif float(agree) / count < 0.9:
		problems.append("viewshed and line of sight disagree")
	# Raycast down onto the observer's ground point.
	var ray := terrain.raycast(observer + Vector3(30.0, 1000.0, 0.0), Vector3(-30.0, -1000.0, 0.0))
	report.raycast_error_m = snappedf(ray.position.distance_to(observer), 0.001) if ray.hit else -1.0
	if not ray.hit or ray.position.distance_to(observer) > 0.01:
		problems.append("raycast missed the observer's ground point")
	if not out_dir.is_empty():
		target = observer + Vector3(radius * 0.45, 0.0, -radius * 0.35)
		target.y = terrain.height_at(target.x, target.z)
		los = terrain.line_of_sight(eye, target + Vector3(0.0, target_height, 0.0), _refraction())
		var mid := observer.lerp(target, 0.5)
		camera.global_position = mid + Vector3(-radius * 0.25, radius * 0.4, radius * 0.75)
		camera.look_at(mid, Vector3.UP)
		_draw()
		_update_info()
		for i in 30:
			await get_tree().process_frame
		report.screenshot = _screenshot(out_dir)
	report.problems = problems
	var text := JSON.stringify(report, "  ")
	print(text)
	if not report_path.is_empty():
		var f := FileAccess.open(report_path, FileAccess.WRITE)
		f.store_string(text)
	get_tree().quit(0 if problems.is_empty() else 1)
