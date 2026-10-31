// CDLOD terrain patch (Strugar 2009). Every selected quadtree node draws the same (PATCH+1)^2 grid; the vertex
// shader places it from `node_data` and moves odd vertices onto the next coarser grid as the camera gets farther
// (geomorphing), so neighbouring levels meet without cracks or popping. Heights come from the R32F package grid,
// read with texelFetch (float textures are not filterable everywhere) and interpolated by hand.
shader_type spatial;
render_mode cull_back;

uniform sampler2D height_map : filter_nearest_mipmap, repeat_disable;
uniform sampler2D color_map : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float spacing;
uniform float half_size;
uniform int cells;
uniform int max_level;
uniform int normal_max_mip;
uniform float lod_range0;
uniform float morph_start = 0.7;
uniform vec3 lod_camera;
uniform float color_scale; // height spacing / colour spacing
uniform float color_samples;

// Node origin (column, row), samples per patch cell, level.
instance uniform vec4 node_data;

varying vec2 grid_pos;

float height_mip(vec2 p, int m) {
	ivec2 size = textureSize(height_map, m);
	vec2 q = clamp(p / float(1 << m), vec2(0.0), vec2(size - 1));
	ivec2 i = min(ivec2(floor(q)), size - 2);
	vec2 f = q - vec2(i);
	float a = texelFetch(height_map, i, m).r;
	float b = texelFetch(height_map, i + ivec2(1, 0), m).r;
	float c = texelFetch(height_map, i + ivec2(0, 1), m).r;
	float d = texelFetch(height_map, i + ivec2(1, 1), m).r;
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec3 local_pos(vec2 p) {
	return vec3(p.x * spacing - half_size, height_mip(p, 0), p.y * spacing - half_size);
}

void vertex() {
	vec2 g = VERTEX.xz;
	float step = node_data.z;
	vec2 hi = vec2(float(cells));
	vec2 p = clamp(node_data.xy + g * step, vec2(0.0), hi);
	int level = int(node_data.w);
	if (level < max_level) {
		float range = lod_range0 * exp2(float(level));
		float d = distance(local_pos(p), lod_camera);
		float k = clamp((d - range * morph_start) / (range * (1.0 - morph_start)), 0.0, 1.0);
		p = clamp(node_data.xy + (g - mod(g, 2.0) * k) * step, vec2(0.0), hi);
	}
	grid_pos = p;
	VERTEX = local_pos(p);
}

vec3 normal_mip(vec2 p, int m) {
	float e = exp2(float(m));
	float hx = height_mip(p + vec2(e, 0.0), m) - height_mip(p - vec2(e, 0.0), m);
	float hz = height_mip(p + vec2(0.0, e), m) - height_mip(p - vec2(0.0, e), m);
	return normalize(vec3(-hx, 2.0 * e * spacing, -hz));
}

void fragment() {
	vec2 p = grid_pos;
	// Sample the normal from the mip whose texels are about one pixel, so distant slopes do not shimmer.
	float texels = max(length(dFdx(p)), length(dFdy(p)));
	float lvl = clamp(log2(max(texels, 1.0)), 0.0, float(normal_max_mip));
	int m0 = int(floor(lvl));
	vec3 n = normalize(mix(normal_mip(p, m0), normal_mip(p, min(m0 + 1, normal_max_mip)), fract(lvl)));
	NORMAL = normalize(mat3(VIEW_MATRIX) * mat3(MODEL_MATRIX) * n);
	ALBEDO = texture(color_map, (p * color_scale + 0.5) / color_samples).rgb;
	ROUGHNESS = 0.95;
	SPECULAR = 0.2;
}
