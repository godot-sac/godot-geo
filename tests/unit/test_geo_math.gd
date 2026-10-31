extends GutTest
## GeoMath against the shared golden file (pymap3d; copy of godot-dis tests/golden/geo_cases.txt).

const CASES := "res://tests/golden/geo_cases.txt"

var _lines: Array[PackedStringArray] = []


func before_all() -> void:
	for line in FileAccess.get_file_as_string(CASES).split("\n"):
		if line.is_empty() or line.begins_with("#"):
			continue
		_lines.append(line.split(" "))


func _cases(kind: String) -> Array[PackedFloat64Array]:
	var out: Array[PackedFloat64Array] = []
	for f in _lines:
		if f[0] == kind:
			var v := PackedFloat64Array()
			for i in range(1, f.size()):
				v.append(f[i].to_float())
			out.append(v)
	return out


func test_geodetic_to_ecef() -> void:
	var cases := _cases("geo")
	assert_gt(cases.size(), 10)
	for c in cases:
		var e := GeoMath.geodetic_to_ecef(c[0], c[1], c[2])
		for k in 3:
			assert_almost_eq(e[k], c[3 + k], 1e-6, "ecef %s" % c)


func test_ecef_to_geodetic_round_trip() -> void:
	for c in _cases("geo"):
		var g := GeoMath.ecef_to_geodetic(PackedFloat64Array([c[3], c[4], c[5]]))
		assert_almost_eq(g[0], c[0], 1e-9, "lat %s" % c)
		if absf(c[0]) < 89.99:  # longitude is undefined at the poles
			assert_almost_eq(fposmod(g[1] - c[1] + 180.0, 360.0) - 180.0, 0.0, 1e-9, "lon %s" % c)
		assert_almost_eq(g[2], c[2], 1e-4, "h %s" % c)


func test_enu() -> void:
	var cases := _cases("enu")
	assert_gt(cases.size(), 5)
	for c in cases:
		var enu := GeoMath.ecef_to_enu(GeoMath.geodetic_to_ecef(c[3], c[4], c[5]), c[0], c[1], c[2])
		for k in 3:
			assert_almost_eq(enu[k], c[6 + k], 1e-5, "enu %s" % c)
		var back := GeoMath.enu_to_ecef(enu, c[0], c[1], c[2])
		var ref := GeoMath.geodetic_to_ecef(c[3], c[4], c[5])
		for k in 3:
			assert_almost_eq(back[k], ref[k], 1e-5)


func test_local_axes() -> void:
	# 1 km north of the origin is at -Z, 1 km east at +X, up is +Y.
	var lat0 := 39.9334
	var lon0 := 32.8597
	var north := GeoMath.geodetic_to_local(lat0 + 0.009, lon0, 0.0, lat0, lon0, 0.0)
	assert_lt(north.z, -990.0)
	assert_almost_eq(north.x, 0.0, 1e-3)
	var up := GeoMath.geodetic_to_local(lat0, lon0, 100.0, lat0, lon0, 0.0)
	assert_almost_eq(up.y, 100.0, 1e-6)
	var g := GeoMath.local_to_geodetic(Vector3(1234.5, 67.0, -890.0), lat0, lon0, 0.0)
	var p := GeoMath.geodetic_to_local(g[0], g[1], g[2], lat0, lon0, 0.0)
	assert_almost_eq(p.distance_to(Vector3(1234.5, 67.0, -890.0)), 0.0, 1e-3)
