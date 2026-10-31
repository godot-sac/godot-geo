## WGS84 helpers in double precision (GDScript floats are 64-bit): geodetic <-> ECEF <-> local frame at an origin.
## The local frame is the one godot-dis DisGeoOrigin uses: ENU tangent plane at the origin, mapped to Godot axes
## +X east, +Y up, -Z north. Latitude / longitude in degrees, heights above the WGS84 ellipsoid in metres.
class_name GeoMath
extends RefCounted

const A := 6378137.0
const F := 1.0 / 298.257223563
const E2 := F * (2.0 - F)


## [x, y, z] in metres.
static func geodetic_to_ecef(lat: float, lon: float, h: float) -> PackedFloat64Array:
	var phi := deg_to_rad(lat)
	var lam := deg_to_rad(lon)
	var s := sin(phi)
	var n := A / sqrt(1.0 - E2 * s * s)
	return PackedFloat64Array([(n + h) * cos(phi) * cos(lam), (n + h) * cos(phi) * sin(lam), (n * (1.0 - E2) + h) * s])


## [lat, lon, h]. Fixed-point iteration on latitude, same as godot-dis.
static func ecef_to_geodetic(ecef: PackedFloat64Array) -> PackedFloat64Array:
	var x := ecef[0]
	var y := ecef[1]
	var z := ecef[2]
	var p := sqrt(x * x + y * y)
	var lam := atan2(y, x)
	var phi := atan2(z, p * (1.0 - E2))
	for i in 10:
		var s := sin(phi)
		var n := A / sqrt(1.0 - E2 * s * s)
		var next := atan2(z + E2 * n * s, p)
		if absf(next - phi) < 1e-14:
			phi = next
			break
		phi = next
	var s := sin(phi)
	var h := p * cos(phi) + z * s - A * sqrt(1.0 - E2 * s * s)
	return PackedFloat64Array([rad_to_deg(phi), rad_to_deg(lam), h])


## East, north, up of `ecef` in the tangent frame at the origin (degrees, degrees, metres).
static func ecef_to_enu(ecef: PackedFloat64Array, lat0: float, lon0: float, h0: float) -> PackedFloat64Array:
	var o := geodetic_to_ecef(lat0, lon0, h0)
	var dx := ecef[0] - o[0]
	var dy := ecef[1] - o[1]
	var dz := ecef[2] - o[2]
	var phi := deg_to_rad(lat0)
	var lam := deg_to_rad(lon0)
	var sp := sin(phi)
	var cp := cos(phi)
	var sl := sin(lam)
	var cl := cos(lam)
	return PackedFloat64Array([
		-sl * dx + cl * dy,
		-sp * cl * dx - sp * sl * dy + cp * dz,
		cp * cl * dx + cp * sl * dy + sp * dz])


static func enu_to_ecef(enu: PackedFloat64Array, lat0: float, lon0: float, h0: float) -> PackedFloat64Array:
	var o := geodetic_to_ecef(lat0, lon0, h0)
	var phi := deg_to_rad(lat0)
	var lam := deg_to_rad(lon0)
	var sp := sin(phi)
	var cp := cos(phi)
	var sl := sin(lam)
	var cl := cos(lam)
	var e := enu[0]
	var n := enu[1]
	var u := enu[2]
	return PackedFloat64Array([
		o[0] - sl * e - sp * cl * n + cp * cl * u,
		o[1] + cl * e - sp * sl * n + cp * sl * u,
		o[2] + cp * n + sp * u])


## Godot position of a geodetic point in the frame at (lat0, lon0, h0).
static func geodetic_to_local(lat: float, lon: float, h: float, lat0: float, lon0: float, h0: float) -> Vector3:
	var enu := ecef_to_enu(geodetic_to_ecef(lat, lon, h), lat0, lon0, h0)
	return Vector3(enu[0], enu[2], -enu[1])


## [lat, lon, h] of a Godot position in the frame at (lat0, lon0, h0).
static func local_to_geodetic(p: Vector3, lat0: float, lon0: float, h0: float) -> PackedFloat64Array:
	return ecef_to_geodetic(enu_to_ecef(PackedFloat64Array([p.x, -p.z, p.y]), lat0, lon0, h0))
