shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Fully procedural comet-nucleus ice block (object-space, no UV / textures).
// Target: gl_compatibility (no SSS -> transmission faked with BACKLIGHT).
// Physical story: an opaque, dust-laden nucleus. Weathered crust = dirty,
// desaturated ice with dark impurity speckling; freshly fractured facets
// (vertex color G from the mesh builder) expose the only clean, glassy ice;
// dust collects in cavities (vertex color R); frost survives on shallow
// faces; fractures cut through the crust with dark cores and bright rims.
// Analytic-derivative fbm with pixel-footprint fading throughout.

group_uniforms Ice;
uniform vec3 ice_deep : source_color = vec3(0.04, 0.06, 0.08);
uniform vec3 ice_mid : source_color = vec3(0.36, 0.42, 0.47);
uniform vec3 ice_bright : source_color = vec3(0.62, 0.67, 0.72);
uniform float ice_roughness : hint_range(0.0, 1.0) = 0.42;
group_uniforms Dust;
uniform vec3 dust_color : source_color = vec3(0.12, 0.10, 0.08);
uniform vec3 dust_color_warm : source_color = vec3(0.30, 0.22, 0.14);
uniform float dust_amount : hint_range(0.0, 1.0) = 0.72;
group_uniforms Frost;
uniform vec3 frost_color : source_color = vec3(0.91, 0.94, 0.98);
uniform float frost_amount : hint_range(0.0, 1.0) = 0.25;
group_uniforms Fractures;
uniform float crack_amount : hint_range(0.0, 1.0) = 0.8;
uniform float crack_depth : hint_range(0.0, 2.0) = 1.0;
group_uniforms Relief;
uniform float bump_strength : hint_range(0.0, 0.05) = 0.016;
uniform float sparkle : hint_range(0.0, 1.0) = 0.35;
uniform float seed = 4.7;
group_uniforms;

varying vec3 v_pos;
varying vec3 v_nrm;
varying vec3 v_col;

void vertex() {
	v_pos = VERTEX;
	v_nrm = NORMAL;
	v_col = COLOR.rgb;
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

vec3 hash33(vec3 p3) {
	p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yxx) * p3.zyx);
}

// value noise + analytic gradient: (value, dx, dy, dz)
vec4 noised(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec3 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	float a = hash13(i);
	float b = hash13(i + vec3(1.0, 0.0, 0.0));
	float c = hash13(i + vec3(0.0, 1.0, 0.0));
	float d = hash13(i + vec3(1.0, 1.0, 0.0));
	float e = hash13(i + vec3(0.0, 0.0, 1.0));
	float g = hash13(i + vec3(1.0, 0.0, 1.0));
	float h = hash13(i + vec3(0.0, 1.0, 1.0));
	float k = hash13(i + vec3(1.0, 1.0, 1.0));
	float k0 = a;
	float k1 = b - a;
	float k2 = c - a;
	float k3 = e - a;
	float k4 = a - b - c + d;
	float k5 = a - c - e + h;
	float k6 = a - b - e + g;
	float k7 = -a + b + c - d + e - g - h + k;
	float v = k0 + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z + k6 * u.z * u.x + k7 * u.x * u.y * u.z;
	vec3 dv = du * vec3(
		k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z,
		k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x,
		k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y);
	return vec4(v, dv);
}

const mat3 ROT = mat3(
	vec3(0.00, 0.80, 0.60),
	vec3(-0.80, 0.36, -0.48),
	vec3(-0.60, -0.48, 0.64));

// fbm with analytic gradient; octaves fade below pixel footprint (fp = object units per pixel).
vec4 fbm(vec3 p, int oct, float footprint, float lac, float gain) {
	float a = 1.0;
	float f = 1.0;
	float norm = 0.0;
	vec4 s = vec4(0.0);
	vec3 q = p;
	mat3 T = mat3(1.0);
	for (int i = 0; i < 12; i++) {
		if (i >= oct) {
			break;
		}
		float fade = 1.0 - smoothstep(0.18, 0.5, f * footprint);
		vec4 n = noised(q);
		s.x += a * fade * (n.x - 0.5) * 2.0;
		s.yzw += a * fade * 2.0 * (n.yzw * T);
		norm += a;
		q = ROT * q * lac;
		T = ROT * T * lac;
		f *= lac;
		a *= gain;
	}
	return s / norm;
}

// 2-octave warped domain offsets, footprint-faded.
vec3 crack_warp(vec3 q, float pix) {
	vec3 w = vec3(0.0);
	float a = 1.0;
	float f = 1.0;
	float norm = 0.0;
	for (int i = 0; i < 2; i++) {
		float fade = 1.0 - smoothstep(0.18, 0.5, f * pix);
		w += a * fade * (vec3(
			noised(q * f + vec3(0.0, 17.1, 0.0)).x,
			noised(q * f + vec3(41.7, 0.0, 5.3)).x,
			noised(q * f + vec3(9.2, 23.4, 0.0)).x) - 0.5);
		norm += a * fade;
		f *= 2.3;
		a *= 0.5;
	}
	return w / max(norm, 1e-4);
}

vec2 voronoi(vec3 p, out vec3 v1, out vec3 v2, out vec3 cid) {
	vec3 ip = floor(p);
	vec3 fp = p - ip;
	float d1 = 8.0;
	float d2 = 8.0;
	v1 = vec3(0.0);
	v2 = vec3(0.0);
	cid = vec3(0.0);
	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				vec3 g = vec3(float(x), float(y), float(z));
				vec3 r = g + hash33(ip + g) - fp;
				float d = dot(r, r);
				if (d < d1) {
					d2 = d1;
					v2 = v1;
					d1 = d;
					v1 = r;
					cid = ip + g;
				} else if (d < d2) {
					d2 = d;
					v2 = r;
				}
			}
		}
	}
	return vec2(sqrt(d1), sqrt(d2));
}

// One fracture layer: gated voronoi network with wandering width and tapering
// depth (no even honeycomb). Adds groove height-gradient, core and halo masks.
void crack_layer(vec3 P, float scale, float warp, float width, float depth, vec3 aniso, float mask, float fade, float fp, inout vec3 grad, inout float core, inout float halo) {
	if (mask * fade < 0.002) {
		return;
	}
	float pix = fp * scale;
	vec3 q = P * scale;
	q += crack_warp(q, pix) * warp;
	q *= aniso;
	vec3 v1;
	vec3 v2;
	vec3 cid;
	vec2 f = voronoi(q, v1, v2, cid);
	float gate = smoothstep(0.15, 0.6, hash13(cid * 7.31 + scale));
	float wb = width * mix(0.35, 1.75, noised(q * 0.53 + 3.7).x);
	float wd = max(wb, pix * 1.5);
	float aa = clamp(wb / wd, 0.0, 1.0);
	fade *= aa;
	float taper = mix(0.3, 1.0, noised(q * 0.27 + 77.7).x);
	float e = f.y - f.x;
	float t = clamp(e / wd, 0.0, 1.0);
	float m = mask * fade * gate * taper;
	core = max(core, (1.0 - t * t * (3.0 - 2.0 * t)) * m);
	halo = max(halo, (1.0 - smoothstep(0.0, wd * 4.0, e)) * m);
	vec3 ge = v1 / max(f.x, 1e-4) - v2 / max(f.y, 1e-4);
	float dc = -6.0 * t * (1.0 - t) / wd * m;
	grad += -depth * dc * (ge * aniso) * scale;
}

void fragment() {
	vec3 P = v_pos + vec3(seed);
	vec3 Ng = normalize(v_nrm);
	float fp = length(fwidth(v_pos));
	float cav = v_col.r;
	float facet = v_col.g;

	// ---- macro / meso / fine variation ------------------------------------
	vec4 mA = fbm(P * 1.9, 5, fp, 2.0, 0.5);
	float macro = mA.x * 0.5 + 0.5;
	vec4 mB = fbm(P * 5.1 + 7.7, 6, fp, 2.1, 0.5);
	float meso = mB.x * 0.5 + 0.5;
	vec4 dfine = fbm(P * 24.0, 6, fp, 2.05, 0.5);

	// ---- dust crust selection (avoids steep faces, loves cavities) --------
	vec3 up = normalize(v_pos / vec3(1.0, 0.72, 1.28));
	float slope = 1.0 - clamp(dot(Ng, up), 0.0, 1.0);
	float score = macro * 0.9 + meso * 0.35 + 0.55 * cav - 1.4 * slope + (dust_amount - 0.5) * 1.6;
	float dust = smoothstep(0.5, 0.82, score);
	dust = clamp(dust * smoothstep(-0.25, 0.05, dfine.x + dust * 1.0 - 0.3), 0.0, 1.0);
	dust *= 1.0 - facet * 0.85; // fresh breaks are dust-free

	// ---- relief (before cracks: they groove it) ----------------------------
	vec4 bA = fbm(P * 7.0, 9, fp, 2.03, 0.47);
	vec3 grad = bump_strength * bA.yzw * (0.7 + 1.2 * dust);
	vec4 bS = fbm(P * 2.4 + 3.3, 3, fp, 2.0, 0.5);
	grad += 0.004 * bS.yzw * (1.0 - dust);

	// ---- fractures (hierarchical gated network; stronger through the crust) --
	float core = 0.0;
	float halo = 0.0;
	float ca = crack_amount * (0.75 + 0.5 * dust);
	float m1 = smoothstep(0.3, 0.62, noised(P * 2.1 + 1.9).x);
	float m2 = smoothstep(0.25, 0.6, noised(P * 4.3 + 9.1).x);
	float m2b = max(max(m2, m1 * 0.75), 0.25);
	crack_layer(P, 3.6, 0.9, 0.055, 0.0080 * crack_depth, vec3(1.0, 0.6, 1.0), m1 * ca, 1.0, fp, grad, core, halo);
	crack_layer(P, 11.0, 0.8, 0.075, 0.0026 * crack_depth, vec3(1.0, 0.8, 1.2), m2b * ca, 1.0 - smoothstep(0.3, 0.6, 11.0 * fp), fp, grad, core, halo);

	// ---- albedo ------------------------------------------------------------
	float patchy = smoothstep(0.25, 0.9, meso * 0.6 + macro * 0.45 - 0.05);
	vec3 ice = mix(ice_deep, ice_mid, patchy);
	// impurity speckling in the ice: medium mottling + fine grain
	float grain = fbm(P * 55.0, 2, fp, 2.2, 0.5).x;
	ice *= 0.70 + 0.45 * (dfine.x * 0.5 + 0.5) * (1.0 - dust * 0.5) + 0.15 * grain;
	// fresh fracture facets expose clean bright ice; erosion bares ridges too
	float crest = smoothstep(0.55, 0.15, cav);
	ice = mix(ice, ice_bright, max(facet * 0.85, crest * 0.35 * (1.0 - dust)));
	// fractures: bright dusty rim, dark debris-filled core
	ice = mix(ice, vec3(0.62, 0.70, 0.78), halo * 0.6 * (1.0 - facet));
	ice = mix(ice, vec3(0.03, 0.04, 0.05), core * 0.85);
	// frost survives on shallow faces and in cavities
	float frost = frost_amount * smoothstep(0.35, 0.75, meso + cav * 0.5 - slope * 0.3 + dfine.x * 0.2);
	frost *= 1.0 - facet * 0.7;
	ice = mix(ice, frost_color, frost * 0.8);
	// dust crust on top, granular
	vec3 dcol = mix(dust_color, dust_color_warm, smoothstep(0.35, 0.8, meso) * 0.8);
	dcol *= 0.5 + 0.8 * (dfine.x * 0.5 + 0.5) + 0.25 * grain;
	dcol = mix(dcol, dust_color * 0.5, core);
	vec3 albedo = mix(ice, dcol, dust);

	// tholin maculae: dark reddish-brown stained terrain (dwarf-planet look)
	float macula = smoothstep(0.42, 0.75, macro + meso * 0.3);
	albedo = mix(albedo, albedo * vec3(0.50, 0.38, 0.31), macula * 0.5 * (1.0 - facet));
	// subtle darkened equatorial band
	float band = smoothstep(0.30, 0.05, abs(dot(normalize(v_pos), normalize(vec3(0.195, 0.976, 0.117)))));
	albedo = mix(albedo, albedo * vec3(0.74, 0.64, 0.58), band * 0.35);

	// ---- surface outputs ----------------------------------------------------
	ALBEDO = albedo;
	METALLIC = 0.0;
	float rough_ice = ice_roughness + 0.18 * smoothstep(0.3, 0.9, meso + 0.3 * dfine.x) + 0.15 * smoothstep(0.3, 0.8, macro) + 0.5 * frost + 0.15 * halo;
	rough_ice = mix(rough_ice, 0.08, facet * 0.8); // fresh facets are glassier
	float roughness = clamp(mix(rough_ice, 0.88, dust), 0.04, 1.0);
	ROUGHNESS = roughness;
	SPECULAR = mix(0.5, 0.2, dust);
	CLEARCOAT = (1.0 - dust) * (1.0 - frost) * mix(0.12, 0.5, facet);
	CLEARCOAT_ROUGHNESS = 0.08;
	AO = mix(1.0, 0.48, clamp(cav * 0.75 + core * 0.4, 0.0, 1.0));
	AO_LIGHT_AFFECT = 0.75;
	// an opaque body: only a faint transmission glow through clean ice
	BACKLIGHT = (1.0 - dust) * (1.0 - frost) * vec3(0.10, 0.22, 0.38) * (0.25 + 0.5 * facet);

	// ---- sparkles: round dots on clean ice, safe at any distance ------------
	// fade the grid out once a cell drops below ~6 px, or it reads as dither
	vec3 glint_n = vec3(0.0);
	float glint_fade = 1.0 - smoothstep(0.12, 0.25, 110.0 * fp);
	if (sparkle > 0.0) {
		vec3 ra = hash33(floor(P * 110.0));
		float da = length(fract(P * 110.0) - 0.5);
		glint_n += (ra - 0.5) * 0.9 * step(0.88, ra.x) * smoothstep(0.4, 0.12, da) * glint_fade;
		glint_n *= sparkle * (1.0 - dust) * (0.4 + 0.6 * facet);
	}

	// ---- normal --------------------------------------------------------------
	vec3 tg = grad - dot(grad, Ng) * Ng;
	vec3 nobj = normalize(Ng - tg + glint_n);
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(nobj, 0.0)).xyz);

	EMISSION = glint_n * vec3(0.6, 0.8, 1.0) * 0.3;
}
