## Phase 0: checks that Terrain3D returns the package heights at grid points and between them (bilinear).
##   <godot> --headless --path . -s res://prototypes/phase0/check_t3d_heights.gd
extends SceneTree

const PACKAGE := "res://terrain/ankara"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PACKAGE + "/terrain.json"))
	var n: int = meta.height.samples
	var spacing: float = meta.height.spacing_m
	var half: float = meta.size_m * 0.5
	var img := Image.load_from_file(ProjectSettings.globalize_path(PACKAGE + "/height.exr"))
	var t := ClassDB.instantiate("Terrain3D") as Node3D
	t.set("region_size", 1024)
	t.set("vertex_spacing", spacing)
	root.add_child(t)
	var images: Array[Image] = [img, null, null]
	var data: Object = t.get("data")
	data.call("import_images", images, Vector3(-half, 0, -half), 0.0, 1.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var max_grid := 0.0
	var max_mid := 0.0
	for i in 2000:
		var px := rng.randi_range(0, n - 2)
		var pz := rng.randi_range(0, n - 2)
		var x := -half + px * spacing
		var z := -half + pz * spacing
		max_grid = maxf(max_grid, absf(data.call("get_height", Vector3(x, 0, z)) - img.get_pixel(px, pz).r))
		var mid := (img.get_pixel(px, pz).r + img.get_pixel(px + 1, pz).r + img.get_pixel(px, pz + 1).r
				+ img.get_pixel(px + 1, pz + 1).r) * 0.25
		max_mid = maxf(max_mid, absf(data.call("get_height", Vector3(x + spacing * 0.5, 0, z + spacing * 0.5)) - mid))
	print("max |terrain3d - package| at grid points: %.4f m, at cell centres: %.4f m" % [max_grid, max_mid])
	quit()
