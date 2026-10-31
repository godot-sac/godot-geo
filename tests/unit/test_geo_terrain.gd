extends GutTest
## GeoTerrain on the small committed package: queries, bounds, errors, origin alignment, collision.

const PACKAGE := "res://tests/data/ankara_small"

var pkg: GeoTerrainPackage


func before_all() -> void:
	pkg = GeoTerrainPackage.open(PACKAGE, true)


func _terrain(path := PACKAGE) -> GeoTerrain:
	var t := GeoTerrain.new()
	t.package_path = path
	add_child_autofree(t)
	return t


func _fake_origin(lat: float, lon: float, h: float) -> Node3D:
	var s := GDScript.new()
	s.source_code = "extends Node3D\nvar latitude := 0.0\nvar longitude := 0.0\nvar height := 0.0\n"
	s.reload()
	var o := Node3D.new()
	o.set_script(s)
	o.set(&"latitude", lat)
	o.set(&"longitude", lon)
	o.set(&"height", h)
	o.add_to_group(&"dis_geo_origin")
	add_child_autofree(o)
	return o


func test_package_loads_and_verifies() -> void:
	assert_true(pkg.ok(), pkg.error)
	assert_eq(pkg.samples, 121)
	assert_eq(pkg.height_data.size(), 121 * 121)
	assert_eq(pkg.attribution().size(), 2)


func test_missing_package() -> void:
	var p := GeoTerrainPackage.open("res://tests/data/does_not_exist")
	assert_false(p.ok())
	assert_string_contains(p.error, "no terrain package")
	var t := _terrain("res://tests/data/does_not_exist")
	assert_push_error("no terrain package")
	assert_false(t.is_loaded())
	assert_true(is_nan(t.height_at(0.0, 0.0)))


func test_height_at_grid_points_is_exact() -> void:
	var t := _terrain()
	for k in 50:
		var c := (k * 37) % pkg.samples
		var r := (k * 53 + 11) % pkg.samples
		var p := pkg.grid_to_local(c, r)
		assert_almost_eq(t.height_at(p.x, p.y), pkg.sample(c, r), 1e-4, "grid %d,%d" % [c, r])


func test_height_at_follows_ne_sw_triangles() -> void:
	var t := _terrain()
	for k in 30:
		var c := (k * 7 + 3) % (pkg.samples - 1)
		var r := (k * 11 + 5) % (pkg.samples - 1)
		var h00 := pkg.sample(c, r)
		var h10 := pkg.sample(c + 1, r)
		var h01 := pkg.sample(c, r + 1)
		var h11 := pkg.sample(c + 1, r + 1)
		# North-west and south-east triangle, written as barycentric mixes.
		var p := pkg.grid_to_local(c + 0.25, r + 0.25)
		assert_almost_eq(t.height_at(p.x, p.y), 0.5 * h00 + 0.25 * h10 + 0.25 * h01, 1e-3)
		p = pkg.grid_to_local(c + 0.75, r + 0.75)
		assert_almost_eq(t.height_at(p.x, p.y), 0.5 * h11 + 0.25 * h10 + 0.25 * h01, 1e-3)
		p = pkg.grid_to_local(c + 0.5, r + 0.5)  # on the diagonal
		assert_almost_eq(t.height_at(p.x, p.y), 0.5 * (h10 + h01), 1e-3)


func test_bounds() -> void:
	var t := _terrain()
	var half := pkg.size_m * 0.5
	assert_almost_eq(t.height_at(-half, -half), pkg.sample(0, 0), 1e-4, "NW corner")
	assert_almost_eq(t.height_at(half, half), pkg.sample(120, 120), 1e-4, "SE corner")
	assert_true(is_nan(t.height_at(half + 0.5, 0.0)))
	assert_true(is_nan(t.height_at(0.0, -half - 0.5)))
	assert_true(is_nan(t.geodetic_height(40.5, 32.8597)))


func test_geodetic_height_round_trip() -> void:
	var t := _terrain()
	for k in 20:
		var x := -1700.0 + k * 171.3
		var z := 1650.0 - k * 163.9
		var y := t.height_at(x, z)
		var g := t.global_to_geodetic(Vector3(x, y, z))
		assert_almost_eq(t.geodetic_height(g[0], g[1]), g[2], 1e-3, "at %s" % Vector2(x, z))
	# At the origin the ellipsoidal height equals the local height (origin height 0).
	assert_almost_eq(t.geodetic_height(pkg.latitude, pkg.longitude), t.height_at(0.0, 0.0), 1e-3)


func test_scene_origin_height_shifts_terrain() -> void:
	_fake_origin(pkg.latitude, pkg.longitude, 938.0)
	var t := _terrain()
	assert_eq(t.origin_warning, "")
	assert_almost_eq(t.origin_offset, -938.0, 1e-9)
	assert_almost_eq(t.height_at(0.0, 0.0), pkg.sample(60, 60) - 938.0, 1e-3)
	# A ground point given geodetically lands on the drawn surface in the shifted frame.
	var h := t.geodetic_height(pkg.latitude + 0.005, pkg.longitude - 0.007)
	var p := t.geodetic_to_global(pkg.latitude + 0.005, pkg.longitude - 0.007, h)
	assert_almost_eq(p.y, t.height_at(p.x, p.z), 1e-3)


func test_scene_origin_elsewhere_warns() -> void:
	_fake_origin(pkg.latitude + 0.01, pkg.longitude, 0.0)
	var t := _terrain()
	assert_push_warning("differs from the package origin")
	assert_string_contains(t.origin_warning, "differs")
	assert_eq(t.origin_offset, 0.0)


func test_collision_matches_surface() -> void:
	var target := Node3D.new()
	add_child_autofree(target)
	target.position = Vector3(300.0, 0.0, -200.0)
	var t := GeoTerrain.new()
	t.package_path = PACKAGE
	t.collision_size = 1500.0
	add_child_autofree(t)
	t.collision_target = t.get_path_to(target)
	t._update(true)
	await wait_physics_frames(3)
	var space := t.get_world_3d().direct_space_state
	for k in 40:
		# Points off the grid lines: a vertical ray exactly along a cell edge can miss (Jolt), which is not what we test.
		var x := target.position.x - 592.7 + k * 31.71
		var z := target.position.z + 492.9 - k * 27.33
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, 5000.0, z), Vector3(x, -1000.0, z))
		var hit := space.intersect_ray(q)
		assert_false(hit.is_empty(), "ray at %s" % Vector2(x, z))
		if not hit.is_empty():
			assert_almost_eq(hit.position.y, t.height_at(x, z), 0.01, "at %s" % Vector2(x, z))
