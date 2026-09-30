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
group_uniforms Sharpness;
uniform float edge_sharpness : hint_range(0.0, 1.0) = 0.85; // crispness of the dust / ice boundary
uniform float edge_jitter : hint_range(0.0, 0.3) = 0.10; // how ragged that boundary is
uniform float ledge : hint_range(0.0, 0.05) = 0.012; // height of the dust crust step at the boundary
uniform float crust_amount : hint_range(0.0, 1.0) = 1.0; // broken ice-crust patches on the ice
uniform float crust_threshold : hint_range(0.3, 0.8) = 0.63; // higher = fewer patches
uniform float micro_ridge : hint_range(0.0, 1.0) = 1.0; // sharp creases at the smallest scales
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

// 2-octave warped domain offsets (one per axis), footprint-faded like fbm.
// The second octave is what breaks the smooth uniform bending of the old
// single-octave warp into irregular wander.
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

// One fracture network layer. Adds groove height-gradient, core and halo masks.
// The voronoi domain is warped by multi-octave fbm, stretched along a stress
// direction (aniso), cell borders open/close at random, and width/depth are
// modulated by low-frequency noise so cracks taper and die out instead of
// forming an even honeycomb.
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
	// per-cell gate: some borders never open, so the network is patchy
	float gate = smoothstep(0.15, 0.6, hash13(cid * 7.31 + scale));
	// width wanders along the crack: pinches shut, then widens again
	float wb = width * mix(0.35, 1.75, noised(q * 0.53 + 3.7).x);
	// Band-limit the lines: never let them get narrower than ~1.5 pixels. A line that
	// would be thinner fades out instead, which removes shimmer / crawling when moving.
	float wd = max(wb, pix * 1.5);
	float aa = clamp(wb / wd, 0.0, 1.0);
	fade *= aa;
	// depth fades along the crack so lines start and stop instead of running forever
	float taper = mix(0.3, 1.0, noised(q * 0.27 + 77.7).x);
	float e = f.y - f.x;
	float t = clamp(e / wd, 0.0, 1.0);
	float m = mask * fade * gate * taper;
	float c = (1.0 - t * t * (3.0 - 2.0 * t)) * m;
	core = max(core, c);
	halo = max(halo, (1.0 - smoothstep(0.0, wd * 4.0, e)) * m);
	vec3 ge = v1 / max(f.x, 1e-4) - v2 / max(f.y, 1e-4);
	float dc = -6.0 * t * (1.0 - t) / wd * m;
	grad += -depth * dc * (ge * aniso) * scale;
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
	vec4 dfine = fbm(P * 38.0, 7, fp, 2.05, 0.5);
	// Ragged, hard-edged boundary: fine noise pushes the threshold around, and the transition is
	// only as wide as ~1 pixel (or the chosen softness) instead of a broad smoothstep.
	score += edge_jitter * dfine.x;
	vec3 gscore = 0.855 * mA.yzw + 0.9275 * mB.yzw + (edge_jitter * 38.0) * dfine.yzw; // d score / d P
	const float DUST_MID = 0.70;
	float wdt = max(mix(0.15, 0.02, edge_sharpness), length(gscore) * fp * 1.2);
	float dt = clamp((score - (DUST_MID - wdt)) / (2.0 * wdt), 0.0, 1.0);
	float dust = dt * dt * (3.0 - 2.0 * dt);
	float ddust = 6.0 * dt * (1.0 - dt) / (2.0 * wdt); // d dust / d score
	dust = clamp(dust * smoothstep(-0.55, 0.15, dfine.x + dust * 1.1 - 0.35), 0.0, 1.0);

	// ---- relief: fbm bump ------------------------------------------------
	vec4 bA = fbm(P * 9.0, 11, fp, 2.03, 0.47);
	vec3 grad = bump_strength * bA.yzw * mix(0.75, 1.9, dust);

	// the dust crust stands proud of the ice: a real step at the boundary catches the light
	vec3 gl = ledge * ddust * gscore;
	gl *= min(1.0, 3.0 / max(length(gl), 1.0e-4));
	grad += gl;

	// sharp creases at the smallest scales (ridged value noise: |2v-1| has a kink, not a bump)
	// Several octaves: a single coarse one carves the ground into big tilted plates with a
	// hard seam between them, which reads as translucent flakes when the camera is close.
	if (micro_ridge > 0.0) {
		vec3 mg = vec3(0.0);
		float sc = 90.0;
		float amp = 0.10;
		for (int i = 0; i < 4; i++) {
			float mf = 1.0 - smoothstep(0.30, 0.65, sc * fp);
			if (mf > 0.01) {
				vec4 rn = noised(P * sc + float(i) * 7.3 + 5.1);
				mg += amp * mf * (-2.0 * sign(2.0 * rn.x - 1.0)) * rn.yzw;
			}
			sc *= 3.0;
			amp *= 1.15;
		}
		grad += micro_ridge * mix(0.35, 1.0, dust) * mg;
	}

	// ---- broken ice crust: hard-edged patches of granular, crumbly relief ----
	float crust = 0.0;
	float mh = 0.5;
	if (crust_amount > 0.0) {
		vec4 c1 = noised(P * 6.5 + 21.7);
		vec4 c2 = noised(P * 23.0 + 4.1);
		float cs = c1.x * 0.7 + c2.x * 0.3 + 0.15 * dfine.x;
		vec3 gc = 0.7 * 6.5 * c1.yzw + 0.3 * 23.0 * c2.yzw + 0.15 * 38.0 * dfine.yzw;
		float cw = max(0.09, length(gc) * fp * 1.2); // wide, soft hand-over to the blue ice
		float ct = clamp((cs - (crust_threshold - cw)) / (2.0 * cw), 0.0, 1.0);
		crust = ct * ct * (3.0 - 2.0 * ct) * (1.0 - dust) * (1.0 - 0.7 * smoothstep(0.4, 0.8, slope)) * crust_amount;
		if (crust > 0.003) {
			// rotated-octave fbm (no lattice-aligned plates); |f| gives sharp crumbly creases
			vec4 cf = fbm(P * 70.0 + 13.3, 5, fp, 2.2, 0.55);
			float sg = clamp(cf.x * 3.0, -1.0, 1.0);
			vec3 cg = -0.16 * sg * cf.yzw;
			vec4 cf2 = fbm(P * 26.0 + 3.9, 4, fp, 2.1, 0.5);
			cg += -0.10 * clamp(cf2.x * 3.0, -1.0, 1.0) * cf2.yzw;
			mh = clamp(0.5 + 0.9 * abs(cf.x) - 0.25 * cf2.x, 0.0, 1.0);			grad += crust * cg;
		}
	}
	// large scallops / sublimation pits on ice
	vec4 bS = fbm(P * 2.6 + 3.3, 3, fp, 2.0, 0.5);
	grad += 0.006 * bS.yzw * (1.0 - dust);

	// ---- fractures -------------------------------------------------------
	float core = 0.0;
	float halo = 0.0;
	float m1 = smoothstep(0.30, 0.62, noised(P * 2.3 + 1.9).x);
	float m2 = smoothstep(0.25, 0.60, noised(P * 4.1 + 9.1).x);
	float m3 = smoothstep(0.20, 0.55, noised(P * 7.0 + 4.4).x);
	// hierarchy: fine cracks cluster around and branch off the larger networks
	m2 = max(max(m2, m1 * 0.75), 0.25);
	m3 = max(max(m3, m2 * 0.6), 0.3);
	float ca = crack_amount * 0.55;
	crack_layer(P, 5.0, 0.9, 0.055, 0.0075 * crack_depth, vec3(1.0, 0.58, 1.0), m1 * ca, 1.0, fp, grad, core, halo);
	crack_layer(P, 19.0, 0.8, 0.075, 0.0030 * crack_depth, vec3(1.0, 0.8, 1.2), m2 * ca, 1.0 - smoothstep(0.30, 0.6, 19.0 * fp), fp, grad, core, halo);
	crack_layer(P, 74.0, 0.7, 0.10, 0.00055 * crack_depth, vec3(1.15, 1.0, 0.9), m3 * ca, 1.0 - smoothstep(0.30, 0.6, 74.0 * fp), fp, grad, core, halo);
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
		// Dot falloff from the cell centre: keeps the glitter as round specks.
		// Without it each selected cell shades as one flat square facet up close.
		float da = length(fract(P * 130.0) - 0.5);
		float db = length(fract(P * 520.0) - 0.5);
		glint_n += (ra - 0.5) * 1.2 * step(0.86, ra.x) * smoothstep(0.45, 0.15, da) * glint_fade_a;
		glint_n += (rb - 0.5) * 1.2 * step(0.80, rb.x) * smoothstep(0.45, 0.15, db) * glint_fade_b;
		glint_n *= sparkle * (1.0 - dust);
	}

	// ---- albedo ----------------------------------------------------------
	float milky = smoothstep(0.30, 0.75, macro * 0.7 + meso * 0.4 - 0.1);
	vec3 ice = mix(ice_clear, ice_milky, milky);
	ice = mix(ice, ice_clear * 0.55, strata * 0.55);
	// frost: bright rough coating in cavities and on flat ground
	float frost = frost_amount * smoothstep(0.35, 0.8, meso + cav * 0.5 - slope * 0.6 + dfine.x * 0.25);
	ice = mix(ice, ice_milky * vec3(1.0, 1.0, 1.02), frost * 0.6);
	// fractures: white scattering halo with deep-blue core
	ice = mix(ice, ice_milky, halo * 0.10 * (1.0 - frost));
	ice *= 1.0 - 0.45 * core; // dark thin fissure, not a blue painted line
	ice = mix(ice, ice * mix(0.6, 1.12, mh), crust * 0.9); // same hue as the ice, only lighter/darker

	vec3 dcol = mix(dust_color, dust_color_warm, smoothstep(0.35, 0.8, meso) * 0.8);
	dcol *= 0.45 + 1.1 * (dfine.x * 0.5 + 0.5);
	dcol = mix(vec3(dot(dcol, vec3(0.333))), dcol, 0.45); // desaturate
	dcol = mix(dcol, dust_color * 0.5, core);

	// boundary dressing: bright frost lip on the ice side, thin dark contact line on the dust side
	float below = (DUST_MID - wdt) - score; // > 0 on the ice side
	float lip = (1.0 - smoothstep(0.0, 0.07, max(below, 0.0))) * step(0.0, below);
	float edge_halo = 1.0 - smoothstep(0.0, 0.16, abs(score - DUST_MID));
	ice = mix(ice, ice_milky, lip * lip * 0.5 * (1.0 - dust));
	ice *= 1.0 - 0.3 * edge_halo * (1.0 - lip) * (1.0 - dust);
	dcol *= mix(0.5, 1.0, smoothstep(0.0, 0.05, score - (DUST_MID + wdt)));

	vec3 albedo = mix(ice, dcol, dust);

	float rough_ice = ice_roughness + 0.28 * smoothstep(0.2, 0.9, meso + 0.3 * dfine.x) + 0.55 * frost + 0.25 * halo;
	float roughness = clamp(mix(rough_ice, 0.93, dust), 0.05, 1.0);
	roughness = mix(roughness, 0.78, crust);

	// ---- normal ----------------------------------------------------------
	vec3 tg = grad - dot(grad, Ng) * Ng;
	vec3 nobj = normalize(Ng - tg + glint_n);
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(nobj, 0.0)).xyz);

	ALBEDO = albedo;
	METALLIC = 0.0;
	ROUGHNESS = roughness;
	SPECULAR = mix(0.55, 0.2, dust);
	CLEARCOAT = (1.0 - dust) * (1.0 - frost) * 0.35 * (1.0 - crust);
	CLEARCOAT_ROUGHNESS = 0.08;
	AO = mix(1.0, 0.45, clamp(cav * 0.8 + core * 0.5, 0.0, 1.0)) * mix(1.0, mix(0.55, 1.0, mh), crust);
	AO_LIGHT_AFFECT = 0.85;
	BACKLIGHT = (1.0 - dust) * vec3(0.10, 0.28, 0.55) * 0.5;
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
	SSS_TRANSMITTANCE_COLOR = vec4(0.20, 0.55, 1.0, 1.0);
	SSS_TRANSMITTANCE_DEPTH = 4.0 * (1.0 - dust);
	SSS_TRANSMITTANCE_BOOST = 0.2;
#endif
}