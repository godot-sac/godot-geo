// Building roofs of GeoBuildingLayer. COLOR = roof colour (linear); UV = position in metres (x / z), used for a
// faint tile / gravel texture near the camera.
shader_type spatial;
render_mode cull_back;

float hash(vec2 c) {
	c = mod(c, 289.0);
	return fract(sin(dot(c, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 cell = floor(UV / vec2(0.35, 0.25));
	float detail = 1.0 - smoothstep(0.3, 1.0, max(fwidth(UV.x), fwidth(UV.y)) / 0.25);
	float n = mix(1.0, 0.88 + 0.24 * hash(cell), detail);
	ALBEDO = COLOR.rgb * n;
	ROUGHNESS = 0.8;
	SPECULAR = 0.3;
}
