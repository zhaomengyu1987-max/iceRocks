shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;

// LOW-SPEC variant (integrated GPU / Compatibility renderer).
// Same look as ice_surface.gdshader but the per-pixel procedural noise is replaced by
// pre-baked seamless procedural textures sampled triplanar in object space
// (built by res://tools/bake_lite_textures.gd). ~24 texture reads, almost no ALU.

group_uniforms Textures;
uniform sampler2D tex_a : filter_linear_mipmap_anisotropic, repeat_enable; // R fbm, G crack edge, B ridged, A mask
uniform sampler2D tex_n : filter_linear_mipmap_anisotropic, repeat_enable; // RG height gradient
group_uniforms Ice;
uniform vec3 ice_clear : source_color = vec3(0.42, 0.68, 0.95);
uniform vec3 ice_milky : source_color = vec3(0.90, 0.95, 1.0);
uniform vec3 ice_deep : source_color = vec3(0.02, 0.10, 0.28);
uniform float ice_roughness : hint_range(0.0, 1.0) = 0.16;
uniform float frost_amount : hint_range(0.0, 1.0) = 0.2;
group_uniforms Dust;
uniform vec3 dust_color : source_color = vec3(0.29, 0.24, 0.20);
uniform vec3 dust_color_warm : source_color = vec3(0.48, 0.35, 0.24);
uniform float dust_amount : hint_range(0.0, 1.0) = 0.5;
group_uniforms Relief;
uniform float bump_strength = 1.0;
uniform float crack_amount : hint_range(0.0, 1.0) = 0.8;
uniform float seed = 11.3;
group_uniforms;

varying vec3 v_pos;
varying vec3 v_nrm;
varying vec3 v_col;

void vertex() {
	v_pos = VERTEX;
	v_nrm = NORMAL;
	v_col = COLOR.rgb;
}

vec3 tri_w(vec3 n) {
	vec3 w = pow(abs(n), vec3(4.0));
	return w / (w.x + w.y + w.z);
}

vec4 tri_a(vec3 p, vec3 w) {
	return texture(tex_a, p.zy) * w.x + texture(tex_a, p.xz) * w.y + texture(tex_a, p.xy) * w.z;
}

vec3 tri_grad(vec3 p, vec3 w) {
	vec2 gx = (texture(tex_n, p.zy).rg - 0.5) * 2.0;
	vec2 gy = (texture(tex_n, p.xz).rg - 0.5) * 2.0;
	vec2 gz = (texture(tex_n, p.xy).rg - 0.5) * 2.0;
	return w.x * vec3(0.0, gx.y, gx.x) + w.y * vec3(gy.x, 0.0, gy.y) + w.z * vec3(gz.x, gz.y, 0.0);
}

void fragment() {
	vec3 P = v_pos + vec3(seed);
	vec3 Ng = normalize(v_nrm);
	vec3 w = tri_w(Ng);
	vec3 up = normalize(v_pos / vec3(1.45, 0.88, 1.0));
	float slope = 1.0 - clamp(dot(Ng, up), 0.0, 1.0);
	float cav = v_col.r;
	float crack_geo = v_col.g;

	// colour / mask samples at three scales (also give the fracture networks)
	vec4 a1 = tri_a(P * 0.42, w);
	vec4 a2 = tri_a(P * 1.6 + 0.37, w);
	vec4 a3 = tri_a(P * 6.0 + 0.71, w);
	float macro = a1.r;
	float meso = a2.r;
	float dfine = (a3.r - 0.5) * 2.0;

	// dust crust
	float score = macro * 0.9 + meso * 0.35 + 0.55 * cav - 1.7 * slope + (dust_amount - 0.5) * 1.5;
	float dust = smoothstep(0.55, 0.85, score);
	dust = clamp(dust * smoothstep(-0.55, 0.15, dfine + dust * 1.1 - 0.35), 0.0, 1.0);

	// relief (baked height gradients, 5 octaves of scale)
	vec3 g = vec3(0.0);
	g += 0.30 * tri_grad(P * 0.42, w);
	g += 0.45 * tri_grad(P * 1.6 + 0.37, w);
	g += 0.55 * tri_grad(P * 6.0 + 0.71, w);
	g += 0.60 * tri_grad(P * 24.0 + 0.13, w);
	g += 0.55 * tri_grad(P * 96.0 + 0.57, w);
	vec3 grad = g * 0.5 * bump_strength * mix(0.75, 1.9, dust);

	// fractures (three networks)
	float ca = crack_amount;
	float m1 = smoothstep(0.35, 0.60, a2.a);
	float m2 = max(smoothstep(0.30, 0.58, a3.a), 0.25);
	float core = (1.0 - smoothstep(0.0, 0.09, a1.g)) * m1 * ca;
	core = max(core, (1.0 - smoothstep(0.0, 0.11, a2.g)) * m2 * ca);
	core = max(core, (1.0 - smoothstep(0.0, 0.14, a3.g)) * 0.7 * ca);
	float halo = (1.0 - smoothstep(0.0, 0.22, a1.g)) * m1 * ca;
	halo = max(halo, (1.0 - smoothstep(0.0, 0.30, a2.g)) * m2 * ca * 0.8);
	core = max(core, crack_geo * 0.6);

	// strata on steep faces
	float strata_c = dot(P, normalize(vec3(0.3, 1.0, 0.2))) * 38.0 + (macro - 0.5) * 12.0 + (meso - 0.5) * 3.0;
	float strata = smoothstep(0.35, 0.65, sin(strata_c) * 0.5 + 0.5) * smoothstep(0.15, 0.55, slope);

	// albedo
	float milky = smoothstep(0.30, 0.75, macro * 0.7 + meso * 0.4 - 0.1);
	vec3 ice = mix(ice_clear, ice_milky, milky);
	ice = mix(ice, ice_clear * 0.55, strata * 0.55);
	float frost = frost_amount * smoothstep(0.35, 0.8, meso + cav * 0.5 - slope * 0.6 + dfine * 0.25);
	ice = mix(ice, vec3(0.94, 0.97, 1.0), frost * 0.8);
	ice = mix(ice, vec3(0.93, 0.97, 1.0), halo * 0.45 * (1.0 - frost));
	ice = mix(ice, ice_deep, core * 0.9);

	vec3 dcol = mix(dust_color, dust_color_warm, smoothstep(0.35, 0.8, meso) * 0.8);
	dcol *= 0.55 + 0.9 * (dfine * 0.5 + 0.5);
	dcol = mix(dcol, dust_color * 0.5, core);
	vec3 albedo = mix(ice, dcol, dust);

	float rough_ice = ice_roughness + 0.28 * smoothstep(0.2, 0.9, meso + 0.15 * dfine) + 0.55 * frost + 0.25 * halo;
	float roughness = clamp(mix(rough_ice, 0.93, dust), 0.05, 1.0);

	vec3 tg = grad - dot(grad, Ng) * Ng;
	vec3 nobj = normalize(Ng - tg);
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(nobj, 0.0)).xyz);

	ALBEDO = albedo;
	METALLIC = 0.0;
	ROUGHNESS = roughness;
	SPECULAR = mix(0.55, 0.2, dust);
	AO = mix(1.0, 0.45, clamp(cav * 0.8 + core * 0.5, 0.0, 1.0));
	AO_LIGHT_AFFECT = 0.7;
}
