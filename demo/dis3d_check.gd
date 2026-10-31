class_name Dis3DCheck
extends RefCounted
## Automatic plausibility check for the 3D DIS demo (dis3d.gd --check <seconds>): fed with every unit at a fixed
## rate, it looks for what a tester would spot by eye and reports it per unit:
##   jump      the unit moved much farther (or less) than its speed allows between two samples
##   reverse   a moving unit went against its heading
##   buried    a land unit is below the terrain;  floating: above it
##   low       an aircraft is closer than LOW_AGL to the ground
##   gap       no PDU from a remote unit for longer than GAP_SECONDS (heartbeat is 5 s)

const JUMP_MIN := 30.0  # metres of unexplained movement between samples before it counts
const LAND_TOLERANCE := 0.5
const LOW_AGL := 50.0
const GAP_SECONDS := 6.0
## Samples before this are ignored: the first frames stall while the terrain and shaders load.
const WARMUP := 3.0

var samples := 0
var _units := {}  # key -> {marking, source, air, n, last, issues: {kind: [count, worst, first_t]}, agl_min, agl_max}


## `units` as built by dis3d.gd (_unit_dict); `t` in seconds.
func add(units: Array, t: float, terrain: GeoTerrain) -> void:
	if t < WARMUP:
		return
	samples += 1
	for u: Dictionary in units:
		var node: Node3D = u.node
		var p := node.global_position
		var s: Dictionary = _units.get(u.key, {})
		if s.is_empty():
			s = {"marking": u.marking, "source": u.source.split(" ")[0], "air": u.air, "n": 0, "issues": {},
					"agl_min": INF, "agl_max": -INF, "last": null}
			_units[u.key] = s
		s.n += 1
		var on_terrain := not is_nan(terrain.height_at(p.x, p.z))
		if on_terrain:
			s.agl_min = minf(s.agl_min, u.agl)
			s.agl_max = maxf(s.agl_max, u.agl)
			if not u.air:
				if u.agl < -LAND_TOLERANCE:
					_issue(s, "buried", -u.agl, t)
				elif u.agl > LAND_TOLERANCE:
					_issue(s, "floating", u.agl, t)
			elif u.agl < LOW_AGL:
				_issue(s, "low", u.agl, t)
		if node is DisRemoteEntity:
			var age := Time.get_ticks_usec() / 1.0e6 - (node as DisRemoteEntity).get_last_update_time()
			if age > GAP_SECONDS:
				_issue(s, "gap", age, t)
		if s.last != null:
			var dt: float = t - s.last.t
			var moved := Vector2(p.x - s.last.p.x, p.z - s.last.p.z)
			var expected: float = 0.5 * (u.speed + s.last.speed) * dt
			var excess := absf(moved.length() - expected)
			if excess > maxf(JUMP_MIN, 0.5 * expected):
				_issue(s, "jump", excess, t)
			if u.speed > 2.0 and moved.length() > 0.5 * expected and expected > 0.0:
				var forward := Vector2(sin(u.heading), -cos(u.heading))
				if moved.normalized().dot(forward) < -0.5:
					_issue(s, "reverse", moved.length(), t)
		s.last = {"t": t, "p": p, "speed": u.speed}


func _issue(s: Dictionary, kind: String, value: float, t: float) -> void:
	var i: Array = s.issues.get(kind, [0, 0.0, t])
	i[0] += 1
	i[1] = maxf(i[1], value)
	s.issues[kind] = i


func problem_count() -> int:
	var n := 0
	for s: Dictionary in _units.values():
		n += s.issues.size()
	return n


## Human-readable report, one line per unit; issues as kind xcount (worst, first at t).
func report() -> String:
	var lines := PackedStringArray(["check: %d units, %d samples" % [_units.size(), samples]])
	var keys := _units.keys()
	keys.sort()
	for key: String in keys:
		var s: Dictionary = _units[key]
		var parts := PackedStringArray()
		for kind: String in s.issues:
			var i: Array = s.issues[kind]
			parts.append("%s x%d (worst %.1f, first at %.1f s)" % [kind, i[0], i[1], i[2]])
		var agl := "agl %.1f..%.1f m" % [s.agl_min, s.agl_max] if s.agl_min != INF else "off terrain"
		lines.append("  %-6s %-7s %-4s %s  %s" % [s.marking, s.source, "air" if s.air else "land", agl,
				"OK" if parts.is_empty() else ", ".join(parts)])
	lines.append("check: %s" % ("no problems" if problem_count() == 0 else "%d problem kinds" % problem_count()))
	return "\n".join(lines)


func to_dict() -> Dictionary:
	var out := {}
	for key: String in _units:
		var s: Dictionary = _units[key]
		out[key] = {"marking": s.marking, "source": s.source, "air": s.air, "samples": s.n,
				"agl_min": s.agl_min if s.agl_min != INF else null,
				"agl_max": s.agl_max if s.agl_max != -INF else null, "issues": s.issues}
	return {"samples": samples, "units": out}
