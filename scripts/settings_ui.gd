extends CanvasLayer
## In-game settings: a "设置" button (top-right) opening a quality panel, plus an always-visible
## status tag (bottom-left) showing the *effective* quality and FPS so it is easy to verify.
## Must be a child of the node that owns quality_manager.gd.

const SETTINGS_PATH := "user://ice_settings.cfg"
const MODE_NAMES := ["自动", "高画质", "低画质"]

var _qm: Node
var _panel: PanelContainer
var _toggle_btn: Button
var _opt: OptionButton
var _scale_slider: HSlider
var _scale_label: Label
var _info: Label
var _hud: Label
var _fps_check: CheckBox
var _show_fps := true
var _hud_timer := 0.0
var _syncing := false


func _ready() -> void:
	layer = 20
	_qm = get_parent()
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		_show_fps = bool(cfg.get_value("ui", "show_fps", true))
	_build()
	_qm.quality_changed.connect(_on_quality_changed)
	_sync.call_deferred()


func _process(delta: float) -> void:
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.25
		_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_panel.visible = not _panel.visible
		get_viewport().set_input_as_handled()


func _build() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _make_theme()
	add_child(root)

	# --- top-right: button + panel -------------------------------------------------
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	vb.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	vb.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	root.add_child(vb)

	_toggle_btn = Button.new()
	_toggle_btn.text = "设置"
	_toggle_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	_toggle_btn.custom_minimum_size = Vector2(88, 34)
	_toggle_btn.focus_mode = Control.FOCUS_NONE
	_toggle_btn.pressed.connect(func(): _panel.visible = not _panel.visible)
	vb.add_child(_toggle_btn)

	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.custom_minimum_size = Vector2(320, 0)
	vb.add_child(_panel)

	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 14)
	_panel.add_child(m)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	m.add_child(col)

	var title := Label.new()
	title.text = "画质设置"
	title.add_theme_font_size_override("font_size", 20)
	col.add_child(title)

	var row := HBoxContainer.new()
	col.add_child(row)
	var l1 := Label.new()
	l1.text = "画质"
	l1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l1)
	_opt = OptionButton.new()
	_opt.focus_mode = Control.FOCUS_NONE
	_opt.custom_minimum_size = Vector2(170, 0)
	for n in MODE_NAMES:
		_opt.add_item(n)
	_opt.item_selected.connect(_on_mode_selected)
	row.add_child(_opt)

	_scale_label = Label.new()
	col.add_child(_scale_label)
	_scale_slider = HSlider.new()
	_scale_slider.min_value = 0.4
	_scale_slider.max_value = 1.0
	_scale_slider.step = 0.05
	_scale_slider.set_value_no_signal(0.8)
	_scale_slider.focus_mode = Control.FOCUS_NONE
	col.add_child(_scale_slider)
	# connect only AFTER the range is configured: setting min/max would otherwise emit
	# value_changed and re-apply quality before the quality manager is even ready
	_scale_slider.value_changed.connect(_on_scale_changed)

	_fps_check = CheckBox.new()
	_fps_check.text = "显示状态与帧率"
	_fps_check.focus_mode = Control.FOCUS_NONE
	_fps_check.button_pressed = _show_fps
	_fps_check.toggled.connect(_on_fps_toggled)
	col.add_child(_fps_check)

	col.add_child(HSeparator.new())

	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.modulate = Color(0.75, 0.85, 1.0)
	col.add_child(_info)

	var hint := Label.new()
	hint.text = "F9 快速切换 · 空格 暂停自转 · R 复位视角 · Esc 开关此面板\n高画质使用 Forward+，低画质使用 Compatibility；切换时程序会自动重启一次（导出版本）。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.add_theme_font_size_override("font_size", 13)
	col.add_child(hint)

	# --- bottom-left: always-visible status ---------------------------------------
	_hud = Label.new()
	_hud.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	_hud.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hud.add_theme_font_size_override("font_size", 15)
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_hud.add_theme_constant_override("outline_size", 4)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_hud)


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 16
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.12, 0.88)
	sb.border_color = Color(0.35, 0.55, 0.85, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	t.set_stylebox("panel", "PanelContainer", sb)
	return t


func _sync() -> void:
	_syncing = true
	_opt.select(_qm.mode)
	_scale_slider.set_value_no_signal(_qm.low_render_scale)
	_syncing = false
	_refresh_labels()
	_update_hud()


func _refresh_labels() -> void:
	var low: bool = _qm.effective == 2
	_opt.set_item_text(0, "自动（当前：%s）" % ("低" if low else "高"))
	_scale_label.text = "低画质渲染分辨率：%d%%" % roundi(_scale_slider.value * 100.0)
	_scale_slider.editable = low
	_scale_label.modulate = Color(1, 1, 1, 1.0 if low else 0.4)
	_info.text = "当前生效：%s\n渲染器：%s\n显卡：%s" % [
		"低画质" if low else "高画质",
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_video_adapter_name()]


func _update_hud() -> void:
	_hud.visible = _show_fps
	if not _show_fps:
		return
	var low: bool = _qm.effective == 2
	_hud.text = "%s · %d FPS" % ["低画质" if low else "高画质", Engine.get_frames_per_second()]
	_hud.modulate = Color(1.0, 0.85, 0.5) if low else Color(0.6, 1.0, 0.7)


func _on_mode_selected(idx: int) -> void:
	if _syncing:
		return
	_qm.set_mode(idx)


func _on_scale_changed(v: float) -> void:
	if _syncing:
		return
	_scale_label.text = "低画质渲染分辨率：%d%%" % roundi(v * 100.0)
	_qm.set_low_scale(v)


func _on_fps_toggled(on: bool) -> void:
	_show_fps = on
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("ui", "show_fps", on)
	cfg.save(SETTINGS_PATH)
	_update_hud()


func _on_quality_changed(_effective: int) -> void:
	_syncing = true
	_opt.select(_qm.mode)
	_syncing = false
	_refresh_labels()
	_update_hud()
