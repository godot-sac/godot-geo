// Far trees of GeoTreeLayer: a unit quad (x -0.5..0.5, y 0..1) per instance, turned about the vertical towards the
// camera; the crown is drawn analytically (an ellipse per species with a leafy, hashed edge and a sphere-like normal)
// so no texture is needed. INSTANCE_CUSTOM.r = species (0 broadleaf, 1 umbrella pine, 2 cypress); COLOR = tint.
shader_type spatial;
render_mode cull_disabled, skip_vertex_transform;

uniform vec3 trunk_color : source_color = vec3(0.24, 0.18, 0.13);

varying vec2 q;
varying float species;
varying vec3 tint;
varying vec3 right_v;
varying vec3 facing_v;
varying float seed;

float hash(vec2 c) {
	c = mod(c, 289.0);
	return fract(sin(dot(c, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	q = VERTEX.xy;
	species = INSTANCE_CUSTOM.r;
	tint = COLOR.rgb;
	vec3 origin = MODEL_MATRIX[3].xyz;
	float w = length(MODEL_MATRIX[0].xyz);
	float h = length(MODEL_MATRIX[1].xyz);
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 to_cam = vec3(cam.x - origin.x, 0.0, cam.z - origin.z);
	to_cam = length(to_cam) > 1e-3 ? normalize(to_cam) : vec3(0.0, 0.0, 1.0);
	vec3 right = vec3(to_cam.z, 0.0, -to_cam.x);
	vec3 world = origin + right * VERTEX.x * w + vec3(0.0, VERTEX.y * h, 0.0);
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	right_v = normalize((VIEW_MATRIX * vec4(right, 0.0)).xyz);
	facing_v = normalize((VIEW_MATRIX * vec4(to_cam, 0.0)).xyz);
	NORMAL = facing_v;
	seed = fract(origin.x * 0.137 + origin.z * 0.071);
}

void fragment() {
	vec2 c;
	vec2 r;
	if (species < 0.5) {
		c = vec2(0.0, 0.66);
		r = vec2(0.46, 0.34);
	} else if (species < 1.5) {
		c = vec2(0.0, 0.86);
		r = vec2(0.5, 0.15);
	} else {
		c = vec2(0.0, 0.55);
		r = vec2(0.5, 0.47);
	}
	vec2 d = (q - c) / r;
	float rr = length(d);
	float angle = atan(d.y, d.x);
	float edge = 1.0 - 0.18 * hash(vec2(floor(angle * 4.0) + seed * 50.0, 1.0)) - 0.1 * hash(floor(q * 24.0));
	bool trunk = abs(q.x) < 0.05 && q.y < c.y;
	if (rr > edge && !trunk) {
		discard;
	}
	if (rr <= edge) {
		vec3 up_v = normalize(cross(facing_v, right_v));
		float nz = sqrt(max(0.0, 1.0 - min(rr * rr, 1.0)));
		NORMAL = normalize(right_v * d.x + up_v * d.y * 0.8 + facing_v * (nz + 0.2));
		ALBEDO = tint * (0.8 + 0.4 * hash(floor(q * 18.0) + seed));
		BACKLIGHT = tint * 0.25;
	} else {
		ALBEDO = trunk_color;
	}
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
}
