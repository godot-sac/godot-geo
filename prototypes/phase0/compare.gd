## Phase 0: draws the Ankara prototype package with Terrain3D or with our own chunked mesh, from fixed camera views,
## and saves screenshots plus timing numbers so the two can be compared side by side.
##   <godot> --path . res://prototypes/phase0/compare.tscn --resolution 1920x1080 -- --renderer terrain3d --out <dir>
## Without --out the scene stays open with a free camera (WASD + right mouse, Shift = fast, wheel = speed).
extends Node3D

const PACKAGE := "res://terrain/ankara_proto"

## name -> [camera position, look-at target]; Y is filled from the terrain where marked NAN (height above ground).
var views := {
	"overview": [Vector3(0, 16000, 26000), Vector3(0, 900, -2000)],
	"city": [Vector3(2500, 2400, 7000), Vector3(-500, 900, -1500)],
	"oblique_hills": [Vector3(9000, 300, 12000), Vector3(14000, 1500, 19000)],
	"low_valley": [Vector3(-3000, 60, 3000), Vector3(-9000, 900, -6000)],
	"top_down": [Vector3(0, 3000, 0.01), Vector3(0, 0, 0)],
}

var renderer := "mesh"
var out_dir := ""
var heights: Image
var meta: Dictionary
var stats := {}
var load_ms := 0.0

@onready var camera: Camera3D = $Camera


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--renderer": renderer = args[i + 1]
			"--out": out_dir = args[i + 1]
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)  # honest frame times
	var t0 := Time.get_ticks_msec()
	meta = JSON.parse_string(FileAccess.get_file_as_string(PACKAGE + "/terrain.json"))
	var n: int = meta.samples
	var bytes := FileAccess.get_file_as_bytes(PACKAGE + "/height.r32")
	heights = Image.create_from_data(n, n, false, Image.FORMAT_RF, bytes)
	var color := Image.load_from_file(ProjectSettings.globalize_path(PACKAGE + "/color.png"))
	if renderer == "terrain3d":
		_build_terrain3d(color)
	else:
		color.generate_mipmaps()
		var mesh := ProtoMeshTerrain.new()
		add_child(mesh)
		mesh.build(heights, ImageTexture.create_from_image(color), meta.size_m, meta.spacing_m)
	load_ms = Time.get_ticks_msec() - t0
	print("renderer=%s load=%d ms" % [renderer, load_ms])
	if out_dir.is_empty():
		_set_view("city")
	else:
		DirAccess.make_dir_recursive_absolute(out_dir)
		_capture_all.call_deferred()


func _build_terrain3d(color: Image) -> void:
	var t := ClassDB.instantiate("Terrain3D") as Node3D
	t.set("region_size", 1024)
	t.set("vertex_spacing", float(meta.spacing_m))
	var mat: Resource = ClassDB.instantiate("Terrain3DMaterial")
	mat.set("show_checkered", false)
	mat.set("show_colormap", true)
	mat.set("world_background", 0)
	t.set("material", mat)
	t.set("assets", ClassDB.instantiate("Terrain3DAssets"))
	t.set("collision_mode", 0)  # same as our mesh in this comparison: no collision
	add_child(t)
	t.call("set_camera", camera)
	color.convert(Image.FORMAT_RGBA8)
	var half: float = meta.size_m * 0.5
	var images: Array[Image] = [heights, null, color]
	t.get("data").call("import_images", images, Vector3(-half, 0, -half), 0.0, 1.0)


func ground_height(x: float, z: float) -> float:
	var half: float = meta.size_m * 0.5
	var px := clampi(roundi((x + half) / meta.spacing_m), 0, heights.get_width() - 1)
	var pz := clampi(roundi((z + half) / meta.spacing_m), 0, heights.get_height() - 1)
	return heights.get_pixel(px, pz).r


func _set_view(name: String) -> void:
	var v: Array = views[name]
	var pos: Vector3 = v[0]
	if name in ["oblique_hills", "low_valley"]:  # Y means height above ground
		pos.y += ground_height(pos.x, pos.z)
	camera.global_position = pos
	camera.look_at(v[1])


func _capture_all() -> void:
	for name: String in views:
		_set_view(name)
		for i in 30:  # let LOD/clipmap settle
			await get_tree().process_frame
		var t0 := Time.get_ticks_usec()
		var frames := 120
		for i in frames:
			await get_tree().process_frame
		var ms := (Time.get_ticks_usec() - t0) / 1000.0 / frames
		var img := get_viewport().get_texture().get_image()
		img.save_png(out_dir.path_join("%s_%s.png" % [renderer, name]))
		stats[name] = {
			"frame_ms": snappedf(ms, 0.01),
			"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		}
	stats["load_ms"] = load_ms
	stats["video_mem_mb"] = snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1)
	stats["texture_mem_mb"] = snappedf(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, 0.1)
	var f := FileAccess.open(out_dir.path_join("%s_stats.json" % renderer), FileAccess.WRITE)
	f.store_string(JSON.stringify(stats, "  "))
	print(JSON.stringify(stats, "  "))
	get_tree().quit()


# --- free camera when run interactively ---
var _speed := 300.0

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		camera.rotate_y(-event.relative.x * 0.003)
		camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * 0.003)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: _speed *= 1.25
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: _speed /= 1.25
	elif event is InputEventKey and event.pressed:
		var keys := {KEY_1: "overview", KEY_2: "city", KEY_3: "oblique_hills", KEY_4: "low_valley", KEY_5: "top_down"}
		if keys.has(event.keycode): _set_view(keys[event.keycode])


func _process(delta: float) -> void:
	if not out_dir.is_empty():
		return
	var dir := Vector3(
		Input.get_axis(&"ui_left", &"ui_right") + float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	var mult := 5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
	camera.translate(dir * _speed * mult * delta)
