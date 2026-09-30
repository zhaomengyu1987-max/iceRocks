@tool
class_name IceNucleus
extends MeshInstance3D
## Procedural comet-nucleus ice body.
## Cube-sphere -> bilobed silhouette -> ridged noise -> craters -> fractures.
## Set `rebuild` to true in the inspector to re-sculpt and bake the mesh.
##
## Bake recipes (the scene stores the HIGH one; the mesh is only as detailed as its grid, so a
## coarser grid needs the sub-grid features removed instead of aliased):
##   HIGH  meshes/ice_nucleus_mesh.res       resolution 128, crater_bands 3, crack_layers 1,
##         crack_min_edges 5, rim_min_edges 2.5, ridge_octaves 3, fine_amount 0.002, normal_smooth_iters 2
##   LOW   meshes/ice_nucleus_mesh_lite.res  same but resolution 96, crater_bands 2, fine_amount 0,
##         normal_smooth_iters 3. Also used by orbit_camera as the zoom-limit collision proxy.

const MESH_PATH := "res://meshes/ice_nucleus_mesh.res"
const S := 100.0 # noise coordinate scale (FastNoiseLite likes large coords)

@export_range(32, 400, 1) var resolution: int = 224
@export var noise_seed: int = 7
@export var elongation := Vector3(1.45, 0.88, 1.0)
@export var status: String = ""
@export var block_amount: float = 0.0
@export var mesh_path: String = MESH_PATH
@export var rebuild: bool = false:
	set(v):
		rebuild = false
		if v and is_inside_tree():
			build()

@export_group("Band limit")
## How many crater size classes are sculpted into the mesh (largest first). Classes that are
## smaller than a few grid cells only alias into noise, so a coarser mesh should use fewer.
@export_range(0, 4, 1) var crater_bands: int = 4
## Fracture layers sculpted into the mesh (0..2). Finer ones alias at low resolution.
@export_range(0, 2, 1) var crack_layers: int = 2
## Amplitude of the finest roughness noise added to the radius.
@export var fine_amount: float = 0.0045
## Minimum fracture-groove width, in mesh grid cells (0 = keep the original fixed width).
@export_range(0.0, 10.0, 0.1) var crack_min_edges: float = 0.0
## Minimum crater-rim width, in mesh grid cells (0 = keep the original fixed profile).
@export_range(0.0, 6.0, 0.1) var rim_min_edges: float = 0.0
## Octaves of the ridged plate noise. The top octaves have wavelengths of only a few grid
## cells on a coarse mesh and turn into saw-tooth spikes; drop them when lowering resolution.
@export_range(1, 5, 1) var ridge_octaves: int = 5
## Amplitude of the ridged plate noise.
@export var ridge_amount: float = 0.045
## Passes of 1-ring smoothing applied to the baked vertex normals (0 = off).
@export_range(0, 12, 1) var normal_smooth_iters: int = 0
## Passes of 1-ring smoothing applied to the baked vertex colours (0 = off).
@export_range(0, 12, 1) var color_smooth_iters: int = 0

@export_group("Big-form hardness")
## Number of planar cleave cuts that slice the silhouette (0 = off). Each one flattens a
## region into a planar scarp and leaves a crisp ridge where it meets its neighbours.
@export_range(0, 40, 1) var facet_planes: int = 0
## Cut depth range: planes sit at this radius fraction (min..max) of the body.
@export var facet_offset_min: float = 0.74
@export var facet_offset_max: float = 0.93
## Edge rounding of the cuts, in radius units (smaller = harder edge).
@export var facet_round: float = 0.012
## Amplitude of the low-frequency lumps that make the body blobby.
@export var lump_amount: float = 0.16
## Terrace the ridged plate noise into steps with hard risers (0 = smooth).
@export_range(0.0, 1.0, 0.05) var terrace_amount: float = 0.0
@export var facet_seed: int = 3

@export_group("Tumble")
@export var spin_axis := Vector3(0.25, 1.0, 0.1)
@export var spin_speed_deg := 1.5

var _building := false
var n_low: FastNoiseLite
var n_ridge: FastNoiseLite
var n_fine: FastNoiseLite
var n_block: FastNoiseLite
var _planes: Array = [] # [normal, offset]
var n_crack: Array[FastNoiseLite] = []
var n_cv: Array[FastNoiseLite] = []
var n_cd: Array[FastNoiseLite] = []

# [freq, threshold, size, depth ratio]
const CRATERS := [
	[1.15, 0.74, 0.52, 0.34],
	[2.6, 0.56, 0.50, 0.32],
	[6.0, 0.46, 0.48, 0.30],
	[14.0, 0.38, 0.46, 0.26],
]
# [freq, width, depth]
const CRACKS := [
	[1.7, 0.07, 0.030],
	[5.5, 0.10, 0.0085],
]

const FACES := [
	[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)],
	[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
	[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)],
	[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
	[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
	[Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
]


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	rotate(spin_axis.normalized(), deg_to_rad(spin_speed_deg) * delta)


func _mk(type: int, freq: float, sd: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = type
	n.seed = sd
	n.frequency = freq / S
	n.fractal_type = FastNoiseLite.FRACTAL_NONE
	return n


func _setup_noise() -> void:
	var s := noise_seed
	n_low = _mk(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.55, s)
	n_low.fractal_type = FastNoiseLite.FRACTAL_FBM
	n_low.fractal_octaves = 4
	n_ridge = _mk(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 2.2, s + 1)
	n_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	n_ridge.fractal_octaves = ridge_octaves
	n_fine = _mk(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 16.0, s + 2)
	n_fine.fractal_type = FastNoiseLite.FRACTAL_FBM
	n_fine.fractal_octaves = 4
	n_block = _mk(FastNoiseLite.TYPE_CELLULAR, 3.2, s + 3)
	n_block.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	n_block.domain_warp_enabled = true
	n_block.domain_warp_amplitude = 14.0
	n_block.domain_warp_frequency = 0.03
	_planes.clear()
	var prng := RandomNumberGenerator.new()
	prng.seed = facet_seed
	for i in facet_planes:
		var pn := Vector3(prng.randfn(), prng.randfn(), prng.randfn()).normalized()
		_planes.append([pn, prng.randf_range(facet_offset_min, facet_offset_max)])
	n_crack.clear()
	n_cv.clear()
	n_cd.clear()
	for i in CRACKS.size():
		var c := _mk(FastNoiseLite.TYPE_CELLULAR, CRACKS[i][0], s + 10 + i)
		c.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
		c.domain_warp_enabled = true
		c.domain_warp_amplitude = 10.0 / (1.0 + i * 1.5)
		c.domain_warp_frequency = 0.05 * (1.0 + i)
		n_crack.append(c)
	for i in CRATERS.size():
		var v := _mk(FastNoiseLite.TYPE_CELLULAR, CRATERS[i][0], s + 30 + i)
		v.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
		var d := _mk(FastNoiseLite.TYPE_CELLULAR, CRATERS[i][0], s + 30 + i)
		d.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
		n_cv.append(v)
		n_cd.append(d)


## Returns (radius multiplier, cavity, crack mask, height01)
func _sample(d: Vector3) -> Vector4:
	var c := d * S
	var r := 1.0
	# silhouette: bilobed with a neck, lopsided lobes, low-frequency lumps
	r += lump_amount * n_low.get_noise_3dv(c)
	r *= 1.0 - 0.24 * exp(-pow(d.x / 0.28, 2.0))
	r *= 1.0 + 0.12 * d.x
	# large ridged plates
	var rv := n_ridge.get_noise_3dv(c)
	if terrace_amount > 0.0:
		var ts := rv * 6.0
		var tf := floorf(ts)
		var tv := (tf + smoothstep(0.85, 1.0, ts - tf)) / 6.0
		rv = lerpf(rv, tv, terrace_amount)
	r += ridge_amount * rv
	# planar cleave cuts: hard-min against each plane -> flat scarps with crisp ridges
	for pl in _planes:
		var dn: float = d.dot(pl[0])
		if dn > 0.05:
			var lim: float = float(pl[1]) / dn
			var hh := clampf(0.5 - 0.5 * (lim - r) / maxf(facet_round, 1.0e-4), 0.0, 1.0)
			r = lerpf(r, lim, hh) - facet_round * hh * (1.0 - hh)
	# fractured blocks / terraces. Off by default: this noise is piecewise-constant, so it
	# creates hard steps that follow the mesh grid; those cast stair-stepped, crawling shadows.
	if block_amount != 0.0:
		r += block_amount * n_block.get_noise_3dv(c)

	var depth_acc := 0.0
	# craters
	for i in mini(crater_bands, CRATERS.size()):
		var cr: Array = CRATERS[i]
		var cv := (n_cv[i].get_noise_3dv(c) + 1.0) * 0.5
		if cv <= cr[1]:
			continue
		var k: float = (cv - cr[1]) / (1.0 - cr[1])
		var rad: float = cr[2] * (0.35 + 0.65 * k)
		var dist := n_cd[i].get_noise_3dv(c) + 1.0
		var x := dist / rad
		var depth: float = cr[3] * rad / cr[0]
		var h := 0.0
		if x < 1.0:
			var bowl := 1.0 - x * x
			bowl = smoothstep(0.0, 0.55, bowl) # flat-ish floor
			h -= depth * bowl
			depth_acc += depth * bowl
		# rim width, widened so it never drops below `rim_min_edges` grid cells (else it aliases
		# into saw-teeth along the mesh grid)
		var rim_w := 0.22
		if rim_min_edges > 0.0:
			var freq: float = cr[0]
			rim_w = maxf(rim_w, rim_min_edges * 2.0 * freq / (float(resolution) * rad))
		h += depth * 0.35 * exp(-pow((x - 1.0) / rim_w, 2.0))
		if x > 1.0:
			h += depth * 0.08 * exp(-(x - 1.0) * 2.5 * 0.22 / rim_w)
		r += h

	# fractures
	var crack_mask := 0.0
	for i in mini(crack_layers, CRACKS.size()):
		var e := n_crack[i].get_noise_3dv(c) + 1.0
		# groove width, widened so it never drops below `crack_min_edges` grid cells: a narrow
		# V-shaped groove on a coarse grid aliases into saw-tooth spikes
		var cw: float = CRACKS[i][1]
		if crack_min_edges > 0.0:
			cw = maxf(cw, crack_min_edges * 2.0 * float(CRACKS[i][0]) / float(resolution))
		var g := 1.0 - smoothstep(0.0, cw, e)
		r -= CRACKS[i][2] * pow(g, 1.3)
		depth_acc += CRACKS[i][2] * g * 0.5
		crack_mask = max(crack_mask, g)

	# fine roughness
	r += fine_amount * n_fine.get_noise_3dv(c)

	var cav := clampf(depth_acc / 0.06, 0.0, 1.0)
	var h01 := clampf(0.5 + (r - 1.0) * 2.0, 0.0, 1.0)
	return Vector4(r, cav, crack_mask, h01)


func _spherify(p: Vector3) -> Vector3:
	var x2 := p.x * p.x
	var y2 := p.y * p.y
	var z2 := p.z * p.z
	return Vector3(
		p.x * sqrt(1.0 - y2 * 0.5 - z2 * 0.5 + y2 * z2 / 3.0),
		p.y * sqrt(1.0 - z2 * 0.5 - x2 * 0.5 + z2 * x2 / 3.0),
		p.z * sqrt(1.0 - x2 * 0.5 - y2 * 0.5 + x2 * y2 / 3.0))


## 1-ring low-pass over the welded mesh. Vertex normals baked from a surface that contains
## detail finer than the grid jump wildly from vertex to vertex; interpolating them gives
## noisy, blocky shading. Each pass averages a vertex with its triangle neighbours.
func _smooth_mesh(src: ArrayMesh) -> ArrayMesh:
	var arrs := src.surface_get_arrays(0)
	var idx: PackedInt32Array = arrs[Mesh.ARRAY_INDEX]
	var nrm: PackedVector3Array = arrs[Mesh.ARRAY_NORMAL]
	var col: PackedColorArray = arrs[Mesh.ARRAY_COLOR]
	var nv := nrm.size()
	var tri_count := int(idx.size() / 3.0)

	for pass_i in normal_smooth_iters:
		var acc := PackedVector3Array()
		acc.resize(nv)
		for ti in tri_count:
			var a := idx[ti * 3]
			var b := idx[ti * 3 + 1]
			var c := idx[ti * 3 + 2]
			var s := nrm[a] + nrm[b] + nrm[c]
			acc[a] += s
			acc[b] += s
			acc[c] += s
			if ti % 100000 == 0:
				await get_tree().process_frame
		for i in nv:
			var l := acc[i].length()
			if l > 1.0e-6:
				nrm[i] = acc[i] / l
		status = "normal smooth %d/%d" % [pass_i + 1, normal_smooth_iters]
		await get_tree().process_frame

	for pass_i in color_smooth_iters:
		var accc := PackedVector3Array()
		accc.resize(nv)
		var cnt := PackedFloat32Array()
		cnt.resize(nv)
		for ti in tri_count:
			var a := idx[ti * 3]
			var b := idx[ti * 3 + 1]
			var c := idx[ti * 3 + 2]
			var s := Vector3(col[a].r + col[b].r + col[c].r, col[a].g + col[b].g + col[c].g, col[a].b + col[b].b + col[c].b)
			accc[a] += s
			accc[b] += s
			accc[c] += s
			cnt[a] += 3.0
			cnt[b] += 3.0
			cnt[c] += 3.0
			if ti % 100000 == 0:
				await get_tree().process_frame
		for i in nv:
			if cnt[i] > 0.0:
				var v := accc[i] / cnt[i]
				col[i] = Color(v.x, v.y, v.z, 1.0)
		status = "colour smooth %d/%d" % [pass_i + 1, color_smooth_iters]
		await get_tree().process_frame

	arrs[Mesh.ARRAY_NORMAL] = nrm
	arrs[Mesh.ARRAY_COLOR] = col
	arrs[Mesh.ARRAY_TANGENT] = null
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
	return out


func build() -> void:
	if _building:
		return
	_building = true
	var t0 := Time.get_ticks_msec()
	_setup_noise()
	var res := resolution
	var n := res + 1
	var per_face := n * n
	var verts := PackedVector3Array()
	verts.resize(6 * per_face)
	var cols := PackedColorArray()
	cols.resize(6 * per_face)
	var idx := PackedInt32Array()
	idx.resize(6 * res * res * 6)

	var k := 0
	var ii := 0
	for f in 6:
		var fn: Vector3 = FACES[f][0]
		var fa: Vector3 = FACES[f][1]
		var fb: Vector3 = FACES[f][2]
		var base := f * per_face
		for j in n:
			var v := 2.0 * j / res - 1.0
			for i in n:
				var u := 2.0 * i / res - 1.0
				var d := _spherify(fn + fa * u + fb * v)
				d = (d * 1.0e5).round() / 1.0e5 # canonical => seams match exactly
				d = d.normalized()
				var h := _sample(d)
				verts[k] = d * h.x * elongation
				cols[k] = Color(h.y, h.z, h.w, 1.0)
				k += 1
			if j % 6 == 5:
				status = "face %d row %d/%d" % [f, j, n]
				await get_tree().process_frame
		for j in res:
			for i in res:
				var a := base + j * n + i
				var b := a + 1
				var c := a + n
				var e := c + 1
				idx[ii] = a
				idx[ii + 1] = c
				idx[ii + 2] = b
				idx[ii + 3] = b
				idx[ii + 4] = c
				idx[ii + 5] = e
				ii += 6

	status = "normals..."
	await get_tree().process_frame
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var st := SurfaceTool.new()
	st.create_from(am, 0)
	st.generate_normals()
	var final_mesh := st.commit()
	if normal_smooth_iters > 0 or color_smooth_iters > 0:
		status = "smoothing..."
		await get_tree().process_frame
		final_mesh = await _smooth_mesh(final_mesh)
	final_mesh.custom_aabb = final_mesh.get_aabb().grow(0.02)
	var err := ResourceSaver.save(final_mesh, mesh_path, ResourceSaver.FLAG_COMPRESS)
	if err == OK:
		final_mesh.take_over_path(mesh_path)
	mesh = final_mesh
	status = "done %d verts, %d ms (save=%d)" % [verts.size(), Time.get_ticks_msec() - t0, err]
	_building = false
