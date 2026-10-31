// Phase 0 prototype terrain shader: heights from an R32F texture (manual bilinear, R32F is not filterable
// everywhere), colour from the Sentinel-2 texture, per-pixel normals from the height field.
shader_type spatial;
render_mode cull_back;

uniform sampler2D height_map : filter_nearest, repeat_disable;
uniform sampler2D color_map : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float half_size;
uniform float spacing;
uniform int samples;
uniform float skirt_depth;

varying vec3 world_pos;

float height_at(vec2 xz) {
	vec2 p = clamp((xz + half_size) / spacing, vec2(0.0), vec2(float(samples - 1)));
	ivec2 i = min(ivec2(floor(p)), ivec2(samples - 2));
	vec2 f = p - vec2(i);
	float a = texelFetch(height_map, i, 0).r;
	float b = texelFetch(height_map, i + ivec2(1, 0), 0).r;
	float c = texelFetch(height_map, i + ivec2(0, 1), 0).r;
	float d = texelFetch(height_map, i + ivec2(1, 1), 0).r;
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y = height_at(w.xz) - UV2.x * skirt_depth;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 xz = world_pos.xz;
	float e = spacing;
	float hx = height_at(xz + vec2(e, 0.0)) - height_at(xz - vec2(e, 0.0));
	float hz = height_at(xz + vec2(0.0, e)) - height_at(xz - vec2(0.0, e));
	vec3 n = normalize(vec3(-hx, 2.0 * e, -hz));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	vec2 uv = ((xz + half_size) / spacing + 0.5) / float(samples);
	ALBEDO = texture(color_map, uv).rgb;
	ROUGHNESS = 0.95;
	SPECULAR = 0.2;
}
