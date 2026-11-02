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
## Optional 8-bit raster layers (terrain.json key -> FORMAT_L8 Image, row 0 = north edge) and their spacing:
## "water" (coverage, 255 = water), "landcover" (ESA WorldCover class value), "canopy" (tree height, metres x 4),
## "footprints" (255 under building footprints).
const LAYER_KEYS := ["water", "landcover", "canopy", "footprints"]
var layers := {}
var layer_spacing := {}
## The water layer (also in `layers`); null if absent.
var water: Image
var water_samples := 0
var water_spacing := 0.0


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

	for key in LAYER_KEYS:
		if not meta.has(key):
			continue
		var file := dir.path_join(meta[key].file)
		if verify and FileAccess.get_sha256(file) != meta[key].sha256:
			return "%s: SHA-256 does not match terrain.json" % file
		var img := Image.load_from_file(_global(file))
		var n := int(meta[key].samples)
		if img == null or img.get_size() != Vector2i(n, n):
			return "%s: missing or wrong size" % meta[key].file
		img.convert(Image.FORMAT_L8)
		layers[key] = img
		layer_spacing[key] = float(meta[key].spacing_m)
	water = layers.get("water")
	if water:
		water_samples = water.get_width()
		water_spacing = layer_spacing.water
	return ""


func has_water() -> bool:
	return water != null


func has_layer(key: String) -> bool:
	return layers.has(key)


## Raw 8-bit value of layer `key` at the sample nearest to local x, z (0 if the package has no such layer).
func layer_value(key: String, x: float, z: float) -> int:
	var img: Image = layers.get(key)
	if img == null:
		return 0
	var s: float = layer_spacing[key]
	var n := img.get_width()
	var half := size_m * 0.5
	var c := clampi(roundi((x + half) / s), 0, n - 1)
	var r := clampi(roundi((z + half) / s), 0, n - 1)
	return img.get_pixel(c, r).r8


## Share of the cell around local x, z covered by water (0..1, bilinear), 0 without a water layer.
func water_at(x: float, z: float) -> float:
	if water == null:
		return 0.0
	var half := size_m * 0.5
	var px := clampf((x + half) / water_spacing, 0.0, water_samples - 1.0)
	var pz := clampf((z + half) / water_spacing, 0.0, water_samples - 1.0)
	var c := mini(int(px), water_samples - 2)
	var r := mini(int(pz), water_samples - 2)
	var fx := px - c
	var fz := pz - r
	var a := lerpf(water.get_pixel(c, r).r, water.get_pixel(c + 1, r).r, fx)
	var b := lerpf(water.get_pixel(c, r + 1).r, water.get_pixel(c + 1, r + 1).r, fx)
	return lerpf(a, b, fz)


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
