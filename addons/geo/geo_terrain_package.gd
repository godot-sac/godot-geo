## A terrain package written by tools/build_terrain.py (see docs/package-format.md), loaded with engine APIs only.
## `open()` never raises engine errors: check `error` (empty on success).
class_name GeoTerrainPackage
extends RefCounted

const FORMAT := "godot-geo-terrain"
const FORMAT_VERSION := 1

var path := ""
var error := ""
var meta: Dictionary = {}
## Heights, FORMAT_RF, row 0 = north edge, and the same values as a flat row-major array.
var heights: Image
var height_data: PackedFloat32Array
var color: Image

var latitude := 0.0
var longitude := 0.0
var origin_height := 0.0
var size_m := 0.0
var spacing := 0.0
## Samples per edge; cells = samples - 1.
var samples := 0
var color_spacing := 0.0
var color_samples := 0
var height_min := 0.0
var height_max := 0.0


## Loads the package directory `dir` (res://, user:// or absolute). With `verify` the SHA-256 of each file is checked.
static func open(dir: String, verify := false) -> GeoTerrainPackage:
	var pkg := GeoTerrainPackage.new()
	pkg.path = dir
	pkg.error = pkg._load(dir, verify)
	return pkg


func ok() -> bool:
	return error.is_empty()


func _load(dir: String, verify: bool) -> String:
	var json_path := dir.path_join("terrain.json")
	if not FileAccess.file_exists(json_path):
		return "no terrain package at %s (terrain.json missing)" % dir
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	if not parsed is Dictionary:
		return "%s is not valid JSON" % json_path
	meta = parsed
	if meta.get("format") != FORMAT:
		return "%s: format is %s, expected %s" % [json_path, meta.get("format"), FORMAT]
	if int(meta.get("format_version", 0)) != FORMAT_VERSION:
		return "%s: format_version %s is not supported (expected %d)" % [json_path, meta.get("format_version"),
				FORMAT_VERSION]
	latitude = float(meta.origin.latitude)
	longitude = float(meta.origin.longitude)
	origin_height = float(meta.origin.height)
	size_m = float(meta.size_m)
	spacing = float(meta.height.spacing_m)
	samples = int(meta.height.samples)
	color_spacing = float(meta.color.spacing_m)
	color_samples = int(meta.color.samples)
	height_min = float(meta.height.min)
	height_max = float(meta.height.max)

	for key in ["height", "color"]:
		var file := dir.path_join(meta[key].file)
		if not FileAccess.file_exists(file):
			return "%s missing" % file
		if verify and FileAccess.get_sha256(file) != meta[key].sha256:
			return "%s: SHA-256 does not match terrain.json" % file

	heights = Image.load_from_file(_global(dir.path_join(meta.height.file)))
	if heights == null or heights.get_format() != Image.FORMAT_RF:
		return "%s: expected a single-channel float32 image" % meta.height.file
	if heights.get_size() != Vector2i(samples, samples):
		return "%s: size %s does not match samples %d" % [meta.height.file, heights.get_size(), samples]
	height_data = heights.get_data().to_float32_array()

	color = Image.load_from_file(_global(dir.path_join(meta.color.file)))
	if color == null or color.get_size() != Vector2i(color_samples, color_samples):
		return "%s: missing or wrong size" % meta.color.file
	return ""


static func _global(p: String) -> String:
	return ProjectSettings.globalize_path(p) if p.begins_with("res://") or p.begins_with("user://") else p


## Height sample at column `c` (east) and row `r` (south), clamped to the grid.
func sample(c: int, r: int) -> float:
	var n := samples
	return height_data[clampi(r, 0, n - 1) * n + clampi(c, 0, n - 1)]


## Local x, z of a grid point.
func grid_to_local(c: float, r: float) -> Vector2:
	return Vector2(-size_m * 0.5 + c * spacing, -size_m * 0.5 + r * spacing)


func contains(x: float, z: float) -> bool:
	var half := size_m * 0.5
	return x >= -half and x <= half and z >= -half and z <= half


func attribution() -> PackedStringArray:
	return PackedStringArray(meta.get("attribution", []))
