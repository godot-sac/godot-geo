// Low-poly trees of GeoTreeLayer (MultiMesh). UV.x: 0 = trunk, 1 = foliage; UV.y = wind sway weight. COLOR is the
// instance colour (Godot multiplies it into the white vertex colour): the foliage tint.
shader_type spatial;
render_mode cull_back;

uniform vec3 trunk_color : source_color = vec3(0.24, 0.18, 0.13);
uniform float wind_strength = 0.015;

varying float foliage;
varying vec3 tint;

void vertex() {
	foliage = UV.x;
	tint = COLOR.rgb;
	vec3 origin = MODEL_MATRIX[3].xyz;
	float phase = dot(origin.xz, vec2(0.13, 0.07)) + float(INSTANCE_ID) * 0.37;
	VERTEX.x += sin(TIME * 1.3 + phase) * wind_strength * UV.y;
	VERTEX.z += cos(TIME * 1.1 + phase) * wind_strength * UV.y;
}

void fragment() {
	ALBEDO = foliage > 0.5 ? tint : trunk_color;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
	// Leaves let some light through; keep the shaded side from going black.
	BACKLIGHT = foliage > 0.5 ? tint * 0.25 : vec3(0.0);
}
