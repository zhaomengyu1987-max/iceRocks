shader_type sky;

// LOW-SPEC sky: Milky Way comes from a baked equirect texture (tex/milkyway.res),
// only three cheap star layers are evaluated per pixel (most pixels exit early).

uniform sampler2D milkyway : filter_linear, repeat_disable;
uniform float star_intensity = 0.7;
uniform float milkyway_intensity = 0.06;
uniform vec3 base_color : source_color = vec3(0.0006, 0.0008, 0.0016);
uniform vec3 band_axis = vec3(0.35, 0.8, 0.5);

vec3 h33(vec3 p3) {
	p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yxx) * p3.zyx);
}

vec3 stars(vec3 d, float scale, float density, float gain) {
	vec3 p = d * scale;
	vec3 id = floor(p);
	vec3 r = h33(id);
	if (r.x < 1.0 - density) {
		return vec3(0.0);
	}
	vec3 fr = fract(p);
	vec3 pos = 0.15 + 0.7 * h33(id + 7.7);
	float dist = length(fr - pos);
	float rad = max(length(fwidth(p)) * 0.9, 0.02);
	float b = smoothstep(rad, 0.0, dist);
	b *= b;
	vec3 col = mix(vec3(1.0, 0.72, 0.5), vec3(0.65, 0.82, 1.0), r.y);
	col = mix(col, vec3(1.0), 0.35);
	return col * b * (pow(r.z, 5.0) * 3.0 + 0.15) * gain;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec2 uv = vec2(atan(d.x, d.z) / TAU + 0.5, acos(clamp(d.y, -1.0, 1.0)) / PI);
	vec3 mw = textureLod(milkyway, uv, 0.0).rgb * 2.0;
	vec3 col = base_color + mw * milkyway_intensity;
	float band = exp(-pow(dot(d, normalize(band_axis)) / 0.20, 2.0));
	float boost = 1.0 + band * 1.5;
	col += stars(d, 42.0, 0.05, 1.6) * star_intensity;
	col += stars(d, 95.0, 0.12 * boost, 1.0) * star_intensity;
	col += stars(d, 210.0, 0.20 * boost, 0.7) * star_intensity;
	COLOR = col;
}
