extends Camera3D
## Minimal orbit camera: slow auto-spin, RMB-drag to orbit, wheel to zoom.

@export var target := Vector3.ZERO
@export var distance := 4.6
@export var pitch := -0.28
@export var yaw := 0.7
@export var auto_spin := 0.05
@export var min_distance := 2.0
@export var max_distance := 9.0

var _rmb := false

func _ready() -> void:
	_apply()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_rmb = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			distance = clampf(distance * 0.92, min_distance, max_distance)
			_apply()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			distance = clampf(distance * 1.08, min_distance, max_distance)
			_apply()
	elif event is InputEventMouseMotion and _rmb:
		var mm := event as InputEventMouseMotion
		yaw -= mm.relative.x * 0.005
		pitch = clampf(pitch - mm.relative.y * 0.005, -1.35, 1.35)
		_apply()

func _process(delta: float) -> void:
	yaw += auto_spin * delta
	_apply()

func _apply() -> void:
	var cp := cos(pitch)
	position = target + Vector3(sin(yaw) * cp, sin(pitch), cos(yaw) * cp) * distance
	look_at(target, Vector3.UP)
