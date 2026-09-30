extends Node3D
## Chooses / switches the render-quality profile.
##  HIGH: fully procedural per-pixel shader, SSAO, glow, cascaded shadows (dedicated GPU).
##  LOW : baked-texture shader, light mesh, baked Milky Way, no SSAO/glow, reduced 3D
##        resolution (integrated GPUs such as Intel HD 4600, Compatibility renderer).
## The player's choice (Auto / High / Low) is persisted in user://ice_settings.cfg.
## Launch overrides:  --low   --high      Quick toggle: F9

signal quality_changed(effective: int)

enum Quality { AUTO, HIGH, LOW }

@export var quality: Quality = Quality.AUTO ## default mode when nothing is saved
@export_range(0.4, 1.0, 0.05) var low_render_scale := 0.8

## The renderer is fixed for the lifetime of a process, so the two profiles run on different
## renderers: HIGH -> Forward+ (SSAO, SSS, glow, TAA), LOW -> Compatibility (OpenGL, old GPUs).
## In an exported build, choosing a profile whose renderer differs from the running one
## relaunches the game once with `--rendering-method`. In the editor this is skipped and the
## profile is only switched in-process (the lite assets also run fine on Forward+).
## If Forward+ is unavailable the engine falls back to OpenGL by itself
## (rendering/rendering_device/fallback_to_opengl3); `--renderer-relaunched` stops relaunch loops.
const RENDERER_HIGH := "forward_plus"
const RENDERER_LOW := "gl_compatibility"
const RELAUNCH_FLAG := "--renderer-relaunched"
const SETTINGS_PATH := "user://ice_settings.cfg"
const WEAK_GPU_KEYWORDS := [
	"intel", "uhd", "iris", "hd graphics", "vega", "radeon(tm) graphics",
	"radeon graphics", "llvmpipe", "software", "microsoft basic", "swiftshader",
]

@onready var _nucleus: MeshInstance3D = $Nucleus
@onready var _env: WorldEnvironment = $WorldEnvironment
@onready var _sun: DirectionalLight3D = $Sun

var mode: int = Quality.AUTO ## what the player selected
var effective: int = Quality.HIGH ## what is actually applied (never AUTO)

var _high_mesh: Mesh
var _high_material: Material
var _high_env: Environment
var _lite_mesh: Mesh
var _lite_material: Material
var _lite_env: Environment
var _forced := false
var _relaunched := false ## this process was started by a renderer switch


func _ready() -> void:
	_high_mesh = _nucleus.mesh
	_high_material = _nucleus.material_override
	_high_env = _env.environment

	mode = quality
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		mode = int(cfg.get_value("quality", "mode", mode))
		low_render_scale = float(cfg.get_value("quality", "low_scale", low_render_scale))
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a == "--low":
			mode = Quality.LOW
			_forced = true
		elif a == "--high":
			mode = Quality.HIGH
			_forced = true
		elif a == RELAUNCH_FLAG:
			_relaunched = true
	if _relaunch_if_needed(_resolve(mode), true):
		return
	_apply_mode()


func _process(_delta: float) -> void:
	_update_shadow_range()


## The sun's shadow map only needs to cover what the camera can actually see of the
## nucleus. A fixed 800-unit range wastes almost every texel on empty space, which makes
## shadow edges blocky and makes them crawl while the body rotates. So the range follows
## the camera: far view -> whole body, close view -> a few dozen units (very fine texels).
func _update_shadow_range() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var d := cam.global_position.distance_to(_nucleus.global_position)
	var far_side := d + 130.0 # reaches past the far side of the body (radius ~95)
	var near_surface := maxf(d - 95.0, 1.0)
	_sun.directional_shadow_max_distance = clampf(near_surface * 3.0 + 80.0, 90.0, far_side)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F9:
		set_mode(Quality.HIGH if effective == Quality.LOW else Quality.LOW)


## Player-facing setter: AUTO / HIGH / LOW.
func set_mode(m: int) -> void:
	mode = m
	_save()
	if _relaunch_if_needed(_resolve(m), false):
		return
	_apply_mode()


func set_low_scale(s: float) -> void:
	low_render_scale = clampf(s, 0.4, 1.0)
	_save()
	if effective == Quality.LOW:
		_apply_mode()


func is_weak_gpu() -> bool:
	# The OpenGL path is what old GPUs / iGPUs end up on. Not conclusive when we chose
	# Compatibility ourselves (relaunch): then judge by the adapter below.
	if RenderingServer.get_current_rendering_method() == "gl_compatibility" and not _relaunched:
		return true
	var t := RenderingServer.get_video_adapter_type()
	if t in [RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU, RenderingDevice.DEVICE_TYPE_CPU, RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU]:
		return true
	var n := RenderingServer.get_video_adapter_name().to_lower()
	if n.contains("arc"):
		return false
	for k in WEAK_GPU_KEYWORDS:
		if n.contains(k):
			return true
	return false


func describe() -> String:
	return "%s  |  %s  |  %s" % [
		"低画质" if effective == Quality.LOW else "高画质",
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_video_adapter_name()]


func _save() -> void:
	if _forced:
		return
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH) # keep other sections (UI prefs)
	cfg.set_value("quality", "mode", mode)
	cfg.set_value("quality", "low_scale", low_render_scale)
	cfg.save(SETTINGS_PATH)


## AUTO -> HIGH or LOW; never returns AUTO.
func _resolve(m: int) -> int:
	if m == Quality.AUTO:
		return Quality.LOW if is_weak_gpu() else Quality.HIGH
	return m


func _apply_mode() -> void:
	_apply(_resolve(mode))


## Relaunches the exported game with the renderer that matches profile `q`.
## Returns true when a relaunch was started (the caller must stop what it is doing).
func _relaunch_if_needed(q: int, at_startup: bool) -> bool:
	if OS.has_feature("editor") or OS.has_feature("web") or OS.has_feature("mobile"):
		return false
	if at_startup and _relaunched:
		return false # already relaunched once: accept whatever renderer we got
	var want := RENDERER_LOW if q == Quality.LOW else RENDERER_HIGH
	if RenderingServer.get_current_rendering_method() == want:
		return false
	var args := PackedStringArray(["--rendering-method", want, RELAUNCH_FLAG])
	var skip_next := false
	for a in OS.get_cmdline_args():
		if skip_next:
			skip_next = false
		elif a == "--rendering-method":
			skip_next = true
		elif a.begins_with("--rendering-method=") or a == RELAUNCH_FLAG or a == "--low" or a == "--high":
			continue
		else:
			args.append(a)
	if OS.create_process(OS.get_executable_path(), args) <= 0:
		push_warning("[IceComet] could not relaunch with renderer %s" % want)
		return false
	get_tree().quit()
	return true


func _apply(q: int) -> void:
	effective = q
	var vp := get_viewport()
	if q == Quality.LOW:
		if _lite_mesh == null:
			_lite_mesh = load("res://meshes/ice_nucleus_mesh_lite.res")
			_lite_material = load("res://materials/ice_surface_lite_material.tres")
			_lite_env = load("res://environments/space_environment_lite.tres")
		_nucleus.mesh = _lite_mesh
		_nucleus.material_override = _lite_material
		_env.environment = _lite_env
		# shadows: single split, modest atlas, cheap filter
		RenderingServer.directional_shadow_atlas_set_size(2048, true)
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_LOW)
		_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		_sun.shadow_blur = 1.0
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.use_taa = false
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = low_render_scale
	else:
		_nucleus.mesh = _high_mesh
		_nucleus.material_override = _high_material
		_env.environment = _high_env
		# shadows: one big 4096 split fitted to the visible range (see _update_shadow_range),
		# high-quality PCF, slightly widened blur to hide texel stair-steps
		RenderingServer.directional_shadow_atlas_set_size(4096, true)
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
		_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		_sun.shadow_blur = 1.6
		# anti-aliasing: MSAA smooths silhouettes; TAA (Forward+ only) also calms
		# sub-pixel shader detail such as thin cracks and stars while the body rotates
		vp.msaa_3d = Viewport.MSAA_4X
		vp.use_taa = RenderingServer.get_current_rendering_method() == "forward_plus"
		vp.scaling_3d_scale = 1.0
	_update_shadow_range()
	print("[IceComet] quality=%s (mode=%s)  renderer=%s  gpu=%s" % [
		"LOW" if q == Quality.LOW else "HIGH",
		["AUTO", "HIGH", "LOW"][mode],
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_video_adapter_name()])
	quality_changed.emit(q)
