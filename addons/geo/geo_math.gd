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


# --- UTM / MGRS (WGS84) ---------------------------------------------------------------------------------------
# Transverse Mercator by the Krueger series to 6th order in the third flattening n (Karney 2011, "Transverse Mercator
# with an accuracy of a few nanometers", eqs. 10-14, 35, 36): nanometres inside a UTM zone.

const UTM_K0 := 0.9996
const UTM_FALSE_EASTING := 500000.0
const UTM_FALSE_NORTHING_SOUTH := 10000000.0
const TM_N := F / (2.0 - F)
const TM_N2 := TM_N * TM_N
const TM_N3 := TM_N2 * TM_N
const TM_N4 := TM_N3 * TM_N
const TM_N5 := TM_N4 * TM_N
const TM_N6 := TM_N5 * TM_N
## Rectifying radius.
const TM_A1 := A / (1.0 + TM_N) * (1.0 + TM_N2 / 4.0 + TM_N4 / 64.0 + TM_N6 / 256.0)
const TM_ALPHA: Array[float] = [
	TM_N / 2.0 - 2.0 * TM_N2 / 3.0 + 5.0 * TM_N3 / 16.0 + 41.0 * TM_N4 / 180.0 - 127.0 * TM_N5 / 288.0
		+ 7891.0 * TM_N6 / 37800.0,
	13.0 * TM_N2 / 48.0 - 3.0 * TM_N3 / 5.0 + 557.0 * TM_N4 / 1440.0 + 281.0 * TM_N5 / 630.0
		- 1983433.0 * TM_N6 / 1935360.0,
	61.0 * TM_N3 / 240.0 - 103.0 * TM_N4 / 140.0 + 15061.0 * TM_N5 / 26880.0 + 167603.0 * TM_N6 / 181440.0,
	49561.0 * TM_N4 / 161280.0 - 179.0 * TM_N5 / 168.0 + 6601661.0 * TM_N6 / 7257600.0,
	34729.0 * TM_N5 / 80640.0 - 3418889.0 * TM_N6 / 1995840.0,
	212378941.0 * TM_N6 / 319334400.0]
const TM_BETA: Array[float] = [
	TM_N / 2.0 - 2.0 * TM_N2 / 3.0 + 37.0 * TM_N3 / 96.0 - TM_N4 / 360.0 - 81.0 * TM_N5 / 512.0
		+ 96199.0 * TM_N6 / 604800.0,
	TM_N2 / 48.0 + TM_N3 / 15.0 - 437.0 * TM_N4 / 1440.0 + 46.0 * TM_N5 / 105.0 - 1118711.0 * TM_N6 / 3870720.0,
	17.0 * TM_N3 / 480.0 - 37.0 * TM_N4 / 840.0 - 209.0 * TM_N5 / 4480.0 + 5569.0 * TM_N6 / 90720.0,
	4397.0 * TM_N4 / 161280.0 - 11.0 * TM_N5 / 504.0 - 830251.0 * TM_N6 / 7257600.0,
	4583.0 * TM_N5 / 161280.0 - 108847.0 * TM_N6 / 3991680.0,
	20648693.0 * TM_N6 / 638668800.0]

const MGRS_BANDS := "CDEFGHJKLMNPQRSTUVWX"
const MGRS_COLUMN_SETS: Array[String] = ["ABCDEFGH", "JKLMNPQR", "STUVWXYZ"]
const MGRS_ROWS := "ABCDEFGHJKLMNPQRSTUV"


## Longitude of the central meridian of a UTM zone (1..60), degrees.
static func utm_central_meridian(zone: int) -> float:
	return zone * 6.0 - 183.0


## UTM zone (1..60) of a point, with the Norway (32V) and Svalbard (31X, 33X, 35X, 37X) exceptions.
static func utm_zone(lat: float, lon: float) -> int:
	var l := fposmod(lon + 180.0, 360.0) - 180.0
	var zone := mini(int(floor((l + 180.0) / 6.0)) + 1, 60)
	if lat >= 56.0 and lat < 64.0 and l >= 3.0 and l < 12.0:
		return 32
	if lat >= 72.0 and lat < 84.0:
		if l >= 0.0 and l < 9.0:
			return 31
		if l >= 9.0 and l < 21.0:
			return 33
		if l >= 21.0 and l < 33.0:
			return 35
		if l >= 33.0 and l < 42.0:
			return 37
	return zone


## Transverse Mercator (k0 applied, no false origin): [x, y] in metres for latitude phi and longitude from the central
## meridian lam, both in radians.
static func _tm_forward(phi: float, lam: float) -> PackedFloat64Array:
	var e := sqrt(E2)
	var tau := tan(phi)
	var sigma := sinh(e * atanh(e * tau / sqrt(1.0 + tau * tau)))
	var tau_p := tau * sqrt(1.0 + sigma * sigma) - sigma * sqrt(1.0 + tau * tau)
	var xi_p := atan2(tau_p, cos(lam))
	var eta_p := asinh(sin(lam) / sqrt(tau_p * tau_p + cos(lam) * cos(lam)))
	var xi := xi_p
	var eta := eta_p
	for j in range(1, 7):
		var a: float = TM_ALPHA[j - 1]
		xi += a * sin(2.0 * j * xi_p) * cosh(2.0 * j * eta_p)
		eta += a * cos(2.0 * j * xi_p) * sinh(2.0 * j * eta_p)
	return PackedFloat64Array([UTM_K0 * TM_A1 * eta, UTM_K0 * TM_A1 * xi])


## Inverse of _tm_forward: [phi, lam] in radians.
static func _tm_inverse(x: float, y: float) -> PackedFloat64Array:
	var xi := y / (UTM_K0 * TM_A1)
	var eta := x / (UTM_K0 * TM_A1)
	var xi_p := xi
	var eta_p := eta
	for j in range(1, 7):
		var b: float = TM_BETA[j - 1]
		xi_p -= b * sin(2.0 * j * xi) * cosh(2.0 * j * eta)
		eta_p -= b * cos(2.0 * j * xi) * sinh(2.0 * j * eta)
	var tau_p := tan(asin(sin(xi_p) / cosh(eta_p)))
	# Newton iteration for tau (Karney 2011, eqs. 19-21).
	var e := sqrt(E2)
	var tau := tau_p
	for i in 8:
		var sqt := sqrt(1.0 + tau * tau)
		var sigma := sinh(e * atanh(e * tau / sqt))
		var tau_i := tau * sqrt(1.0 + sigma * sigma) - sigma * sqt
		var delta := (tau_p - tau_i) / sqrt(1.0 + tau_i * tau_i) * (1.0 + (1.0 - E2) * tau * tau) \
				/ ((1.0 - E2) * sqt)
		tau += delta
		if absf(delta) < 1e-15 * maxf(1.0, absf(tau)):
			break
	return PackedFloat64Array([atan(tau), atan2(sinh(eta_p), cos(xi_p))])


## UTM coordinates of a WGS84 point: {"zone": int, "north": bool, "easting": float, "northing": float} (metres, false
## easting 500000 and, in the south, false northing 10000000 included). Valid for -80 <= lat < 84; returns an empty
## Dictionary outside that range (UPS polar areas are not supported) or for non-finite input.
static func geodetic_to_utm(lat: float, lon: float) -> Dictionary:
	if not (lat >= -80.0 and lat < 84.0 and is_finite(lon)):
		return {}
	var zone := utm_zone(lat, lon)
	var dlon := fposmod(lon - utm_central_meridian(zone) + 180.0, 360.0) - 180.0
	var xy := _tm_forward(deg_to_rad(lat), deg_to_rad(dlon))
	var north := lat >= 0.0
	return {
		"zone": zone, "north": north, "easting": UTM_FALSE_EASTING + xy[0],
		"northing": xy[1] + (0.0 if north else UTM_FALSE_NORTHING_SOUTH)}


## [lat, lon] in degrees of a UTM coordinate (longitude in [-180, 180)). Empty array for a zone outside 1..60 or
## non-finite input.
static func utm_to_geodetic(zone: int, north: bool, easting: float, northing: float) -> PackedFloat64Array:
	if zone < 1 or zone > 60 or not is_finite(easting) or not is_finite(northing):
		return PackedFloat64Array()
	var y := northing - (0.0 if north else UTM_FALSE_NORTHING_SOUTH)
	var pl := _tm_inverse(easting - UTM_FALSE_EASTING, y)
	var lon := fposmod(rad_to_deg(pl[1]) + utm_central_meridian(zone) + 180.0, 360.0) - 180.0
	return PackedFloat64Array([rad_to_deg(pl[0]), lon])


## MGRS string without spaces, e.g. "36SVK8801220374" (zone, latitude band, 100 km square, then `digits` digits of
## easting and of northing, 0..5; 5 digits = 1 m). Coordinates are truncated, not rounded, as MGRS requires. Valid for
## -80 <= lat < 84 (UTM area, 100 km square letters of the WGS84 "AA" scheme); returns "" outside (UPS polar areas are
## not supported).
static func geodetic_to_mgrs(lat: float, lon: float, digits := 5) -> String:
	var utm := geodetic_to_utm(lat, lon)
	if utm.is_empty():
		return ""
	digits = clampi(digits, 0, 5)
	var zone: int = utm["zone"]
	var e := int(floor(utm["easting"]))
	var n := int(floor(utm["northing"]))
	var band := clampi(int(floor((lat + 80.0) / 8.0)), 0, 19)
	var col: String = MGRS_COLUMN_SETS[(zone - 1) % 3][e / 100000 - 1]
	var row: String = MGRS_ROWS[(n / 100000 + (5 if zone % 2 == 0 else 0)) % 20]
	var out := "%02d%s%s%s" % [zone, MGRS_BANDS[band], col, row]
	if digits > 0:
		var unit := int(pow(10.0, 5 - digits))
		out += String.num_int64((e % 100000) / unit).pad_zeros(digits)
		out += String.num_int64((n % 100000) / unit).pad_zeros(digits)
	return out


## [lat, lon] of the CENTRE of the square an MGRS string refers to (the whole 100 km square for no digits, a
## 10^(5-digits) m square otherwise). Spaces and lower case are accepted; the latitude band picks the right 2000 km
## northing cycle. Empty array on invalid input.
static func mgrs_to_geodetic(mgrs: String) -> PackedFloat64Array:
	var s := mgrs.replace(" ", "").to_upper()
	var i := 0
	while i < mini(2, s.length()) and s.unicode_at(i) >= 48 and s.unicode_at(i) <= 57:
		i += 1
	if i == 0 or s.length() < i + 3:
		return PackedFloat64Array()
	var zone := s.substr(0, i).to_int()
	var band := MGRS_BANDS.find(s[i])
	var col := MGRS_COLUMN_SETS[(zone - 1) % 3].find(s[i + 1]) if zone >= 1 else -1
	var row := MGRS_ROWS.find(s[i + 2])
	var num := s.substr(i + 3)
	if zone < 1 or zone > 60 or band < 0 or col < 0 or row < 0 or num.length() % 2 != 0 or num.length() > 10:
		return PackedFloat64Array()
	for k in num.length():
		if num.unicode_at(k) < 48 or num.unicode_at(k) > 57:
			return PackedFloat64Array()
	var digits := num.length() / 2
	var unit := pow(10.0, 5 - digits)
	var e := (col + 1) * 100000.0 + (num.substr(0, digits).to_int() if digits > 0 else 0) * unit + unit / 2.0
	var n_in_cycle := posmod(row - (5 if zone % 2 == 0 else 0), 20) * 100000.0 \
			+ (num.substr(digits).to_int() if digits > 0 else 0) * unit + unit / 2.0
	# The 2000 km northing cycle nearest to the middle of the latitude band (a band is < 1000 km from it).
	var north := band >= 10
	var lat_mid := -80.0 + band * 8.0 + (6.0 if band == 19 else 4.0)
	var n_mid := _tm_forward(deg_to_rad(lat_mid), 0.0)[1] + (0.0 if north else UTM_FALSE_NORTHING_SOUTH)
	var n := n_in_cycle + 2000000.0 * roundf((n_mid - n_in_cycle) / 2000000.0)
	return utm_to_geodetic(zone, north, e, n)
