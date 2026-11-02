## Scripted run of the visibility demo for the README animation and the social preview image.
##   <godot> --path . --resolution 960x540 --write-movie <dir>/frame.png --fixed-fps 15 res://demo/visibility_tour.tscn
##   <godot> --path . --resolution 1280x640 res://demo/visibility_tour.tscn -- --poster <file.png>
## Options: --observer <lat>,<lon> (default below), --package <dir> (as the demo). Frames to GIF: tools/make_gif.py.
## The line of sight sweeps a circle around the observer; halfway the mast grows from 10 m to 60 m and the viewshed
## is computed again. The camera stays still so the GIF stays small; the line of sight is drawn as wide beams over the
## demo's one-pixel lines so that it shows in a scaled-down GIF.
extends Node

const VisibilityDemo := preload("res://demo/visibility.gd")
const OBSERVER := Vector2(39.8400, 32.9100)  # latitude, longitude; hills south-east of Ankara (40 km package)
const DURATION := 14.0
const RADIUS := 4000.0

var _t := 0.0
var _poster := ""
var _beams: Array[MeshInstance3D] = []

@onready var demo: VisibilityDemo = $Visibility


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_poster = demo._arg(args, "--poster", "")
	var at := OBSERVER
	var given := demo._arg(args, "--observer", "").split(",")
	if given.size() == 2:
		at = Vector2(given[0].to_float(), given[1].to_float())
	var terrain: GeoTerrain = demo.terrain
	var p := terrain.geodetic_to_global(at.x, at.y, 0.0)
	demo._place_observer(p)
	demo.radius = minf(RADIUS, terrain.package.size_m * 0.3)
	demo.observer_height = 10.0
	demo.help.text = ""
	demo.show_fps = false
	process_priority = 1  # after the demo, so the beams show this frame's line of sight
	for c: Color in [VisibilityDemo.VISIBLE_COLOR, VisibilityDemo.BLOCKED_COLOR]:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = c * 0.6  # darker: the AgX tonemapper washes bright unshaded colours out to white
		mat.no_depth_test = true
		mat.render_priority = 1
		var beam := MeshInstance3D.new()
		beam.mesh = BoxMesh.new()
		beam.material_override = mat
		add_child(beam)
		_beams.append(beam)
	var cam: Camera3D = demo.camera
	var o: Vector3 = demo.observer
	var r: float = demo.radius
	cam.global_position = o + Vector3(-0.55 * r, 0.75 * r, 1.25 * r)
	cam.look_at(o + Vector3(0.1 * r, 0.0, 0.1 * r), Vector3.UP)
	demo.viewshed_now()
	if not _poster.is_empty():
		_make_poster.call_deferred()


func _process(delta: float) -> void:
	_draw_beams()
	if not _poster.is_empty():
		return
	_t += delta
	if _t >= DURATION / 2.0 and demo.observer_height < 60.0:
		demo.observer_height = 60.0
		demo.viewshed_now()
	_aim(_t / DURATION)
	if _t >= DURATION:
		get_tree().quit()


## Points the line of sight at a ring around the observer; f = 0..1 is one turn.
func _aim(f: float) -> void:
	var a := TAU * f + 0.6
	var p: Vector3 = demo.observer + Vector3(cos(a), 0.0, sin(a)) * demo.radius * 0.75
	p.y = demo.terrain.height_at(p.x, p.z)
	demo.scripted_target = p


func _draw_beams() -> void:
	var los: Dictionary = demo.los
	var eye := demo._eye()
	var ends := [[eye, los.get("point", eye)], [los.get("point", eye), demo.target + Vector3(0.0, demo.target_height, 0.0)]]
	for i in 2:
		var a: Vector3 = ends[i][0]
		var b: Vector3 = ends[i][1]
		var show: bool = not los.is_empty() and (i == 0 or not los.visible) and a.distance_to(b) > 1.0
		_beams[i].visible = show
		if show:
			var w := demo.camera.global_position.distance_to((a + b) / 2.0) * 0.008
			var basis := Basis.looking_at(b - a, Vector3.UP) * Basis.from_scale(Vector3(w, w, a.distance_to(b)))
			_beams[i].global_transform = Transform3D(basis, (a + b) / 2.0)


func _make_poster() -> void:
	demo.observer_height = 60.0
	demo.viewshed_now()
	_aim(0.4)
	demo.show_info = false
	var hud: CanvasLayer = demo.get_node("HUD")
	var title := Label.new()
	title.text = "godot-geo"
	title.position = Vector2(48.0, 36.0)
	title.add_theme_font_size_override("font_size", 76)
	var sub := Label.new()
	sub.text = "Real-world terrain for Godot 4 from open data or DTED / GeoTIFF\nline of sight · viewshed · WGS84 / MGRS"
	sub.position = Vector2(52.0, 140.0)
	sub.add_theme_font_size_override("font_size", 28)
	for l: Label in [title, sub]:
		l.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
		l.add_theme_constant_override("outline_size", 10)
		hud.add_child(l)
	for i in 60:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(_poster)
	print("poster: ", _poster)
	get_tree().quit()
