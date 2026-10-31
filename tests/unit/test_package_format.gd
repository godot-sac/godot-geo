extends GutTest
## Format contract between tools/build_terrain.py and Godot: the small committed package must load with plain
## engine APIs (GeoTerrainPackage uses the same calls).

const PACKAGE := "res://tests/data/ankara_small"

var meta: Dictionary


func before_all() -> void:
	meta = JSON.parse_string(FileAccess.get_file_as_string(PACKAGE + "/terrain.json"))


func test_meta_basics() -> void:
	assert_eq(meta.format, "godot-geo-terrain")
	assert_eq(int(meta.format_version), 1)
	assert_almost_eq(float(meta.origin.latitude), 39.9334, 1e-9)


func test_height_exr_loads_as_float_image() -> void:
	var img := Image.load_from_file(ProjectSettings.globalize_path(PACKAGE + "/" + meta.height.file))
	assert_not_null(img)
	assert_eq(img.get_format(), Image.FORMAT_RF, "single-channel float32 EXR")
	var n := int(meta.height.samples)
	assert_eq(img.get_size(), Vector2i(n, n))
	var lo := INF
	var hi := -INF
	for y in n:
		for x in n:
			var v := img.get_pixel(x, y).r
			lo = minf(lo, v)
			hi = maxf(hi, v)
	assert_almost_eq(lo, float(meta.height.min), 1e-3)
	assert_almost_eq(hi, float(meta.height.max), 1e-3)


func test_color_png_loads() -> void:
	var img := Image.load_from_file(ProjectSettings.globalize_path(PACKAGE + "/" + meta.color.file))
	assert_not_null(img)
	var n := int(meta.color.samples)
	assert_eq(img.get_size(), Vector2i(n, n))


func test_sha256_matches_meta() -> void:
	for key in ["height", "color"]:
		var path: String = PACKAGE + "/" + meta[key].file
		assert_eq(FileAccess.get_sha256(path), meta[key].sha256, key)
