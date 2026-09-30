extends SceneTree
## Offline baker for the low-spec (integrated GPU / Compatibility) path.
## Run:  Godot --path <project> -s res://tools/bake_lite_textures.gd
## Produces seamless procedural detail textures + a Milky Way map as ImageTexture .res
## (mipmaps included, no import step needed).

const N := 1024
const CELLS := 12
const OUT_DIR := "res://tex"

var _t0 := 0


func _init() -> void:
	_t0 = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_bake_detail()
	_bake_milkyway()
	print("ALL DONE in %d ms" % (Time.get_ticks_msec() - _t0))
	quit()


func _mk(type: int, freq: float, sd: int, fractal: int, oct: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = type
	n.seed = sd
	n.frequency = freq
	n.fractal_type = fractal
	n.fractal_octaves = oct
	n.fractal_gain = 0.5
	return n


func _blend(noise: FastNoiseLite, x: int, y: int) -> float:
	var fx := float(x) / N
	var fy := float(y) / N
	var a := noise.get_noise_2d(x, y)
	var b := noise.get_noise_2d(x - N, y)
	var c := noise.get_noise_2d(x, y - N)
	var d := noise.get_noise_2d(x - N, y - N)
	return a * (1.0 - fx) * (1.0 - fy) + b * fx * (1.0 - fy) + c * (1.0 - fx) * fy + d * fx * fy


func _normalize(arr: PackedFloat32Array) -> void:
	var mean := 0.0
	for v in arr:
		mean += v
	mean /= arr.size()
	var varsum := 0.0
	for v in arr:
		varsum += (v - mean) * (v - mean)
	var sd := sqrt(varsum / arr.size())
	for i in arr.size():
		arr[i] = clampf((arr[i] - mean) / (4.0 * sd) + 0.5, 0.0, 1.0)


func _bake_detail() -> void:
	var n_fbm := _mk(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.007, 11, FastNoiseLite.FRACTAL_FBM, 6)
	var n_rid := _mk(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.02, 12, FastNoiseLite.FRACTAL_RIDGED, 5)
	var n_msk := _mk(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.012, 13, FastNoiseLite.FRACTAL_FBM, 4)
	var total := N * N
	var R := PackedFloat32Array()
	R.resize(total)
	var B := PackedFloat32Array()
	B.resize(total)
	var A := PackedFloat32Array()
	A.resize(total)
	for y in N:
		for x in N:
			var i := y * N + x
			R[i] = _blend(n_fbm, x, y)
			B[i] = _blend(n_rid, x, y)
			A[i] = _blend(n_msk, x, y)
		if y % 128 == 0:
			print("noise row %d  (%d ms)" % [y, Time.get_ticks_msec() - _t0])
	_normalize(R)
	_normalize(B)
	_normalize(A)

	# periodic Voronoi F2-F1 (fracture network), domain-warped by the noise fields
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var cell := float(N) / CELLS
	var pts := PackedVector2Array()
	pts.resize(CELLS * CELLS)
	for j in CELLS:
		for i in CELLS:
			pts[j * CELLS + i] = Vector2((i + rng.randf()) * cell, (j + rng.randf()) * cell)
	var G := PackedFloat32Array()
	G.resize(total)
	for y in N:
		for x in N:
			var i := y * N + x
			var px := fposmod(x + (A[i] - 0.5) * 45.0, float(N))
			var py := fposmod(y + (R[i] - 0.5) * 45.0, float(N))
			var ci := int(px / cell)
			var cj := int(py / cell)
			var d1 := 1.0e9
			var d2 := 1.0e9
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var ii := ci + di
					var jj := cj + dj
					var wi := posmod(ii, CELLS)
					var wj := posmod(jj, CELLS)
					var p := pts[wj * CELLS + wi]
					var ex := p.x + (ii - wi) * cell - px
					var ey := p.y + (jj - wj) * cell - py
					var d := ex * ex + ey * ey
					if d < d1:
						d2 = d1
						d1 = d
					elif d < d2:
						d2 = d
			G[i] = (sqrt(d2) - sqrt(d1)) / cell
		if y % 128 == 0:
			print("voronoi row %d  (%d ms)" % [y, Time.get_ticks_msec() - _t0])

	# height field and its gradient (wrap-around central differences)
	var H := PackedFloat32Array()
	H.resize(total)
	for i in total:
		var groove := 1.0 - smoothstep(0.0, 0.12, G[i])
		H[i] = (R[i] - 0.5) * 60.0 + (B[i] - 0.5) * 20.0 - groove * 16.0
	var GX := PackedFloat32Array()
	GX.resize(total)
	var GY := PackedFloat32Array()
	GY.resize(total)
	var sum_abs := 0.0
	for y in N:
		var ym := ((y - 1 + N) % N) * N
		var yp := ((y + 1) % N) * N
		var yc := y * N
		for x in N:
			var xm := (x - 1 + N) % N
			var xp := (x + 1) % N
			var gx := (H[yc + xp] - H[yc + xm]) * 0.5
			var gy := (H[yp + x] - H[ym + x]) * 0.5
			GX[yc + x] = gx
			GY[yc + x] = gy
			sum_abs += absf(gx) + absf(gy)
	var gmax := sum_abs / (2.0 * total) * 3.5
	print("gmax = ", gmax)

	var img_a := Image.create(N, N, false, Image.FORMAT_RGBA8)
	var img_n := Image.create(N, N, false, Image.FORMAT_RGBA8)
	for y in N:
		for x in N:
			var i := y * N + x
			img_a.set_pixel(x, y, Color(R[i], clampf(G[i], 0.0, 1.0), B[i], A[i]))
			var nx := 0.5 + 0.5 * clampf(GX[i] / gmax, -1.0, 1.0)
			var ny := 0.5 + 0.5 * clampf(GY[i] / gmax, -1.0, 1.0)
			img_n.set_pixel(x, y, Color(nx, ny, clampf(0.5 + H[i] / 60.0, 0.0, 1.0), 1.0))
	_save(img_a, "ice_detail_a.res")
	_save(img_n, "ice_detail_n.res")
	img_a.save_png("res://tex/preview_detail_a.png")
	img_n.save_png("res://tex/preview_detail_n.png")


func _bake_milkyway() -> void:
	var W := 1024
	var Hh := 512
	var cloud := _mk(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 1.0, 21, FastNoiseLite.FRACTAL_FBM, 5)
	var lanes := _mk(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 1.0, 22, FastNoiseLite.FRACTAL_FBM, 5)
	var axis := Vector3(0.35, 0.8, 0.5).normalized()
	var img := Image.create(W, Hh, false, Image.FORMAT_RGB8)
	for y in Hh:
		var th := (y + 0.5) / Hh * PI
		for x in W:
			var a := ((x + 0.5) / W - 0.5) * TAU
			var d := Vector3(sin(th) * sin(a), cos(th), sin(th) * cos(a))
			var bnd := d.dot(axis)
			var band := exp(-pow(bnd / 0.20, 2.0))
			var core := exp(-pow(bnd / 0.07, 2.0))
			var c := cloud.get_noise_3dv(d * 4.0) * 0.5 + 0.5
			var l := smoothstep(0.35, 0.65, lanes.get_noise_3dv(d * 9.0 + Vector3(3, 3, 3)) * 0.5 + 0.5)
			var mw := (band * 0.5 + core * 0.6) * (0.35 + 1.1 * c) * (1.0 - 0.7 * l * band)
			var col := Color(0.55, 0.62, 0.9).lerp(Color(1.0, 0.82, 0.6), smoothstep(0.3, 0.8, c))
			var v := mw * 0.5 # stored /2, shader multiplies back
			img.set_pixel(x, y, Color(col.r * v, col.g * v, col.b * v))
	_save(img, "milkyway.res")


func _save(img: Image, file: String) -> void:
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var err := ResourceSaver.save(tex, "%s/%s" % [OUT_DIR, file])
	print("saved %s err=%d (%d ms)" % [file, err, Time.get_ticks_msec() - _t0])
