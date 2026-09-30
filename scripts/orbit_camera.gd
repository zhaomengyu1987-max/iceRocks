extends Camera3D
## Orbit camera centred on the ice nucleus.
##   Left-drag  : orbit          Mouse wheel / pinch : zoom
##   Space      : pause/resume the nucleus tumble      R : reset view

@export var target_path: NodePath = ^"../Nucleus"
@export_range(0.05, 1.0, 0.01) var rotate_speed_deg_per_px := 0.25
@export_range(0.02, 0.4, 0.01) var zoom_step := 0.10 ## fraction of distance per wheel notch
@export var max_distance := 1500.0
@export_range(0.0, 30.0, 0.5) var smoothing := 12.0 ## higher = snappier, 0 = instant
@export var surface_margin := 3.0 ## extra clearance above the surface when zooming in

var _target: Node3D
var _yaw := 0.0
var _pitch := 0.0
var _dist := 300.0
var _t_yaw := 0.0
var _t_pitch := 0.0
var _t_dist := 300.0
var _init_yaw := 0.0
var _init_pitch := 0.0
var _init_dist := 300.0
var _half := Vector3(1, 1, 1) ## world-space half extents of the nucleus
var _saved_spin := -1.0
const LITE_MESH := "res://meshes/ice_nucleus_mesh_lite.res"
var _tri: TriangleMesh
var _dragging := false
var _last_pos := Vector2.ZERO


func _ready() -> void:
	_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		set_process(false)
		push_warning("OrbitCamera: target not found at %s" % target_path)
		return
	var mi := _target as MeshInstance3D
	if mi and mi.mesh:
		_half = mi.mesh.get_aabb().size * 0.5 * mi.global_transform.basis.get_scale()
		# collision proxy for zoom limits: the light mesh is plenty accurate and cheap to build
		var proxy: Mesh = mi.mesh
		if ResourceLoader.exists(LITE_MESH):
			proxy = load(LITE_MESH)
		_tri = proxy.generate_triangle_mesh()
	var off := global_position - _target.global_position
	_dist = off.length()
	_yaw = atan2(off.x, off.z)
	_pitch = asin(clampf(off.y / maxf(_dist, 0.001), -1.0, 1.0))
	_t_yaw = _yaw
	_t_pitch = _pitch
	_t_dist = _dist
	_init_yaw = _yaw
	_init_pitch = _pitch
	_init_dist = _dist
	_apply()


## Distance from the centre to the outermost surface along a view direction.
## Exact: ray-cast against the mesh triangles in the nucleus' own (rotating) space.
func _surface_radius(dir: Vector3) -> float:
	var t := _target.global_transform
	var inv := t.affine_inverse()
	var scale := t.basis.get_scale().x
	if _tri != null:
		var far_pt := inv * (t.origin + dir * 10000.0)
		var centre := inv * t.origin
		var hit: Dictionary = _tri.intersect_ray(far_pt, (centre - far_pt).normalized())
		if not hit.is_empty():
			return (hit["position"] as Vector3).distance_to(centre) * scale
	# fallback: ellipsoid fitted to the mesh bounds
	var h := _half * 1.25
	var k := (dir.x / h.x) * (dir.x / h.x) + (dir.y / h.y) * (dir.y / h.y) + (dir.z / h.z) * (dir.z / h.z)
	return 1.0 / sqrt(maxf(k, 1.0e-6))


func _dir(yaw: float, pitch: float) -> Vector3:
	return Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))


func _min_distance() -> float:
	return _surface_radius(_dir(_t_yaw, _t_pitch)) + surface_margin


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_last_pos = event.position
		return
	if event is InputEventMouseMotion:
		var rel: Vector2 = event.relative
		if rel == Vector2.ZERO:
			rel = event.position - _last_pos
		_last_pos = event.position
		if _dragging or (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
			var s := deg_to_rad(rotate_speed_deg_per_px)
			_t_yaw -= rel.x * s
			_t_pitch = clampf(_t_pitch + rel.y * s, deg_to_rad(-89.0), deg_to_rad(89.0))
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(1.0 - zoom_step)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(1.0 + zoom_step)
	elif event is InputEventMagnifyGesture:
		_zoom(1.0 / maxf(event.factor, 0.1))
	elif event is InputEventPanGesture:
		var s2 := deg_to_rad(rotate_speed_deg_per_px) * 4.0
		_t_yaw -= event.delta.x * s2
		_t_pitch = clampf(_t_pitch + event.delta.y * s2, deg_to_rad(-89.0), deg_to_rad(89.0))
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_toggle_spin()
		elif event.keycode == KEY_R:
			_t_yaw = _init_yaw
			_t_pitch = _init_pitch
			_t_dist = _init_dist


func _zoom(mult: float) -> void:
	_t_dist = clampf(_t_dist * mult, _min_distance(), max_distance)


func _toggle_spin() -> void:
	if _target == null or not ("spin_speed_deg" in _target):
		return
	if _saved_spin < 0.0:
		_saved_spin = _target.spin_speed_deg
		_target.spin_speed_deg = 0.0
	else:
		_target.spin_speed_deg = _saved_spin
		_saved_spin = -1.0


func _process(delta: float) -> void:
	_t_dist = clampf(_t_dist, _min_distance(), max_distance)
	var w := 1.0 if smoothing <= 0.0 else 1.0 - exp(-smoothing * delta)
	_yaw = lerp_angle(_yaw, _t_yaw, w)
	_pitch = lerpf(_pitch, _t_pitch, w)
	_dist = lerpf(_dist, _t_dist, w)
	# never let the camera sink into the ice (the nucleus tumbles towards/away from us)
	_dist = maxf(_dist, _surface_radius(_dir(_yaw, _pitch)) + surface_margin)
	_apply()


func _apply() -> void:
	var c := _target.global_position
	var dir := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch))
	global_position = c + dir * _dist
	look_at(c, Vector3.UP)
