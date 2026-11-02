@tool
## Base class of the things a GeoTerrain draws on top of its surface from package layers (trees, buildings, roads).
## A layer is a child of the GeoTerrain; it works in the package frame (x east, z south, y up relative to the
## package origin), so its own position only carries the terrain's vertical alignment offset.
class_name GeoTerrainLayer
extends Node3D

var terrain: GeoTerrain
var package: GeoTerrainPackage


## Called by GeoTerrain after a package is loaded (and with null when it is cleared).
func setup(t: GeoTerrain) -> void:
	terrain = t
	package = t.package if t else null
	position = Vector3(0.0, t.origin_offset if t else 0.0, 0.0)
	_rebuild()


## Called every frame with the camera position in the package frame.
func update_view(_camera: Vector3) -> void:
	pass


## Whether the package has the data this layer needs.
func has_data() -> bool:
	return false


func _rebuild() -> void:
	pass


## Surface height in the package frame (NAN outside).
func ground(x: float, z: float) -> float:
	return terrain.surface_height_local(x, z)


## Deterministic hash of three integers to [0, 1): the same tree, roof or colour on every run and machine.
static func rand3(a: int, b: int, c: int) -> float:
	var h := (a * 73856093) ^ (b * 19349663) ^ (c * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / 16777216.0
