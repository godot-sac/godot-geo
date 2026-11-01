extends GutTest
## GeoMath UTM / MGRS against tests/golden/utm_mgrs_cases.txt (UTM: pyproj / PROJ; MGRS: python-mgrs).

const CASES := "res://tests/golden/utm_mgrs_cases.txt"

var _utm: Array[PackedStringArray] = []
var _mgrs: Array[PackedStringArray] = []


func before_all() -> void:
	for line in FileAccess.get_file_as_string(CASES).split("\n"):
		if line.is_empty() or line.begins_with("#"):
			continue
		var f := line.split(" ")
		if f[0] == "utm":
			_utm.append(f)
		elif f[0] == "mgrs":
			_mgrs.append(f)


func test_golden_file_is_loaded() -> void:
	assert_gt(_utm.size(), 50)
	assert_eq(_mgrs.size(), _utm.size())


func test_geodetic_to_utm() -> void:
	for f in _utm:
		var lat := f[1].to_float()
		var lon := f[2].to_float()
		var u := GeoMath.geodetic_to_utm(lat, lon)
		assert_false(u.is_empty(), "utm %s %s" % [lat, lon])
		if u.is_empty():
			continue
		assert_eq(u["zone"], f[3].to_int(), "zone %s %s" % [lat, lon])
		assert_eq(u["north"], f[4] == "N", "hemisphere %s %s" % [lat, lon])
		assert_almost_eq(u["easting"], f[5].to_float(), 1e-3, "easting %s %s" % [lat, lon])
		assert_almost_eq(u["northing"], f[6].to_float(), 1e-3, "northing %s %s" % [lat, lon])


func test_utm_to_geodetic_round_trip() -> void:
	for f in _utm:
		var g := GeoMath.utm_to_geodetic(f[3].to_int(), f[4] == "N", f[5].to_float(), f[6].to_float())
		assert_eq(g.size(), 2)
		if g.size() != 2:
			continue
		assert_almost_eq(g[0], f[1].to_float(), 1e-9, "lat %s %s" % [f[1], f[2]])
		assert_almost_eq(fposmod(g[1] - f[2].to_float() + 180.0, 360.0) - 180.0, 0.0, 1e-9, "lon %s %s" % [f[1], f[2]])


func test_utm_zone_exceptions() -> void:
	assert_eq(GeoMath.utm_zone(60.5, 5.5), 32, "Norway")
	assert_eq(GeoMath.utm_zone(64.0, 5.5), 31, "north of the 32V band")
	assert_eq(GeoMath.utm_zone(55.99, 5.5), 31)
	assert_eq(GeoMath.utm_zone(78.0, 15.0), 33, "Svalbard")
	assert_eq(GeoMath.utm_zone(78.0, 7.0), 31)
	assert_eq(GeoMath.utm_zone(78.0, 25.0), 35)
	assert_eq(GeoMath.utm_zone(78.0, 37.0), 37)
	assert_eq(GeoMath.utm_zone(0.0, 180.0), 1)
	assert_eq(GeoMath.utm_zone(0.0, -180.0), 1)
	assert_eq(GeoMath.utm_zone(0.0, 179.99), 60)


func test_geodetic_to_mgrs() -> void:
	for f in _mgrs:
		var lat := f[1].to_float()
		var lon := f[2].to_float()
		var golden: String = f[4]
		assert_eq(GeoMath.geodetic_to_mgrs(lat, lon), golden, "mgrs %s %s" % [lat, lon])
		# Lower precisions are truncations of the 5-digit string (the generator checks the same on python-mgrs).
		var head := golden.substr(0, golden.length() - 10)
		var e := golden.substr(golden.length() - 10, 5)
		var n := golden.substr(golden.length() - 5)
		for d in range(0, 5):
			assert_eq(GeoMath.geodetic_to_mgrs(lat, lon, d), head + e.substr(0, d) + n.substr(0, d),
					"mgrs %s %s digits %d" % [lat, lon, d])


func test_mgrs_to_geodetic_is_square_centre() -> void:
	for f in _mgrs:
		var lat := f[1].to_float()
		var lon := f[2].to_float()
		var g := GeoMath.mgrs_to_geodetic(f[4])
		assert_eq(g.size(), 2, f[4])
		if g.size() != 2:
			continue
		# The centre of a 1 m square is within sqrt(2)/2 m of any point in it.
		var p := GeoMath.geodetic_to_local(g[0], g[1], 0.0, lat, lon, 0.0)
		assert_lt(p.length(), 0.72, f[4])


func test_mgrs_to_geodetic_coarse_squares() -> void:
	for f in _mgrs:
		var lat := f[1].to_float()
		var lon := f[2].to_float()
		for d in range(0, 5):
			var s := GeoMath.geodetic_to_mgrs(lat, lon, d)
			var g := GeoMath.mgrs_to_geodetic(s)
			assert_eq(g.size(), 2, s)
			if g.size() != 2:
				continue
			var p := GeoMath.geodetic_to_local(g[0], g[1], 0.0, lat, lon, 0.0)
			assert_lt(p.length(), 0.7072 * 10.0 ** (5 - d) + 1.0, s)


func test_mgrs_input_forms() -> void:
	var ref := GeoMath.mgrs_to_geodetic("36SVK8801220374")
	assert_eq(ref.size(), 2)
	for s in ["36S VK 88012 20374", "36svk8801220374", " 36S VK 88012 20374 "]:
		var g := GeoMath.mgrs_to_geodetic(s)
		assert_eq(g.size(), 2, s)
		if g.size() == 2:
			assert_eq(g[0], ref[0])
			assert_eq(g[1], ref[1])
	# Single-digit zone.
	var z := GeoMath.mgrs_to_geodetic("9JWM1435425430")
	assert_eq(z.size(), 2)
	if z.size() == 2:
		assert_almost_eq(z[0], -25.989867, 1e-5)
		assert_almost_eq(z[1], -128.856578, 1e-5)


func test_invalid_inputs() -> void:
	assert_true(GeoMath.geodetic_to_utm(84.0, 0.0).is_empty())
	assert_true(GeoMath.geodetic_to_utm(89.0, 0.0).is_empty())
	assert_true(GeoMath.geodetic_to_utm(-80.1, 0.0).is_empty())
	assert_true(GeoMath.geodetic_to_utm(NAN, 0.0).is_empty())
	assert_true(GeoMath.geodetic_to_utm(10.0, INF).is_empty())
	assert_false(GeoMath.geodetic_to_utm(-80.0, 0.0).is_empty())
	assert_false(GeoMath.geodetic_to_utm(83.999, 0.0).is_empty())
	assert_eq(GeoMath.geodetic_to_mgrs(85.0, 0.0), "")
	assert_eq(GeoMath.geodetic_to_mgrs(-81.0, 0.0), "")
	assert_eq(GeoMath.utm_to_geodetic(0, true, 500000.0, 0.0).size(), 0)
	assert_eq(GeoMath.utm_to_geodetic(61, true, 500000.0, 0.0).size(), 0)
	assert_eq(GeoMath.utm_to_geodetic(36, true, NAN, 0.0).size(), 0)
	for s in ["", "36", "36S", "36SV", "36SVK1", "36SVK123", "36SVK12345678901", "36SVK12X4", "37SVK8801220374",
			"36IVK8801220374", "36SVI8801220374", "36SVO8801220374", "36SVK", "00SVK8801220374", "61SVK8801220374",
			"SVK8801220374", "36SVK-1-1", "36 S V K 1 2 3"]:
		var g := GeoMath.mgrs_to_geodetic(s)
		if s == "36SVK":
			assert_eq(g.size(), 2, "100 km square only")
		elif s == "37SVK8801220374":
			# 'V' is not a column letter of zone 37's set (set 1: J..R), so this is invalid
			assert_eq(g.size(), 0, s)
		else:
			assert_eq(g.size(), 0, "'%s' should be invalid" % s)
