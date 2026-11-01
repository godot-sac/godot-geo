## Draws a GeoTerrainPackage. GeoTerrain owns loading, queries, collision and alignment; a backend only turns the
## height grid into pixels. `surface_height` must return the height of the surface the backend draws at its finest
## level of detail, so queries, collision and the picture agree (a test checks this for every backend).
class_name GeoTerrainBackend
extends Node3D

var package: GeoTerrainPackage


## Builds the renderable terrain. Called once, after the node is in the tree.
func build(_package: GeoTerrainPackage) -> void:
	package = _package


## Called every frame with the camera position in this node's local space.
func update_view(_camera_local: Vector3) -> void:
	pass


## Height at local x, z (inside the package; the caller checks bounds).
func surface_height(_x: float, _z: float) -> float:
	return NAN


func set_cast_shadows(_mode: GeometryInstance3D.ShadowCastingSetting) -> void:
	pass


## Procedural ground detail near the camera, 0 (off) to 1; optional for a backend.
func set_ground_detail(_strength: float) -> void:
	pass


## RGBA texture blended over the terrain colour inside `rect` (local x / z); null removes it.
func set_overlay(_texture: Texture2D, _rect: Rect2) -> void:
	pass
