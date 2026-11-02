// Building walls of GeoBuildingLayer. UV = (metres along the wall, metres above the building base); COLOR = facade
// colour (linear). Windows are drawn procedurally on 3 m floors and ~3.2 m bays; where a window would be smaller
// than about two pixels the pattern fades into its average so distant facades do not shimmer.
shader_type spatial;
render_mode cull_back;

uniform float floor_height = 3.0;
uniform float bay_width = 3.2;
uniform vec3 window_color : source_color = vec3(0.16, 0.19, 0.22);

float box(vec2 f, vec2 lo, vec2 hi, vec2 aa) {
	vec2 a = smoothstep(lo - aa, lo + aa, f) * (1.0 - smoothstep(hi - aa, hi + aa, f));
	return a.x * a.y;
}

void fragment() {
	vec2 uv = UV;
	vec2 cell = vec2(bay_width, floor_height);
	vec2 f = fract(uv / cell);
	vec2 aa = fwidth(uv / cell);
	// Windows: 50 % of the bay wide, 1.4 m tall at 0.9 m sill; none below 0.6 m (plinth) and on very low walls.
	float win = box(f, vec2(0.25, 0.3), vec2(0.75, 0.77), aa * 1.5) * step(0.6, uv.y);
	float detail = 1.0 - smoothstep(0.25, 0.6, max(aa.x, aa.y));
	win = mix(0.36 * 0.5 * step(0.6, uv.y), win, detail);
	// Slight floor-to-floor and bay-to-bay variation of the plaster; a darker plinth.
	float row = floor(uv.y / floor_height);
	float vary = 0.94 + 0.06 * fract(sin(row * 12.9898 + floor(uv.x / bay_width) * 4.1414) * 43758.5453);
	vec3 wall = COLOR.rgb * mix(1.0, vary, detail) * mix(0.75, 1.0, smoothstep(0.0, 0.6, uv.y));
	ALBEDO = mix(wall, window_color, win);
	ROUGHNESS = mix(0.85, 0.15, win);
	SPECULAR = mix(0.3, 0.6, win);
}
