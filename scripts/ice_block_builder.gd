@tool
extends MeshInstance3D
## Procedural comet-nucleus / frozen-dwarf-planet mesh, deterministic seed.
## Pipeline: cube-sphere -> radial fbm irregularity -> contact-binary pinch
## (optional bilobe) -> impact craters (bowl + raised rim) -> subtle planar
## shear cuts -> fbm detail -> smooth normals (centre-oriented) + vertex colors
## (R = cavity/dust pocket incl. crater floors, G = fresh ice exposure: crater
## bowls & shear facets). No UVs, no imported assets. Deterministic seed.

@export_range(8, 64) var subdivision := 30
@export var radius := Vector3(1.05, 0.92, 1.0)
@export_range(0.0, 1.0) var bilobe := 0.45
## Contact-binary waist direction (lobes form toward both poles of this axis).
@export var bilobe_axis := Vector3(0.25, 1.0, 0.15)
@export_range(0, 24) var crater_count := 14
@export_range(0.0, 1.0) var crater_depth := 0.35
@export_range(0, 12) var shear_cuts := 4
@export var seed_value := 20260930

const ROT := Basis(
	Vector3(0.0, 0.8, 0.6),
	Vector3(-0.8, 0.36, -0.48),
	Vector3(-0.6, -0.48, 0.64))

# Faces whose u/v grid winds clockwise seen from outside: triangles reversed.
const FACE_FLIP := [true, false, false, true, true, false]

var _cut_n: Array[Vector3] = []
var _cut_d: Array[float] = []

func _hash13(p3: Vector3) -> float:
	p3 = p3 * 0.1031
	p3 = Vector3(fposmod(p3.x, 1.0), fposmod(p3.y, 1.0), fposmod(p3.z, 1.0))
	var d := p3.dot(Vector3(p3.z, p3.y, p3.x)) + 31.32
	p3 += Vector3(d, d, d)
	return fposmod((p3.x + p3.y) * p3.z, 1.0)

func _vnoise(p: Vector3) -> float:
	var i := p.floor()
	var f := p - i
	var u := f * f * f * (f * (f * 6.0 - Vector3(15.0, 15.0, 15.0)) + Vector3(10.0, 10.0, 10.0))
	var v000 := _hash13(i)
	var v100 := _hash13(i + Vector3(1, 0, 0))
	var v010 := _hash13(i + Vector3(0, 1, 0))
	var v110 := _hash13(i + Vector3(1, 1, 0))
	var v001 := _hash13(i + Vector3(0, 0, 1))
	var v101 := _hash13(i + Vector3(1, 0, 1))
	var v011 := _hash13(i + Vector3(0, 1, 1))
	var v111 := _hash13(i + Vector3(1, 1, 1))
	return lerp(
		lerp(lerp(v000, v100, u.x), lerp(v010, v110, u.x), u.y),
		lerp(lerp(v001, v101, u.x), lerp(v011, v111, u.x), u.y),
		u.z)

func _fbm(p: Vector3, octaves: int) -> float:
	var a := 1.0
	var norm := 0.0
	var sum := 0.0
	var q := p
	for i in octaves:
		sum += a * (_vnoise(q) - 0.5) * 2.0
		norm += a
		q = (ROT * q) * 2.03
		a *= 0.5
	return sum / norm

func _cube_face(i: int, u: float, v: float) -> Vector3:
	# unit cube surface, u/v in [-1, 1]
	var w := 1.0
	match i:
		0: return Vector3(w, u, v)
		1: return Vector3(-w, u, v)
		2: return Vector3(u, w, v)
		3: return Vector3(u, -w, v)
		4: return Vector3(u, v, w)
		_: return Vector3(u, v, -w)

func _apply_cuts(p: Vector3) -> Vector3:
	var q := p
	for i in _cut_n.size():
		var s := _cut_n[i].dot(q) - _cut_d[i]
		if s > 0.0:
			q -= _cut_n[i] * s
	return q

func _facet_mask(p: Vector3) -> float:
	var m := 0.0
	for i in _cut_n.size():
		m = maxf(m, clampf(1.0 - absf(_cut_n[i].dot(p) - _cut_d[i]) * 9.0, 0.0, 1.0))
	return m

func _build_mesh() -> void:
	var n := subdivision
	var grid := n + 1
	var axis := bilobe_axis.normalized()
	# pass 1: irregular spherical body with optional contact-binary pinch
	var base: Array[Vector3] = []
	base.resize(6 * grid * grid)
	for face in 6:
		for iy in n + 1:
			for ix in n + 1:
				var u := float(ix) / float(n) * 2.0 - 1.0
				var v := float(iy) / float(n) * 2.0 - 1.0
				var dir := _cube_face(face, u, v).normalized()
				var p := Vector3(dir.x * radius.x, dir.y * radius.y, dir.z * radius.z)
				var w := 0.15 * _fbm(dir * 1.5 + Vector3(3.1, 3.1, 3.1), 4)
				w += 0.06 * _fbm(dir * 3.6 + Vector3(17.0, 17.0, 17.0), 3)
				p += dir * w
				var t := clampf(dir.dot(axis), -1.0, 1.0)
				var waist := exp(-t * t / 0.09)
				p *= 1.0 - bilobe * 0.20 * waist
				p *= 1.0 + bilobe * 0.12 * (t * t - 0.33)
				base[face * grid * grid + iy * grid + ix] = p
	# pass 2: impact craters — smooth bowl below, raised rim at the crest
	var crater_dir: Array[Vector3] = []
	var crater_rad: Array[float] = []
	var crater_dep: Array[float] = []
	for i in crater_count:
		var h := float(i) * 13.7 + seed_value * 0.001
		crater_dir.append(Vector3(
			_hash13(Vector3(h, 4.2, 8.1)) - 0.5,
			_hash13(Vector3(7.7, h, 2.3)) - 0.5,
			_hash13(Vector3(1.9, 6.6, h)) - 0.5).normalized())
		crater_rad.append(0.14 + _hash13(Vector3(h, 9.1, 0.5)) * 0.30)
		crater_dep.append((0.35 + _hash13(Vector3(h, 3.3, 7.7)) * 0.65) * crater_depth)
	var fresh: Array[float] = []
	fresh.resize(base.size())
	for idx in base.size():
		var p := base[idx]
		var dn := p.normalized()
		var hgt := 0.0
		for i in crater_count:
			var cg := clampf(dn.dot(crater_dir[i]), -1.0, 1.0)
			var x := acos(cg) / crater_rad[i]
			if x >= 1.6:
				continue
			if x < 1.0:
				var bowl := 1.0 - x * x
				hgt -= crater_dep[i] * bowl * bowl
				fresh[idx] = maxf(fresh[idx], clampf(1.2 - x, 0.0, 1.0))
			hgt += crater_dep[i] * 0.30 * exp(-pow((x - 1.06) / 0.16, 2.0))
		base[idx] = p + dn * hgt
	# pass 3: subtle planar shear scars, placed from the TRUE support of the
	# post-crater shape so they only shave the surface
	_cut_n.clear()
	_cut_d.clear()
	for i in shear_cuts:
		var h2 := float(i) * 29.13 + seed_value * 0.002
		var pn := Vector3(
			_hash13(Vector3(h2, 1.7, 9.2)) - 0.5,
			_hash13(Vector3(5.3, h2, 3.1)) - 0.5,
			_hash13(Vector3(2.9, 8.8, h2)) - 0.5).normalized()
		var side := 1.0 if _hash13(Vector3(h2, 6.6, 0.3)) > 0.5 else -1.0
		var cn := pn * side
		var support := -1e9
		for p in base:
			support = maxf(support, cn.dot(p))
		_cut_n.append(cn)
		_cut_d.append(support - (0.10 + _hash13(Vector3(h2, 2.2, 4.4)) * 0.10))
	# pass 4: cuts + fine fbm detail
	var verts: Array[Vector3] = []
	var disps: Array[float] = []
	for idx in base.size():
		var p := _apply_cuts(base[idx])
		var dn := p.normalized()
		var disp := 0.08 * _fbm(p * 2.3 + Vector3(5.5, 5.5, 5.5), 4)
		disp += 0.035 * _fbm(p * 5.2 + Vector3(23.0, 23.0, 23.0), 3)
		disp += 0.012 * _fbm(p * 11.5 + Vector3(41.0, 41.0, 41.0), 3)
		p += dn * disp
		verts.append(p)
		disps.append(disp)
	# triangles (positions first, then normals/colors)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in 6:
		var fbase := face * grid * grid
		for iy in n:
			for ix in n:
				var a := fbase + iy * grid + ix
				var b := a + 1
				var c := a + grid
				var d := c + 1
				var tris := [[a, d, c], [a, b, d]] if FACE_FLIP[face] else [[a, c, d], [a, d, b]]
				for tri in tris:
					st.add_vertex(verts[tri[0]]); st.add_vertex(verts[tri[1]]); st.add_vertex(verts[tri[2]])
	# smooth normals by accumulation, oriented outward against the body centre
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	for face in 6:
		var fbase := face * grid * grid
		for iy in n:
			for ix in n:
				var a := fbase + iy * grid + ix
				var b := a + 1
				var c := a + grid
				var d := c + 1
				var tris := [[a, d, c], [a, b, d]] if FACE_FLIP[face] else [[a, c, d], [a, d, b]]
				for tri in tris:
					var pn := (verts[tri[1]] - verts[tri[0]]).cross(verts[tri[2]] - verts[tri[0]])
					var cen := (verts[tri[0]] + verts[tri[1]] + verts[tri[2]]) / 3.0
					if pn.dot(cen) < 0.0:
						pn = -pn
					for vi in tri:
						normals[vi] += pn
	# finish: normals + colors
	st.clear()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in 6:
		var fbase := face * grid * grid
		for iy in n:
			for ix in n:
				var a := fbase + iy * grid + ix
				var b := a + 1
				var c := a + grid
				var d := c + 1
				var tris := [[a, d, c], [a, b, d]] if FACE_FLIP[face] else [[a, c, d], [a, d, b]]
				for tri in tris:
					for vi in tri:
						st.set_normal(normals[vi].normalized())
						# valleys & crater floors = dust pockets; craters & cuts = fresh ice
						var cavity := clampf(0.55 - disps[vi] * 3.0 + fresh[vi] * 0.3, 0.0, 1.0)
						var ice_exposure := maxf(_facet_mask(verts[vi]), fresh[vi] * 0.8)
						st.set_color(Color(cavity, ice_exposure, 0.0))
						st.add_vertex(verts[vi])
	mesh = st.commit()

func _ready() -> void:
	_build_mesh()
