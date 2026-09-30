shader_type sky;

// Deep-space backdrop: multi-layer stars + faint Milky Way band with dust lanes.

uniform vec3 band_axis = vec3(0.35, 0.8, 0.5);
uniform float star_intensity = 1.5;
uniform float milkyway_intensity = 0.06;
uniform vec3 base_color : source_color = vec3(0.0006, 0.0008, 0.0016);

float h13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

vec3 h33(vec3 p3) {
	p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yxx) * p3.zyx);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(h13(i), h13(i + vec3(1, 0, 0)), f.x), mix(h13(i + vec3(0, 1, 0)), h13(i + vec3(1, 1, 0)), f.x), f.y);
	float b = mix(mix(h13(i + vec3(0, 0, 1)), h13(i + vec3(1, 0, 1)), f.x), mix(h13(i + vec3(0, 1, 1)), h13(i + vec3(1, 1, 1)), f.x), f.y);
	return mix(a, b, f.z);
}

float fbm3(vec3 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 6; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + 11.7;
		a *= 0.5;
	}
	return s;
}

vec3 stars(vec3 d, float scale, float density, float gain) {
	vec3 p = d * scale;
	vec3 id = floor(p);
	vec3 fr = fract(p);
	vec3 r = h33(id);
	if (r.x < 1.0 - density) {
		return vec3(0.0);
	}
	vec3 pos = 0.15 + 0.7 * h33(id + 7.7);
	float dist = length(fr - pos);
	float px = length(fwidth(p));
	float rad = max(px * 0.9, 0.02);
	float b = smoothstep(rad, 0.0, dist);
	b *= b;
	vec3 col = mix(vec3(1.0, 0.72, 0.5), vec3(0.65, 0.82, 1.0), r.y);
	col = mix(col, vec3(1.0), 0.35);
	float mag = pow(r.z, 5.0) * 3.0 + 0.15;
	return col * b * mag * gain;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 col = base_color;

	// Milky Way
	float bnd = dot(d, normalize(band_axis));
	float band = exp(-pow(bnd / 0.20, 2.0));
	float core = exp(-pow(bnd / 0.07, 2.0));
	float cloud = fbm3(d * 4.0);
	float lanes = smoothstep(0.35, 0.65, fbm3(d * 9.0 + 3.0));
	float mw = (band * 0.5 + core * 0.6) * (0.35 + 1.1 * cloud) * (1.0 - 0.7 * lanes * band);
	vec3 mwcol = mix(vec3(0.55, 0.62, 0.9), vec3(1.0, 0.82, 0.6), smoothstep(0.3, 0.8, cloud));
	col += mwcol * mw * milkyway_intensity;

	// stars (denser inside the band)
	float dens_boost = 1.0 + band * 1.5;
	col += stars(d, 42.0, 0.05, 1.6) * star_intensity;
	col += stars(d, 95.0, 0.12 * dens_boost, 1.0) * star_intensity;
	col += stars(d, 210.0, 0.20 * dens_boost, 0.7) * star_intensity;
	col += stars(d, 420.0, 0.30 * dens_boost, 0.5) * star_intensity * (0.4 + band);

	COLOR = col;
}
