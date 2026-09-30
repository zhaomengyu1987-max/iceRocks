shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Fully procedural comet-ice surface (object-space, no UV / textures).
// Layers: milky/clear ice, sublimation frost, dark dust crust, multi-scale fractures,
// strata, fbm bump (analytic derivatives), micro glints, translucency.

group_uniforms Ice;
uniform vec3 ice_clear : source_color = vec3(0.42, 0.68, 0.95);
uniform vec3 ice_milky : source_color = vec3(0.90, 0.95, 1.0);
uniform vec3 ice_deep : source_color = vec3(0.02, 0.10, 0.28);
uniform float ice_roughness : hint_range(0.0, 1.0) = 0.16;
uniform float frost_amount : hint_range(0.0, 1.0) = 0.45;
group_uniforms Dust;
uniform vec3 dust_color : source_color = vec3(0.05, 0.042, 0.036);
uniform vec3 dust_color_warm : source_color = vec3(0.13, 0.085, 0.05);
uniform float dust_amount : hint_range(0.0, 1.0) = 0.5;
group_uniforms Relief;
uniform float bump_strength = 0.010;
uniform float crack_depth = 1.0;
uniform float crack_amount : hint_range(0.0, 1.0) = 0.8;
uniform float sparkle : hint_range(0.0, 1.0) = 0.6;
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
	float a = hash13(i + vec3(0.0, 0.0, 0.0));
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

// fbm with gradient. Result value in about [-1,1]; gradient w.r.t. p.
// Octaves fade out once they drop below pixel size (footprint = p-units per pixel).
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

vec2 voronoi(vec3 p, out vec3 v1, out vec3 v2) {
	vec3 ip = floor(p);
	vec3 fp = p - ip;
	float d1 = 8.0;
	float d2 = 8.0;
	v1 = vec3(0.0);
	v2 = vec3(0.0);
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
				} else if (d < d2) {
					d2 = d;
					v2 = r;
				}
			}
		}
	}
	return vec2(sqrt(d1), sqrt(d2));
}

// One fracture network layer. Adds groove height-gradient, core and halo masks.
void crack_layer(vec3 P, float scale, float warp, float width, float depth, float mask, float fade, float fp, inout vec3 grad, inout float core, inout float halo) {
	if (mask * fade < 0.002) {
		return;
	}
	// Band-limit the lines: never let them get narrower than ~1.5 pixels. A line that
	// would be thinner fades out instead, which removes shimmer / crawling when moving.
	float pix = fp * scale;
	float wd = max(width, pix * 1.5);
	float aa = clamp(width / wd, 0.0, 1.0);
	fade *= aa;
	vec3 q = P * scale;
	vec3 w = vec3(noised(q * 0.35).x, noised(q * 0.35 + 17.1).x, noised(q * 0.35 + 41.7).x) - 0.5;
	q += w * warp;
	vec3 v1;
	vec3 v2;
	vec2 f = voronoi(q, v1, v2);
	float e = f.y - f.x;
	float t = clamp(e / wd, 0.0, 1.0);
	float c = (1.0 - t * t * (3.0 - 2.0 * t)) * mask * fade;
	core = max(core, c);
	halo = max(halo, (1.0 - smoothstep(0.0, wd * 4.0, e)) * mask * fade);
	vec3 ge = v1 / max(f.x, 1e-4) - v2 / max(f.y, 1e-4);
	float dc = -6.0 * t * (1.0 - t) / wd * mask * fade;
	grad += -depth * dc * ge * scale;
}

void fragment() {
	vec3 P = v_pos + vec3(seed);
	vec3 Ng = normalize(v_nrm);
	float fp = length(fwidth(v_pos));
	vec3 up = normalize(v_pos / vec3(1.45, 0.88, 1.0));
	float slope = 1.0 - clamp(dot(Ng, up), 0.0, 1.0);
	float cav = v_col.r;
	float crack_geo = v_col.g;

	// ---- macro variation -------------------------------------------------
	vec4 mA = fbm(P * 1.9, 5, fp, 2.0, 0.5);
	float macro = mA.x * 0.5 + 0.5;
	vec4 mB = fbm(P * 5.3 + 7.7, 6, fp, 2.1, 0.5);
	float meso = mB.x * 0.5 + 0.5;

	// ---- dust crust selection --------------------------------------------
	float score = macro * 0.9 + meso * 0.35 + 0.55 * cav - 1.7 * slope + (dust_amount - 0.5) * 1.5;
	float dust = smoothstep(0.55, 0.85, score);
	vec4 dfine = fbm(P * 38.0, 7, fp, 2.05, 0.5);
	dust = clamp(dust * smoothstep(-0.55, 0.15, dfine.x + dust * 1.1 - 0.35), 0.0, 1.0);

	// ---- relief: fbm bump ------------------------------------------------
	vec4 bA = fbm(P * 9.0, 11, fp, 2.03, 0.47);
	vec3 grad = bump_strength * bA.yzw * mix(0.75, 1.9, dust);

	// large scallops / sublimation pits on ice
	vec4 bS = fbm(P * 2.6 + 3.3, 3, fp, 2.0, 0.5);
	grad += 0.006 * bS.yzw * (1.0 - dust);

	// ---- fractures -------------------------------------------------------
	float core = 0.0;
	float halo = 0.0;
	float m1 = smoothstep(0.30, 0.62, noised(P * 2.3 + 1.9).x);
	float m2 = smoothstep(0.25, 0.60, noised(P * 4.1 + 9.1).x);
	float m3 = smoothstep(0.20, 0.55, noised(P * 7.0 + 4.4).x);
	float ca = crack_amount;
	crack_layer(P, 5.0, 0.9, 0.055, 0.0040 * crack_depth, m1 * ca, 1.0, fp, grad, core, halo);
	crack_layer(P, 19.0, 0.8, 0.075, 0.0016 * crack_depth, max(m2, 0.25) * ca, 1.0 - smoothstep(0.30, 0.6, 19.0 * fp), fp, grad, core, halo);
	crack_layer(P, 74.0, 0.7, 0.10, 0.00055 * crack_depth, max(m3, 0.3) * ca, 1.0 - smoothstep(0.30, 0.6, 74.0 * fp), fp, grad, core, halo);
	core = max(core, crack_geo * 0.6);

	// ---- strata on steep faces ------------------------------------------
	float strata_c = dot(P, normalize(vec3(0.3, 1.0, 0.2))) * 38.0 + mA.x * 6.0 + mB.x * 1.5;
	float strata = sin(strata_c) * 0.5 + 0.5;
	strata = smoothstep(0.35, 0.65, strata) * smoothstep(0.15, 0.55, slope);

	// ---- micro glints ----------------------------------------------------
	vec3 glint_n = vec3(0.0);
	float glint_fade_a = 1.0 - smoothstep(0.30, 0.65, 130.0 * fp);
	float glint_fade_b = 1.0 - smoothstep(0.30, 0.65, 520.0 * fp);
	if (sparkle > 0.0) {
		vec3 ra = hash33(floor(P * 130.0));
		vec3 rb = hash33(floor(P * 520.0) + 3.1);
		glint_n += (ra - 0.5) * 1.2 * step(0.86, ra.x) * glint_fade_a;
		glint_n += (rb - 0.5) * 1.2 * step(0.80, rb.x) * glint_fade_b;
		glint_n *= sparkle * (1.0 - dust);
	}

	// ---- albedo ----------------------------------------------------------
	float milky = smoothstep(0.30, 0.75, macro * 0.7 + meso * 0.4 - 0.1);
	vec3 ice = mix(ice_clear, ice_milky, milky);
	ice = mix(ice, ice_clear * 0.55, strata * 0.55);
	// frost: bright rough coating in cavities and on flat ground
	float frost = frost_amount * smoothstep(0.35, 0.8, meso + cav * 0.5 - slope * 0.6 + dfine.x * 0.25);
	ice = mix(ice, vec3(0.94, 0.97, 1.0), frost * 0.8);
	// fractures: white scattering halo with deep-blue core
	ice = mix(ice, vec3(0.93, 0.97, 1.0), halo * 0.45 * (1.0 - frost));
	ice = mix(ice, ice_deep, core * 0.9);

	vec3 dcol = mix(dust_color, dust_color_warm, smoothstep(0.35, 0.8, meso) * 0.8);
	dcol *= 0.55 + 0.9 * (dfine.x * 0.5 + 0.5);
	dcol = mix(dcol, dust_color * 0.5, core);

	vec3 albedo = mix(ice, dcol, dust);

	float rough_ice = ice_roughness + 0.28 * smoothstep(0.2, 0.9, meso + 0.3 * dfine.x) + 0.55 * frost + 0.25 * halo;
	float roughness = clamp(mix(rough_ice, 0.93, dust), 0.05, 1.0);

	// ---- normal ----------------------------------------------------------
	vec3 tg = grad - dot(grad, Ng) * Ng;
	vec3 nobj = normalize(Ng - tg + glint_n);
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(nobj, 0.0)).xyz);

	ALBEDO = albedo;
	METALLIC = 0.0;
	ROUGHNESS = roughness;
	SPECULAR = mix(0.55, 0.2, dust);
	CLEARCOAT = (1.0 - dust) * (1.0 - frost) * 0.35;
	CLEARCOAT_ROUGHNESS = 0.08;
	AO = mix(1.0, 0.45, clamp(cav * 0.8 + core * 0.5, 0.0, 1.0));
	AO_LIGHT_AFFECT = 0.7;
	BACKLIGHT = (1.0 - dust) * vec3(0.10, 0.28, 0.55) * 0.5;
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
	SSS_TRANSMITTANCE_COLOR = vec4(0.20, 0.55, 1.0, 1.0);
	SSS_TRANSMITTANCE_DEPTH = 4.0 * (1.0 - dust);
	SSS_TRANSMITTANCE_BOOST = 0.2;
#endif
}
