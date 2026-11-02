extends GutTest
## Water layer on the Üsküdar test package (3 km around the Üsküdar seafront): loading, water_at, the surface over
## water at mean sea level, the shader switch; and the bookmark file of demo/city.tscn.

const PACKAGE := "res://tests/data/uskudar_small"
const PLACES := "res://demo/places.json"
# Mid-Bosphorus off Üsküdar, and a street in Üsküdar (Hakimiyeti Milliye Caddesi).
const SEA := Vector2(41.0240, 29.0000)
const LAND := Vector2(41.0245, 29.0200)

var pkg: GeoTerrainPackage


func before_all() -> void:
	pkg = GeoTerrainPackage.open(PACKAGE, true)


func _terrain() -> GeoTerrain:
	var t := GeoTerrain.new()
	t.package_path = PACKAGE
	add_child_autofree(t)
	return t


func test_package_has_water() -> void:
	assert_true(pkg.ok(), pkg.error)
	assert_true(pkg.has_water())
	assert_eq(pkg.water_samples, 401)
	assert_eq(pkg.water.get_format(), Image.FORMAT_L8)
	assert_eq(pkg.water_spacing, 7.5)


func test_package_without_water() -> void:
	var p := GeoTerrainPackage.open("res://tests/data/ankara_small")
	assert_true(p.ok(), p.error)
	assert_false(p.has_water())
	assert_eq(p.water_at(0.0, 0.0), 0.0)
	var t := GeoTerrain.new()
	t.package_path = "res://tests/data/ankara_small"
	add_child_autofree(t)
	assert_eq(t.water_at(0.0, 0.0), 0.0)


func test_water_at() -> void:
	var t := _terrain()
	var sea := t.geodetic_to_global(SEA.x, SEA.y, 0.0)
	var land := t.geodetic_to_global(LAND.x, LAND.y, 0.0)
	assert_eq(t.water_at(sea.x, sea.z), 1.0)
	assert_eq(t.water_at(land.x, land.z), 0.0)
	assert_true(is_nan(t.water_at(5000.0, 0.0)), "outside the package")


func test_sea_surface_is_mean_sea_level() -> void:
	# Over water height_at() is the water surface: the DEM's 0 m (EGM2008), i.e. ellipsoidal height = geoid N.
	var t := _terrain()
	var geoid: Dictionary = pkg.meta.sources.geoid
	for lat in [41.012, 41.018, 41.024, 41.030, 41.036]:
		var h := t.geodetic_height(lat, SEA.y)
		assert_between(h, float(geoid.n_min_m) - 0.05, float(geoid.n_max_m) + 0.05, "lat %f" % lat)
	assert_gt(t.geodetic_height(LAND.x, LAND.y), float(geoid.n_max_m) + 3.0)


func test_water_switch_reaches_the_shader() -> void:
	var t := _terrain()
	var b := t.get_child(0, true) as GeoCdlodBackend
	var mat: ShaderMaterial = b._material
	assert_true(mat.get_shader_parameter("water_enabled"))
	t.water = false
	assert_false(mat.get_shader_parameter("water_enabled"))


func test_places_file() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(PLACES))
	assert_true(data is Dictionary)
	var ids := {}
	var checks := 0
	for p: Dictionary in data.places:
		for key in ["id", "name", "lat", "lon", "target_height", "heading", "pitch", "distance", "note"]:
			assert_true(p.has(key), "%s lacks %s" % [p.get("id"), key])
		assert_false(ids.has(p.id), "duplicate id %s" % p.id)
		ids[p.id] = true
		assert_between(float(p.pitch), -89.0, 89.0)
		assert_gt(float(p.distance), 0.0)
		if p.get("check", false):
			checks += 1
	assert_eq(checks, 3, "Kaan's three reference views")
	for id in ["bulgurlu", "capitol", "uskudar_sahil"]:
		assert_true(ids.has(id), id)
