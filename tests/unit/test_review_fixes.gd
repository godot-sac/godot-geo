extends GutTest
## Edge cases found in the pre-release review: long and degenerate segments, vertical rays, eyes among trees,
## corrupted binary layers, missing layer files.

const PACKAGE := "res://tests/data/uskudar_small"

var pkg: GeoTerrainPackage


func before_all() -> void:
	pkg = GeoTerrainPackage.open(PACKAGE)


func test_obstacles_searched_only_over_the_package() -> void:
	var a := Vector3(0.0, 300.0, 0.0)
	var t0 := Time.get_ticks_msec()
	var r := GeoVisibility.line_of_sight(pkg, a, Vector3(1.0e6, 300.0, 0.0))
	assert_lt(Time.get_ticks_msec() - t0, 100, "1000 km segment: only the 1.5 km over the package is walked")
	assert_true(r.partial)
	r = GeoVisibility.line_of_sight(pkg, Vector3(5000.0, 300.0, 0.0), Vector3(9000.0, 300.0, 0.0))
	assert_true(r.visible, "a segment outside the package has nothing to hit")
	var span := GeoVisibility.clip_to_package(pkg, Vector3(-3000.0, 0.0, 0.0), Vector3(3000.0, 0.0, 0.0))
	assert_almost_eq(span.x, 0.25, 1e-9)
	assert_almost_eq(span.y, 0.75, 1e-9)


func test_vertical_ray_with_infinite_range_hits_the_ground() -> void:
	var r := GeoVisibility.raycast(pkg, Vector3(-1000.0, 2000.0, 400.0), Vector3.DOWN, INF, GeoVisibility.TERRAIN)
	assert_true(r.hit)
	assert_almost_eq(r.position.y, GeoVisibility.surface_height(pkg, -1000.0, 400.0), 0.01)
	r = GeoVisibility.raycast(pkg, Vector3(-1000.0, 2000.0, 400.0), Vector3.UP, INF)
	assert_false(r.hit)


func test_trace_returns_on_absurd_segments() -> void:
	var tr := GeoVisibility.trace(pkg, Vector3(-1.0e18, 500.0, 10.0), Vector3(1.0e18, 500.0, 10.0))
	assert_true(tr.partial)


func test_eye_among_trees_can_look_up() -> void:
	# Find a tree sample of the package and look straight up from 2 m above its ground.
	var spot := Vector2(NAN, NAN)
	for z in range(-1400, 1400, 20):
		for x in range(-1400, 1400, 20):
			if pkg.tree_height_at(x, z) > 5.0:
				spot = Vector2(x, z)
				break
		if not is_nan(spot.x):
			break
	assert_false(is_nan(spot.x), "the test package has trees")
	var g := GeoVisibility.surface_height(pkg, spot.x, spot.y)
	var r := GeoVisibility.line_of_sight(pkg, Vector3(spot.x, g + 2.0, spot.y), Vector3(spot.x, g + 500.0, spot.y), 0.0,
			0.001, GeoVisibility.TREES)
	assert_true(r.visible)


func _write(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func test_hostile_building_header_is_refused() -> void:
	var head := PackedByteArray()
	head.resize(20)
	head.encode_u32(0, 0x4C424747)  # "GGBL"
	head.encode_u16(4, 1)
	head.encode_float(8, 500.0)
	head.encode_u16(12, 65535)
	head.encode_u16(14, 65535)
	var path := "user://hostile_buildings.bin"
	_write(path, head)
	var d := GeoBuildingData.open(path, 3000.0)
	assert_false(d.ok())
	head.encode_float(8, 0.0)
	head.encode_u16(12, 6)
	head.encode_u16(14, 6)
	_write(path, head)
	assert_false(GeoBuildingData.open(path, 3000.0).ok(), "tile size 0")


func test_truncated_building_tile_decodes_what_fits() -> void:
	var src := FileAccess.get_file_as_bytes(PACKAGE.path_join("buildings.bin"))
	var d := GeoBuildingData.open(PACKAGE.path_join("buildings.bin"), 3000.0)
	var raw := PackedByteArray()
	for j in d.tiles_z:
		for i in d.tiles_x:
			if d.tile_count(i, j) > 10:
				var o := (j * d.tiles_x + i) * 16 + 20
				raw = src.slice(src.decode_u32(o), src.decode_u32(o) + src.decode_u32(o + 4)).decompress(
						src.decode_u32(o + 8), FileAccess.COMPRESSION_DEFLATE)
				break
		if not raw.is_empty():
			break
	var cut := raw.slice(0, raw.size() / 2)
	var list := d._decode(cut, Vector2.ZERO)
	assert_gt(list.size(), 0)
	for b: Dictionary in list:
		assert_gte((b.rings[0] as PackedVector2Array).size(), 3)


func test_missing_layer_file_is_an_error_not_a_crash() -> void:
	var dir := "user://pkg_missing_layer"
	DirAccess.make_dir_recursive_absolute(dir)
	for f in ["terrain.json", "height.exr", "color.png"]:
		_write(dir.path_join(f), FileAccess.get_file_as_bytes(PACKAGE.path_join(f)))
	var p := GeoTerrainPackage.open(dir)
	assert_false(p.ok())
	assert_string_contains(p.error, "missing")
