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
// Procedural detail near the camera (not data): breaks up the 10 m imagery when seen from a few metres. 0 = off.
uniform float detail_strength = 0.0;
uniform float detail_distance = 800.0;
// Water layer: coverage mask (1 = water) on its own grid. The surface is the terrain itself (the DEM is at water
// level there); only the shading changes: wave normals near the camera, low roughness, a darker colour.
uniform bool water_enabled = false;
uniform sampler2D water_map : filter_linear_mipmap, repeat_disable;
uniform float water_scale = 1.0; // height spacing / water spacing
uniform float water_samples = 1.0;
uniform vec3 water_deep : source_color = vec3(0.035, 0.11, 0.15);
uniform vec3 water_shallow : source_color = vec3(0.07, 0.19, 0.19);
uniform float wave_distance = 2500.0;
// Analysis overlay (viewshed etc.): RGBA blended by alpha over local x / z rectangle (x0, z0, width, depth).
uniform bool overlay_enabled = false;
uniform sampler2D overlay_map : source_color, filter_nearest, repeat_disable;
uniform vec4 overlay_rect;

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

// Value noise; the lattice wraps every 289 cells so the hash stays exact in float32 far from the origin.
float hash(vec2 c) {
	c = mod(c, 289.0);
	return fract(sin(dot(c, vec2(12.9898, 78.233))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 c = floor(p);
	vec2 f = p - c;
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(c), hash(c + vec2(1.0, 0.0)), f.x), mix(hash(c + vec2(0.0, 1.0)), hash(c + vec2(1.0)), f.x), f.y);
}

// Slope (dh/dx, dh/dz) of a sum of travelling sine waves at local position m (metres); deep-water dispersion
// w = sqrt(g k). Directions and wavelengths are spread so the pattern does not visibly repeat. Waves shorter than a
// few pixels (footprint `fp`, metres per pixel) fade out instead of aliasing into stripes; the caller turns the
// lost detail into roughness.
vec2 wave_slope(vec2 m, float t, float fp) {
	const vec4 WAVES[6] = vec4[](
		vec4(0.94, 0.34, 13.0, 0.16), vec4(0.62, 0.78, 7.3, 0.10), vec4(0.99, -0.12, 4.1, 0.06),
		vec4(0.37, 0.93, 2.3, 0.035), vec4(0.80, -0.60, 1.4, 0.02), vec4(-0.20, 0.98, 0.9, 0.012));
	vec2 s = vec2(0.0);
	for (int i = 0; i < 6; i++) {
		float len = WAVES[i].z;
		float keep = 1.0 - smoothstep(0.12 * len, 0.4 * len, fp);
		if (keep <= 0.0) {
			continue;
		}
		vec2 d = WAVES[i].xy;
		float k = 6.2831853 / len;
		float ph = k * dot(d, m) - sqrt(9.81 * k) * t + float(i) * 1.7;
		s += keep * WAVES[i].w * cos(ph) * d;
	}
	return s;
}

void fragment() {
	vec2 p = grid_pos;
	// Sample the normal from the mip whose texels are about one pixel, so distant slopes do not shimmer.
	float texels = max(length(dFdx(p)), length(dFdy(p)));
	float lvl = clamp(log2(max(texels, 1.0)), 0.0, float(normal_max_mip));
	int m0 = int(floor(lvl));
	vec3 n = normalize(mix(normal_mip(p, m0), normal_mip(p, min(m0 + 1, normal_max_mip)), fract(lvl)));
	NORMAL = normalize(mat3(VIEW_MATRIX) * mat3(MODEL_MATRIX) * n);
	vec3 albedo = texture(color_map, (p * color_scale + 0.5) / color_samples).rgb;
	if (detail_strength > 0.0) {
		float fade = 1.0 - smoothstep(detail_distance * 0.4, detail_distance, length(VERTEX));
		if (fade > 0.0) {
			vec2 m = p * spacing; // metres
			float dn = 0.5 * value_noise(m * 0.35) + 0.3 * value_noise(m * 1.7) + 0.2 * value_noise(m * 6.0);
			albedo *= mix(1.0, 0.7 + 0.6 * dn, detail_strength * fade);
		}
	}
	float roughness = 0.95;
	float specular = 0.2;
	if (water_enabled) {
		vec2 wuv = (p * water_scale + 0.5) / water_samples;
		float w = texture(water_map, wuv).r;
		// The bilinear coverage acts like a distance field: cut at 0.5 with a one-pixel ramp for a sharp shore.
		float mask = clamp((w - 0.5) / max(fwidth(w), 1e-4) + 0.5, 0.0, 1.0);
		if (mask > 0.0) {
			float dist = length(VERTEX);
			float near = 1.0 - smoothstep(wave_distance * 0.3, wave_distance, dist);
			vec2 m = p * spacing;
			float fp = max(length(dFdx(m)), length(dFdy(m)));
			near *= 1.0 - smoothstep(0.5, 3.0, fp); // all waves below pixel size: flat and rough
			// Patches of calmer and rougher water (tens of metres) break up the regular sum of sines.
			float gust = 0.35 + 1.1 * value_noise(m * 0.018 + vec2(TIME * 0.05, 0.0));
			vec2 slope = wave_slope(m, TIME, fp) * near * gust;
			vec3 wn = normalize(mix(n, normalize(vec3(-slope.x, 1.0, -slope.y)), mask));
			NORMAL = normalize(mat3(VIEW_MATRIX) * mat3(MODEL_MATRIX) * wn);
			// Shallow tint within ~40 m of the shore (coverage blurred by a coarser mip), imagery tone far away.
			float shore = 1.0 - textureLod(water_map, wuv, 3.0).r;
			vec3 wc = mix(water_deep, water_shallow, clamp(shore * 2.0, 0.0, 1.0));
			wc = mix(wc, albedo * 0.85, smoothstep(1500.0, 9000.0, dist) * 0.6);
			albedo = mix(albedo, wc, mask);
			roughness = mix(roughness, mix(0.04, 0.2, smoothstep(0.1, 2.0, fp)), mask);
			specular = mix(specular, 0.25, mask); // F0 = 0.02 for water
		}
	}
	if (overlay_enabled) {
		vec2 uv = (p * spacing - half_size - overlay_rect.xy) / overlay_rect.zw;
		if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)))) {
			vec4 o = texture(overlay_map, uv);
			albedo = mix(albedo, o.rgb, o.a);
		}
	}
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	SPECULAR = specular;
}
