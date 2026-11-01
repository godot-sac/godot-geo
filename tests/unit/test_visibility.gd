extends GutTest
## GeoVisibility and the GeoTerrain query methods: analytic cases on synthetic grids, dense sampling of the real
## test package as an independent reference, viewshed against single lines of sight.

const PACKAGE := "res://tests/data/ankara_small"

var pkg: GeoTerrainPackage


func before_all() -> void:
	pkg = GeoTerrainPackage.open(PACKAGE)


## A synthetic package: samples x samples heights from `f(col, row)`, `spacing` metres apart.
func _grid(samples: int, spacing: float, f: Callable) -> GeoTerrainPackage:
	var p := GeoTerrainPackage.new()
	p.samples = samples
	p.spacing = spacing
	p.size_m = (samples - 1) * spacing
	p.height_data.resize(samples * samples)
	for r in samples:
		for c in samples:
			p.height_data[r * samples + c] = f.call(c, r)
	return p


## Column `col` as local x.
func _x(p: GeoTerrainPackage, col: float) -> float:
	return -p.size_m * 0.5 + col * p.spacing


func _terrain(path := PACKAGE) -> GeoTerrain:
	var t := GeoTerrain.new()
	t.package_path = path
	add_child_autofree(t)
	return t


func test_flat_ground() -> void:
	var p := _grid(101, 10.0, func(_c, _r): return 0.0)
	var los := GeoVisibility.line_of_sight(p, Vector3(-300, 2, 100), Vector3(400, 2, -250))
	assert_true(los.visible)
	assert_almost_eq(los.clearance, 2.0, 1e-6)
	assert_false(los.partial)
	var below := GeoVisibility.line_of_sight(p, Vector3(-300, -1, 0), Vector3(300, 2, 0))
	assert_false(below.visible)
	assert_almost_eq(below.distance, 0.0, 1e-6, "starts under the ground")


func test_ridge_blocks_at_the_exact_point() -> void:
	# A ridge along z: 0 m everywhere except 50 m on column 50, so the slope rises 5 m per metre after column 49.
	var p := _grid(101, 10.0, func(c, _r): return 50.0 if c == 50 else 0.0)
	var a := Vector3(-400, 10, 37)
	var b := Vector3(400, 10, -123)
	var los := GeoVisibility.line_of_sight(p, a, b)
	assert_false(los.visible)
	assert_almost_eq(los.point.x, _x(p, 49) + 2.0, 1e-3)
	assert_almost_eq(los.point.y, 10.0, 1e-6)
	assert_almost_eq(los.clearance, -40.0, 1e-3)
	assert_almost_eq(los.clearance_point.x, _x(p, 50), 1e-3)
	var over := GeoVisibility.line_of_sight(p, a + Vector3(0, 50, 0), b + Vector3(0, 50, 0))
	assert_true(over.visible)
	assert_almost_eq(over.clearance, 10.0, 1e-3)
	# Diagonal and reversed lines meet the same ridge.
	var rev := GeoVisibility.line_of_sight(p, b, a)
	assert_almost_eq(rev.point.x, _x(p, 51) - 2.0, 1e-3)
	var diag := GeoVisibility.line_of_sight(p, Vector3(-480, 10, -480), Vector3(480, 10, 470))
	assert_almost_eq(diag.point.x, _x(p, 49) + 2.0, 1e-3)


func test_refraction_raises_the_line_by_the_bulge() -> void:
	var p := _grid(201, 50.0, func(c, _r): return 30.0 if c == 140 else 0.0)
	var a := Vector3(_x(p, 0), 20, 0)
	var b := Vector3(_x(p, 200), 20, 0)
	var k := 0.25
	var plain := GeoVisibility.line_of_sight(p, a, b)
	var bent := GeoVisibility.line_of_sight(p, a, b, k)
	var s1 := 140.0 * 50.0
	var s2 := 60.0 * 50.0
	assert_almost_eq(bent.clearance - plain.clearance, k * s1 * s2 / (2.0 * GeoVisibility.EARTH_RADIUS), 1e-4)
	# The bend lifts the line by 0.41 m at the ridge: 29.7 m clears 30 m only with it.
	a.y = 29.7
	b.y = 29.7
	assert_false(GeoVisibility.line_of_sight(p, a, b).visible)
	assert_true(GeoVisibility.line_of_sight(p, a, b, k).visible)


func test_outside_parts_are_reported() -> void:
	var p := _grid(11, 10.0, func(_c, _r): return 0.0)
	var los := GeoVisibility.line_of_sight(p, Vector3(-200, 5, 0), Vector3(20, 5, 0))
	assert_true(los.visible)
	assert_true(los.partial)
	var away := GeoVisibility.line_of_sight(p, Vector3(-200, 5, 0), Vector3(-100, 5, 0))
	assert_true(away.partial)
	assert_eq(away.clearance, INF)


func test_surface_height_matches_the_renderer() -> void:
	var t := _terrain()
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var half := pkg.size_m * 0.5
	for i in 300:
		var x := rng.randf_range(-half, half)
		var z := rng.randf_range(-half, half)
		assert_almost_eq(GeoVisibility.surface_height(pkg, x, z), t.height_at(x, z), 1e-4)


func test_line_of_sight_against_dense_sampling() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var half := pkg.size_m * 0.5 - 1.0
	var blocked := 0
	for i in 60:
		var a := Vector3(rng.randf_range(-half, half), 0, rng.randf_range(-half, half))
		var b := Vector3(rng.randf_range(-half, half), 0, rng.randf_range(-half, half))
		a.y = GeoVisibility.surface_height(pkg, a.x, a.z) + rng.randf_range(1.0, 40.0)
		b.y = GeoVisibility.surface_height(pkg, b.x, b.z) + rng.randf_range(1.0, 40.0)
		var los := GeoVisibility.line_of_sight(pkg, a, b)
		# Reference: the line sampled every 5 cm.
		var steps := int(a.distance_to(b) / 0.05) + 1
		var first := -1.0
		var min_c := INF
		for s in steps + 1:
			var q := a.lerp(b, float(s) / steps)
			var c := q.y - GeoVisibility.surface_height(pkg, q.x, q.z)
			min_c = minf(min_c, c)
			if first < 0.0 and c < -0.001:
				first = a.distance_to(q)
		assert_eq(los.visible, first < 0.0, "segment %d" % i)
		assert_true(los.clearance <= min_c + 1e-4 and los.clearance >= min_c - 0.05, "clearance %d" % i)
		if first >= 0.0:
			blocked += 1
			# The reported point is on the surface, no earlier than the first sample below it would allow, and the
			# line is above the surface before it.
			var hit: Vector3 = los.point
			assert_almost_eq(hit.y, GeoVisibility.surface_height(pkg, hit.x, hit.z), 1e-3, "on surface %d" % i)
			assert_true(los.distance <= first + 1e-3, "obstruction %d too late" % i)
			var before := a.lerp(b, maxf(los.distance - 0.05, 0.0) / a.distance_to(b))
			assert_gt(before.y - GeoVisibility.surface_height(pkg, before.x, before.z), -0.001, "early %d" % i)
	assert_gt(blocked, 10, "the sample should contain blocked lines")
	assert_lt(blocked, 55, "and visible ones")


func test_raycast() -> void:
	var t := _terrain()
	var rng := RandomNumberGenerator.new()
	rng.seed = 8
	var half := pkg.size_m * 0.5 - 1.0
	for i in 40:
		var x := rng.randf_range(-half, half)
		var z := rng.randf_range(-half, half)
		var down := t.raycast(Vector3(x, 3000, z), Vector3.DOWN)
		assert_true(down.hit)
		assert_almost_eq(down.position.y, t.height_at(x, z), 1e-3)
		assert_almost_eq(Vector2(down.position.x, down.position.z), Vector2(x, z), Vector2(1e-3, 1e-3))
		assert_almost_eq(down.distance, 3000.0 - down.position.y, 1e-3)
		# Oblique ray: the hit lies on the surface and nothing before it is below the surface.
		var from := Vector3(x, t.height_at(x, z) + 30.0, z)
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.4, -0.05), rng.randf_range(-1, 1))
		var r := t.raycast(from, dir)
		if r.hit:
			assert_almost_eq(r.position.y, t.height_at(r.position.x, r.position.z), 1e-3)
			var check := t.line_of_sight(from, from + dir.normalized() * (r.distance - 0.05))
			assert_true(check.visible, "ray %d hits too late" % i)
			assert_gt(r.normal.y, 0.5)
	# Pointing up, and from outside towards the package.
	assert_false(t.raycast(Vector3(0, 2000, 0), Vector3.UP).hit)
	var outside := t.raycast(Vector3(-5000, 3000, 0), Vector3(1, -0.4, 0))
	assert_true(outside.hit)
	assert_true(pkg.contains(outside.position.x, outside.position.z))


func test_raycast_normal() -> void:
	var p := _grid(11, 10.0, func(c, r): return 0.5 * c * 10.0 - 0.25 * r * 10.0)  # plane z = 0.5x - 0.25z
	var r := GeoVisibility.raycast(p, Vector3(3, 100, -7), Vector3.DOWN)
	assert_almost_eq(r.normal, Vector3(-0.5, 1, 0.25).normalized(), Vector3.ONE * 1e-6)


func test_viewshed_flat_and_pit() -> void:
	var flat := _grid(101, 10.0, func(_c, _r): return 0.0)
	var img := GeoVisibility.viewshed(flat, Vector3(0, 2, 0), 400.0, 0.0, 64)
	assert_eq(img.get_format(), Image.FORMAT_LA8)
	var inside := 0
	for row in 64:
		for col in 64:
			var px := img.get_pixel(col, row)
			if px.a > 0.5:
				inside += 1
				assert_eq(px.r, 1.0, "flat ground is visible at %d,%d" % [col, row])
	assert_almost_eq(inside / (64.0 * 64.0), PI / 4.0, 0.02, "alpha covers the circle")
	# A 20 m wall at 200 m: ground beyond it is hidden from 2 m, visible from 60 m.
	var pit := _grid(101, 10.0, func(c, r):
		var d := Vector2(c - 50, r - 50).length() * 10.0
		return 20.0 if absf(d - 200.0) < 8.0 else 0.0)
	var low := GeoVisibility.viewshed(pit, Vector3(0, 2, 0), 450.0, 0.0, 90)
	var high := GeoVisibility.viewshed(pit, Vector3(0, 60, 0), 450.0, 0.0, 90)
	var cell := 900.0 / 90
	for k: Vector2 in [Vector2(320, 0), Vector2(0, -330), Vector2(-250, 250)]:
		var col := int((k.x + 450.0) / cell)
		var row := int((k.y + 450.0) / cell)
		assert_eq(low.get_pixel(col, row).r, 0.0, "hidden behind the wall %s" % k)
		assert_eq(high.get_pixel(col, row).r, 1.0, "visible over the wall %s" % k)
	var near := int(450.0 / cell) + 5
	assert_eq(low.get_pixel(near, near).r, 1.0, "inside the wall")


func test_viewshed_agrees_with_line_of_sight() -> void:
	var observer := Vector3(120, 0, -80)
	observer.y = GeoVisibility.surface_height(pkg, observer.x, observer.z) + 10.0
	var radius := 1500.0
	var res := 60
	var target_h := 2.0
	var img := GeoVisibility.viewshed(pkg, observer, radius, target_h, res)
	var cell := 2.0 * radius / res
	var total := 0
	var agree := 0
	var visible := 0
	for row in res:
		for col in res:
			var px := img.get_pixel(col, row)
			if px.a < 0.5:
				continue
			var x := observer.x - radius + (col + 0.5) * cell
			var z := observer.z - radius + (row + 0.5) * cell
			var target := Vector3(x, GeoVisibility.surface_height(pkg, x, z) + target_h, z)
			var los := GeoVisibility.line_of_sight(pkg, observer, target)
			total += 1
			if los.visible == (px.r > 0.5):
				agree += 1
			if los.visible:
				visible += 1
	gut.p("viewshed vs line of sight: %d / %d agree, %d visible" % [agree, total, visible])
	assert_gt(float(agree) / total, 0.95)
	assert_true(visible > total * 0.1 and visible < total * 0.95, "a mixed view, not a trivial one")


func test_viewshed_speed() -> void:
	var observer := Vector3(0, GeoVisibility.surface_height(pkg, 0, 0) + 5.0, 0)
	var t0 := Time.get_ticks_usec()
	GeoVisibility.viewshed(pkg, observer, 1700.0, 0.0, 256)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	gut.p("viewshed 256^2: %.0f ms" % ms)
	assert_lt(ms, 3000.0)


func test_terrain_methods_use_scene_positions() -> void:
	var t := _terrain()
	t.position = Vector3(1000, 50, -2000)
	var a := Vector3(1000 - 900, 0, -2000 + 300)
	var b := Vector3(1000 + 800, 0, -2000 - 600)
	a.y = t.height_at(a.x, a.z) + 1.7
	b.y = t.height_at(b.x, b.z) + 1.7
	var los := t.line_of_sight(a, b)
	var local := GeoVisibility.line_of_sight(pkg, a - t.position, b - t.position)
	assert_eq(los.visible, local.visible)
	assert_almost_eq(los.point, local.point + t.position, Vector3.ONE * 1e-3)
	if not los.visible:
		assert_almost_eq(los.point.y, t.height_at(los.point.x, los.point.z), 0.05)
	var img := t.viewshed(a, 600.0)
	assert_eq(img.get_width(), 256)
	assert_eq(t.viewshed_rect(a, 600.0), Rect2(a.x - 600, a.z - 600, 1200, 1200))
	t.set_overlay(GeoVisibility.viewshed_colors(img), t.viewshed_rect(a, 600.0))
	t.clear_overlay()
	assert_true(t.is_loaded())


func test_world_packages() -> void:
	# Across the antimeridian (Fiji) and the 70 N tile band edge (Norway): the same point given with either
	# longitude convention lands on the same place, and heights are continuous across the seam.
	var fiji := _terrain("res://tests/data/fiji_small")
	assert_true(fiji.is_loaded())
	var east := fiji.geodetic_to_global(-16.82, 179.999, 0.0)
	var west := fiji.geodetic_to_global(-16.82, -179.999, 0.0)
	assert_almost_eq(west.x - east.x, 2.0 * 0.001 * 111320.0 * cos(deg_to_rad(16.82)), 0.5)
	var p := fiji.geodetic_to_global(-16.82, 180.0, 0.0)
	assert_almost_eq(fiji.geodetic_to_global(-16.82, -180.0, 0.0), p, Vector3.ONE * 1e-6)
	var h_e := fiji.geodetic_height(-16.81, 179.9995)
	var h_w := fiji.geodetic_height(-16.81, -179.9995)
	assert_false(is_nan(h_e) or is_nan(h_w))
	assert_lt(absf(h_e - h_w), 15.0)
	var lla := fiji.global_to_geodetic(west)
	assert_almost_eq(lla[1], -179.999, 1e-9)
	var norway := _terrain("res://tests/data/norway_small")
	assert_true(norway.is_loaded())
	var north := norway.geodetic_height(70.0001, 23.27)
	var south := norway.geodetic_height(69.9999, 23.27)
	assert_lt(absf(north - south), 10.0)
	var q := norway.geodetic_to_global(70.0, 23.27, north)
	assert_almost_eq(q.y, norway.height_at(q.x, q.z), 0.01)
