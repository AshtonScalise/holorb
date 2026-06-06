extends Node3D

enum State { MENU, PLAYING, GAMEOVER, SHOP, OUTOFLIVES }

const AD_COINS_REWARD := 50
const COIN_VOL := -4.0
const MILESTONE_VOL := -2.0
const HIT_VOL := 0.0

const SPAWN_Z := -46.0
const SPAWN_SPACING := 15.0
const ARENA_HALF := 4.0
const DRAG_SENS := 0.022
const SAVE_PATH := "user://holerunner.save"

var state: int = State.MENU
var score := 0
var best := 0

var player: Player
var walls: Array = []
var coins: Array = []
var _newest_wall: Wall = null
var _run_coins := 0
var _magnet_active := false  # Coin Magnet consumed for this run

# World
var cam: Camera3D
var cam_base_pos: Vector3
var shake := 0.0

# UI
var ui: CanvasLayer
var score_label: Label
var menu_root: Control
var gameover_root: Control
var final_label: Label
var best_label: Label
var menu_btn: Button
var coin_label: Label
var coin_hud: HBoxContainer
var coins_gained_label: Label
var shop_root: Control
var shop_coin_label: Label
# Item-detail modal (one reusable popup for every shop item)
var modal_root: Control
var _modal_icon: TextureRect
var _modal_title: Label
var _modal_desc: Label
var _modal_info: Label
var _modal_action_btn: Button
var _modal_action := Callable()
var skins_tab_btn: Button
var effects_tab_btn: Button
var items_tab_btn: Button
var _content_list: VBoxContainer   # the scrollable list, rebuilt per tab
var _shop_tab := "skins"
var _card_press_pos := Vector2.ZERO  # for tap-vs-drag detection on cards
var _card_moved := false

# Lives + shields HUD, Zelda-style pip rows, top-left (never shown at the same
# time -- lives on menu/game-over, shields during a run).
var lives_hud: HBoxContainer
var shield_hud: HBoxContainer
var _life_pips: Array = []     # 5 heart TextureRects
var _shield_pips: Array = []   # 5 shield TextureRects
var _heart_full: ImageTexture
var _heart_empty: ImageTexture
var _heart_gold: ImageTexture
var _shield_full: ImageTexture
var _shield_empty: ImageTexture

# Ads / IAP -- the out-of-lives gate (watch ad for lives, or buy Unlimited Lives)
var _reward_action := ""  # "lives" or "coins" -- what the next rewarded ad is for
var outoflives_root: Control
var oot_title_label: Label
var oot_watch_btn: Button
var oot_timer_label: Label
var ad_coins_btn: Button

# Audio
var coin_sfx: AudioStreamPlayer
var milestone_sfx: AudioStreamPlayer
var hit_sfx: AudioStreamPlayer

# Menu ball idle animation
var _menu_t := 0.0
const MILESTONE_EVERY := 10

func _ready() -> void:
	randomize()
	_build_audio()
	_build_world()
	_build_ui()
	best = _load_best()
	Profile.refill_if_new_day()
	Ads.rewarded_completed.connect(_on_rewarded_completed)
	Ads.ads_removed_changed.connect(_on_ads_removed_changed)
	_set_state(State.MENU)

# ---------------------------------------------------------------- Audio setup

func _build_audio() -> void:
	coin_sfx = AudioStreamPlayer.new()
	coin_sfx.volume_db = COIN_VOL
	add_child(coin_sfx)
	coin_sfx.stream = _load_audio("res://assets/audio/coin_pickup.mp3")

	milestone_sfx = AudioStreamPlayer.new()
	milestone_sfx.volume_db = MILESTONE_VOL
	add_child(milestone_sfx)
	milestone_sfx.stream = _load_audio("res://assets/audio/milestone.mp3")

	hit_sfx = AudioStreamPlayer.new()
	hit_sfx.volume_db = HIT_VOL
	add_child(hit_sfx)
	hit_sfx.stream = _load_audio("res://assets/audio/thud.mp3")

	_warm_up_audio()

# The audio output device can drop the very first sound on a cold start, which
# is why the first coin pickup was silent. Prime each player muted at startup,
# then restore real volumes so the first real SFX is audible.
func _warm_up_audio() -> void:
	for pl in [coin_sfx, milestone_sfx, hit_sfx]:
		if pl and pl.stream:
			pl.volume_db = -80.0
			pl.play()
	await get_tree().create_timer(0.5).timeout
	for pl in [coin_sfx, milestone_sfx, hit_sfx]:
		if pl and pl.playing:
			pl.stop()
	coin_sfx.volume_db = COIN_VOL
	milestone_sfx.volume_db = MILESTONE_VOL
	hit_sfx.volume_db = HIT_VOL

# Prefer the editor-imported resource (best for exported builds); fall back to a
# raw read so the sound still works before the asset has been imported.
func _load_audio(path: String) -> AudioStream:
	if ResourceLoader.exists(path):
		var res := load(path)
		if res is AudioStream:
			return res
	# Fallback: read the raw mp3 so the sound still works before the asset has
	# been imported (or when the imported resource was built by a different
	# engine version than the one running).
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			var s := AudioStreamMP3.new()
			s.data = f.get_buffer(f.get_length())
			f.close()
			return s
	return null

# ---------------------------------------------------------------- World setup

func _build_world() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.62)
	env.ambient_light_energy = 0.7
	env.fog_enabled = true
	env.fog_light_color = Color(0.07, 0.08, 0.13)
	env.fog_density = 0.015
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-58), deg_to_rad(-35), 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)

	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.14, 0.15, 0.2)
	fmat.roughness = 1.0
	ground.mesh = pm
	ground.material_override = fmat
	add_child(ground)

	cam = Camera3D.new()
	cam.position = Vector3(0, 7.5, 10.0)
	cam.fov = 60
	add_child(cam)
	cam.look_at(Vector3(0, 0.5, -7.0), Vector3.UP)
	cam_base_pos = cam.position

	player = Player.new()
	add_child(player)

# ------------------------------------------------------------------- UI setup

func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)

	score_label = _make_label("0", 84)
	score_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	score_label.offset_top = 50
	score_label.offset_bottom = 180
	ui.add_child(score_label)

	# Live coin counter with a coin icon, top-right.
	coin_hud = HBoxContainer.new()
	coin_hud.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	coin_hud.offset_left = -320
	coin_hud.offset_right = -30
	coin_hud.offset_top = 40
	coin_hud.offset_bottom = 104
	coin_hud.alignment = BoxContainer.ALIGNMENT_END
	coin_hud.add_theme_constant_override("separation", 10)
	coin_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(coin_hud)
	var coin_icon := TextureRect.new()
	coin_icon.texture = _make_coin_icon(58)
	coin_icon.custom_minimum_size = Vector2(58, 58)
	coin_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	coin_hud.add_child(coin_icon)
	coin_label = _make_label("0", 44)
	coin_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	coin_hud.add_child(coin_label)

	menu_root = _make_screen()
	ui.add_child(menu_root)
	var mv := _make_vbox(menu_root)
	mv.add_child(_make_label("HOLORB", 96))
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 70)
	mv.add_child(spacer)
	var play_btn := _make_button("PLAY", 46, true)
	play_btn.pressed.connect(_start_game)
	mv.add_child(play_btn)
	var shop_btn := _make_button("SHOP", 36)
	shop_btn.pressed.connect(_open_shop)
	mv.add_child(shop_btn)

	gameover_root = _make_screen()
	ui.add_child(gameover_root)
	var gv := _make_vbox(gameover_root)
	gv.add_child(_make_label("GAME OVER", 80))
	final_label = _make_label("Score: 0", 52)
	gv.add_child(final_label)
	best_label = _make_label("Best: 0", 44)
	gv.add_child(best_label)
	coins_gained_label = _make_label("", 38)
	coins_gained_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	gv.add_child(coins_gained_label)
	var sp2 := Control.new()
	sp2.custom_minimum_size = Vector2(0, 40)
	gv.add_child(sp2)
	var retry_btn := _make_button("RETRY", 38, true)
	retry_btn.pressed.connect(_start_game)
	gv.add_child(retry_btn)
	menu_btn = _make_button("MENU", 34)
	menu_btn.pressed.connect(_go_to_menu)
	gv.add_child(menu_btn)

	# Pre-render the pip icons once.
	_heart_full = _make_heart_icon(48, Color(0.95, 0.27, 0.34), Color(1.0, 0.6, 0.64))
	_heart_empty = _make_heart_icon(48, Color(0.24, 0.26, 0.32), Color(0.32, 0.34, 0.40))
	_heart_gold = _make_heart_icon(48, Color(1.0, 0.82, 0.30), Color(1.0, 0.93, 0.6))
	_shield_full = _make_shield_icon(48, true)
	_shield_empty = _make_shield_icon(48, false)

	# Lives: a Zelda-style row of 5 hearts, top-left (menu & game-over). Tappable to
	# open the lives menu (refill via ad / buy Unlimited Lives).
	lives_hud = HBoxContainer.new()
	lives_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	lives_hud.position = Vector2(28, 40)
	lives_hud.add_theme_constant_override("separation", 4)
	lives_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lives_hud.gui_input.connect(_on_lives_hud_input)
	ui.add_child(lives_hud)
	for i in Profile.MAX_LIVES:
		var pip := TextureRect.new()
		pip.texture = _heart_full
		pip.custom_minimum_size = Vector2(48, 48)
		pip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lives_hud.add_child(pip)
		_life_pips.append(pip)

	# Shields: a second row of pips, just below the hearts.
	shield_hud = HBoxContainer.new()
	shield_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	shield_hud.position = Vector2(28, 96)
	shield_hud.add_theme_constant_override("separation", 4)
	shield_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(shield_hud)
	for i in Profile.MAX_SHIELDS:
		var pip := TextureRect.new()
		pip.texture = _shield_empty
		pip.custom_minimum_size = Vector2(48, 48)
		pip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		shield_hud.add_child(pip)
		_shield_pips.append(pip)

	_build_shop()
	_build_outoflives()
	_build_item_modal()

# Out-of-lives gate: shown when the player has 0 lives. They can watch a rewarded
# ad for more lives, buy Unlimited Lives, or wait for the daily refill. Never forced.
func _build_outoflives() -> void:
	outoflives_root = _make_screen()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.10, 0.96)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	outoflives_root.add_child(bg)
	ui.add_child(outoflives_root)

	var v := _make_vbox(outoflives_root)
	oot_title_label = _make_label("OUT OF LIVES", 64)
	v.add_child(oot_title_label)
	oot_timer_label = _make_label("", 32)
	oot_timer_label.add_theme_color_override("font_color", Color(0.7, 0.74, 0.85))
	v.add_child(oot_timer_label)
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 40)
	v.add_child(sp)
	oot_watch_btn = _make_button("WATCH AD    +%d  LIVES" % Profile.LIVES_PER_AD, 36, true)
	oot_watch_btn.pressed.connect(_on_watch_ad_lives)
	v.add_child(oot_watch_btn)
	var back := _make_button("MENU", 30)
	back.pressed.connect(_go_to_menu)
	v.add_child(back)

# One reusable item-detail modal: icon, title, description, price/status line,
# a primary action button, and Back. Populated per-item by _open_item_modal().
func _build_item_modal() -> void:
	modal_root = Control.new()
	modal_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal_root.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	modal_root.add_child(dim)
	ui.add_child(modal_root)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	modal_root.add_child(center)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style(false))
	card.custom_minimum_size = Vector2(600, 0)
	center.add_child(card)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 34)
	m.add_theme_constant_override("margin_top", 34)
	m.add_theme_constant_override("margin_right", 34)
	m.add_theme_constant_override("margin_bottom", 34)
	card.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	m.add_child(v)
	_modal_icon = TextureRect.new()
	_modal_icon.custom_minimum_size = Vector2(120, 120)
	_modal_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_modal_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(_modal_icon)
	_modal_title = _make_label("", 44)
	v.add_child(_modal_title)
	_modal_desc = _make_label("", 28)
	_modal_desc.add_theme_color_override("font_color", Color(0.72, 0.76, 0.88))
	_modal_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_modal_desc)
	_modal_info = _make_label("", 26)
	_modal_info.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	v.add_child(_modal_info)
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 8)
	v.add_child(sp)
	_modal_action_btn = _make_button("", 34, true)
	_modal_action_btn.pressed.connect(_modal_do_action)
	v.add_child(_modal_action_btn)
	var back := _make_button("BACK", 30)
	back.pressed.connect(_close_item_modal)
	v.add_child(back)

	modal_root.visible = false

# Populate + show the modal. action_label == "" hides the action button.
func _open_item_modal(icon: Texture2D, title: String, desc: String, info: String,
		action_label: String, action: Callable, action_enabled: bool) -> void:
	_modal_icon.texture = icon
	_modal_title.text = title
	_modal_desc.text = desc
	_modal_desc.visible = desc != ""
	_modal_info.text = info
	_modal_info.visible = info != ""
	if action_label == "":
		_modal_action_btn.visible = false
		_modal_action = Callable()
	else:
		_modal_action_btn.visible = true
		_modal_action_btn.text = action_label
		_modal_action_btn.disabled = not action_enabled
		_modal_action = action
	modal_root.visible = true

func _close_item_modal() -> void:
	modal_root.visible = false

func _modal_do_action() -> void:
	_close_item_modal()
	if _modal_action.is_valid():
		_modal_action.call()

func _build_shop() -> void:
	shop_root = _make_screen()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.10, 0.97)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	shop_root.add_child(bg)
	ui.add_child(shop_root)

	# Outer padding around the whole shop.
	var outer := MarginContainer.new()
	outer.set_anchors_preset(Control.PRESET_FULL_RECT)
	outer.add_theme_constant_override("margin_left", 28)
	outer.add_theme_constant_override("margin_right", 28)
	outer.add_theme_constant_override("margin_top", 64)
	outer.add_theme_constant_override("margin_bottom", 40)
	shop_root.add_child(outer)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	outer.add_child(col)

	# Header: title (left) + coin balance pill (right).
	var header := HBoxContainer.new()
	var title := _make_label("Shop", 54)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.add_child(title)
	var hsp := Control.new()
	hsp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(hsp)
	var coin_pill := HBoxContainer.new()
	coin_pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	coin_pill.add_theme_constant_override("separation", 8)
	var ci := TextureRect.new()
	ci.texture = _make_coin_icon(48)
	ci.custom_minimum_size = Vector2(48, 48)
	ci.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin_pill.add_child(ci)
	shop_coin_label = _make_label("0", 42)
	shop_coin_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	coin_pill.add_child(shop_coin_label)
	header.add_child(coin_pill)
	col.add_child(header)

	# Connected tab strip sitting flush on top of the body panel (no gaps).
	var tab_group := VBoxContainer.new()
	tab_group.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab_group.add_theme_constant_override("separation", 0)
	col.add_child(tab_group)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	tab_group.add_child(tabs)
	skins_tab_btn = _make_tab_button("SKINS", "skins")
	tabs.add_child(skins_tab_btn)
	effects_tab_btn = _make_tab_button("EFFECTS", "effects")
	tabs.add_child(effects_tab_btn)
	items_tab_btn = _make_tab_button("ITEMS", "items")
	tabs.add_child(items_tab_btn)

	# Body panel: a fixed "Earn Coins" card at the top + the scrollable list below.
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _shop_panel_style())
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.clip_contents = true
	tab_group.add_child(panel)
	var panel_v := VBoxContainer.new()
	panel_v.add_theme_constant_override("separation", 0)
	panel.add_child(panel_v)

	# Sticky "Earn Coins" card -- always at the top of the list, never scrolls.
	var top_pad := MarginContainer.new()
	top_pad.add_theme_constant_override("margin_left", 16)
	top_pad.add_theme_constant_override("margin_top", 14)
	top_pad.add_theme_constant_override("margin_right", 16)
	top_pad.add_theme_constant_override("margin_bottom", 10)
	panel_v.add_child(top_pad)
	top_pad.add_child(_coins_card())

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Slim scrollbar, shown only when the list actually overflows; drag/touch
	# scrolling works too.
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel_v.add_child(scroll)
	_style_thin_scrollbar(scroll)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE  # let card input reach the scroll
	pad.add_theme_constant_override("margin_left", 16)
	pad.add_theme_constant_override("margin_top", 0)
	pad.add_theme_constant_override("margin_right", 16)
	pad.add_theme_constant_override("margin_bottom", 30)
	scroll.add_child(pad)
	_content_list = VBoxContainer.new()
	_content_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content_list.add_theme_constant_override("separation", 10)
	pad.add_child(_content_list)

	var back := _make_button("Back", 32)
	back.size_flags_horizontal = Control.SIZE_FILL
	back.custom_minimum_size = Vector2(0, 86)
	back.pressed.connect(_close_shop)
	col.add_child(back)

# A segmented tab button; active state styled via _apply_tab_style.
func _make_tab_button(text: String, tab_id: String) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 30)
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 86)
	b.pressed.connect(_show_shop_tab.bind(tab_id))
	return b

func _apply_tab_style(b: Button, active: bool) -> void:
	# Connected "folder tab" look: rounded TOP corners only; the active tab shares
	# the panel's fill (so it merges into it) and gets an accent top edge.
	var s := StyleBoxFlat.new()
	s.corner_radius_top_left = 12
	s.corner_radius_top_right = 12
	s.set_content_margin_all(12)
	s.border_width_left = 1
	s.border_width_right = 1
	if active:
		s.bg_color = Color(0.08, 0.09, 0.15, 0.98)   # == panel fill -> connected
		s.border_color = Color(0.55, 0.61, 1.0)
		s.border_width_top = 4                         # accent top edge
	else:
		s.bg_color = Color(0.05, 0.06, 0.11, 0.98)
		s.border_color = Color(0.20, 0.23, 0.34)
		s.border_width_top = 1
	b.add_theme_stylebox_override("normal", s)
	b.add_theme_stylebox_override("hover", s)
	b.add_theme_stylebox_override("pressed", s)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var fc := Color(1, 1, 1) if active else Color(0.62, 0.67, 0.82)
	b.add_theme_color_override("font_color", fc)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", fc)

# Make a ScrollContainer's vertical bar very thin (an 8px rounded pill).
func _style_thin_scrollbar(sc: ScrollContainer) -> void:
	var vsb := sc.get_v_scroll_bar()
	if vsb == null:
		return
	vsb.custom_minimum_size = Vector2(8, 0)
	vsb.add_theme_stylebox_override("scroll", StyleBoxEmpty.new())
	vsb.add_theme_stylebox_override("scroll_focus", StyleBoxEmpty.new())
	var grab := StyleBoxFlat.new()
	grab.bg_color = Color(0.42, 0.46, 0.60, 0.85)
	grab.set_corner_radius_all(4)
	vsb.add_theme_stylebox_override("grabber", grab)
	var grab_hi := grab.duplicate()
	grab_hi.bg_color = Color(0.56, 0.61, 0.80, 0.95)
	vsb.add_theme_stylebox_override("grabber_highlight", grab_hi)
	vsb.add_theme_stylebox_override("grabber_pressed", grab_hi)

func _shop_panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.08, 0.09, 0.15, 0.98)
	s.border_color = Color(0.24, 0.27, 0.40)
	# Square top (the tab strip connects flush); rounded bottom.
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_bottom = 1
	s.border_width_top = 0
	s.corner_radius_bottom_left = 16
	s.corner_radius_bottom_right = 16
	return s

func _card_style(highlight: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	if highlight:
		s.bg_color = Color(0.19, 0.22, 0.38, 0.99)
		s.border_color = Color(0.55, 0.61, 1.0)
	else:
		s.bg_color = Color(0.12, 0.13, 0.20, 0.98)
		s.border_color = Color(0.26, 0.30, 0.44)
	s.set_border_width_all(1)
	s.set_corner_radius_all(14)
	return s

# A flat list-item card: preview icon + title/subtitle + right action button.
# A tappable list row: icon + title + sub + a chevron. The whole card opens the
# item-detail modal via on_tap (no inline action button).
func _list_card(icon: Texture2D, title: String, sub: Control, on_tap: Callable, highlight: bool) -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style(highlight))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 14)
	m.add_theme_constant_override("margin_top", 14)
	m.add_theme_constant_override("margin_right", 14)
	m.add_theme_constant_override("margin_bottom", 14)
	card.add_child(m)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(row)
	var pic := TextureRect.new()
	pic.texture = icon
	pic.custom_minimum_size = Vector2(84, 84)
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(pic)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info.add_theme_constant_override("separation", 4)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(info)
	var tl := Label.new()
	tl.text = title
	tl.add_theme_font_size_override("font_size", 30)
	tl.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	tl.clip_text = true  # so a long name can't force the whole column wider
	info.add_child(tl)
	if sub:
		info.add_child(sub)
	var chev := Label.new()
	chev.text = ">"
	chev.add_theme_font_size_override("font_size", 38)
	chev.add_theme_color_override("font_color", Color(0.45, 0.5, 0.62))
	chev.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chev.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(chev)
	# Whole card is tappable, but we do NOT use a Button (that would eat drags and
	# block list scrolling). Instead the card passes input through (MOUSE_FILTER_PASS)
	# so the ScrollContainer can scroll, and we detect a "tap" vs a "drag" ourselves.
	if on_tap.is_valid():
		card.mouse_filter = Control.MOUSE_FILTER_PASS
		card.gui_input.connect(_on_card_input.bind(on_tap))
	return card

# Distinguish a tap (open the item) from a drag (let the list scroll).
func _on_card_input(event: InputEvent, on_tap: Callable) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_card_press_pos = event.position
			_card_moved = false
		elif not _card_moved:
			on_tap.call()
	elif event is InputEventScreenDrag:
		if event.position.distance_to(_card_press_pos) > 12.0:
			_card_moved = true
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_card_press_pos = event.position
			_card_moved = false
		elif not _card_moved:
			on_tap.call()
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		if event.position.distance_to(_card_press_pos) > 12.0:
			_card_moved = true

func _sub_label(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 22)
	l.add_theme_color_override("font_color", color)
	l.clip_text = true
	return l

# Coin icon + price (+ optional muted note), as a card subtitle.
func _price_sub(price: int, note: String) -> Control:
	var h := HBoxContainer.new()
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_theme_constant_override("separation", 6)
	var ci := TextureRect.new()
	ci.texture = _make_coin_icon(30)
	ci.custom_minimum_size = Vector2(30, 30)
	ci.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ci.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(ci)
	var pl := Label.new()
	pl.text = str(price)
	pl.add_theme_font_size_override("font_size", 24)
	pl.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	h.add_child(pl)
	if note != "":
		var nl := Label.new()
		nl.text = "   " + note
		nl.add_theme_font_size_override("font_size", 20)
		nl.add_theme_color_override("font_color", Color(0.6, 0.65, 0.78))
		nl.clip_text = true
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(nl)
	return h

# A compact card action button.
func _card_action(text: String, primary: bool, disabled: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 24)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(160, 74)
	_apply_button_style(b, primary)
	b.disabled = disabled
	return b

func _show_shop_tab(which: String) -> void:
	_shop_tab = which
	_apply_tab_style(skins_tab_btn, which == "skins")
	_apply_tab_style(effects_tab_btn, which == "effects")
	_apply_tab_style(items_tab_btn, which == "items")
	_rebuild_shop_content()

# Rebuild the list for the active tab (cheap; ~6-10 cards).
func _rebuild_shop_content() -> void:
	for c in _content_list.get_children():
		_content_list.remove_child(c)
		c.queue_free()
	if _shop_tab == "skins":
		_content_list.add_child(_roll_card())  # "Surprise Orb" lives with the skins
		for s in Skins.CATALOG:
			_content_list.add_child(_skin_card(s["id"]))
		for id in Profile.owned.keys():
			if Skins.is_random(id):
				_content_list.add_child(_skin_card(id))
	elif _shop_tab == "effects":
		for e in Skins.EFFECTS:
			_content_list.add_child(_effect_card(e["id"]))
	else:
		_content_list.add_child(_shield_card())
		_content_list.add_child(_magnet_card())

# Short status/price line for a list card (full detail lives in the modal).
func _status_sub(owned: bool, equipped: bool, price: int) -> Control:
	if equipped:
		return _sub_label("Equipped", Color(0.6, 0.9, 0.66))
	if owned:
		return _sub_label("Owned", Color(0.7, 0.78, 0.92))
	return _price_sub(price, "")

func _effect_card(id: String) -> PanelContainer:
	var e := Skins.get_effect(id)
	var equipped: bool = Profile.equipped_effect == id
	return _list_card(_make_effect_icon(id), str(e["name"]),
		_status_sub(Profile.is_effect_owned(id), equipped, int(e["price"])),
		_open_effect_modal.bind(id), equipped)

func _open_effect_modal(id: String) -> void:
	var e := Skins.get_effect(id)
	var price := int(e["price"])
	var equipped: bool = Profile.equipped_effect == id
	var info := "Equipped"
	var label := ""
	var enabled := false
	if not equipped:
		if Profile.is_effect_owned(id):
			info = "Owned"
			label = "EQUIP"
			enabled = true
		else:
			info = "%d coins" % price
			label = "BUY"
			enabled = Profile.can_afford(price)
	_open_item_modal(_make_effect_icon(id, 120), str(e["name"]), _effect_desc(id), info,
		label, _on_effect_pressed.bind(id), enabled)

func _effect_desc(id: String) -> String:
	match id:
		"fire": return "Flames trail your orb as it rolls."
		"electric": return "Crackling sparks orbit your orb."
		"smoke": return "A smoky plume drifts off your orb."
		"sparkle": return "Golden sparkles shimmer around your orb."
		_: return "No particle effect."

func _on_effect_pressed(id: String) -> void:
	if Profile.is_effect_owned(id):
		Profile.equip_effect(id)
	elif Profile.buy_effect(id):
		Profile.equip_effect(id)
	else:
		return  # couldn't afford
	player.apply_effect(Profile.equipped_effect)
	_refresh_shop()

func _skin_card(id: String) -> PanelContainer:
	var s := Skins.get_skin(id)
	var equipped: bool = Profile.equipped == id
	return _list_card(Skins.preview_texture(id, 96), str(s["name"]),
		_status_sub(Profile.is_owned(id), equipped, int(s["price"])),
		_open_skin_modal.bind(id), equipped)

func _open_skin_modal(id: String) -> void:
	var s := Skins.get_skin(id)
	var price := int(s["price"])
	var equipped: bool = Profile.equipped == id
	var desc := "A one-of-a-kind procedurally-generated orb." if Skins.is_random(id) else "A cosmetic skin for your orb."
	var info := "Equipped"
	var label := ""
	var enabled := false
	if not equipped:
		if Profile.is_owned(id):
			info = "Owned"
			label = "EQUIP"
			enabled = true
		else:
			info = "%d coins" % price
			label = "BUY"
			enabled = Profile.can_afford(price)
	_open_item_modal(Skins.preview_texture(id, 120), str(s["name"]), desc, info,
		label, _on_skin_pressed.bind(id), enabled)

func _coins_card() -> PanelContainer:
	return _list_card(_make_coin_icon(96), "Earn Coins", null, _open_coins_modal, true)

func _open_coins_modal() -> void:
	_open_item_modal(_make_coin_icon(120), "Earn Coins",
		"Watch a short ad to earn +%d coins." % AD_COINS_REWARD, "",
		"WATCH AD", _on_watch_ad_coins, true)

func _shield_card() -> PanelContainer:
	return _list_card(_make_shield_icon(96), "Shield",
		_price_sub(Profile.SHIELD_PRICE, "owned %d/%d" % [Profile.shields, Profile.MAX_SHIELDS]),
		_open_shield_modal, false)

func _open_shield_modal() -> void:
	var enabled := Profile.shields < Profile.MAX_SHIELDS and Profile.can_afford(Profile.SHIELD_PRICE)
	_open_item_modal(_make_shield_icon(120), "Shield",
		"Absorbs one wall hit instead of ending your run. Carry up to %d into a run." % Profile.MAX_SHIELDS,
		"%d coins   ·   owned %d/%d" % [Profile.SHIELD_PRICE, Profile.shields, Profile.MAX_SHIELDS],
		"BUY", _on_buy_shield, enabled)

func _magnet_card() -> PanelContainer:
	return _list_card(_make_magnet_icon(96), "Coin Magnet",
		_price_sub(Profile.MAGNET_PRICE, "owned %d/%d" % [Profile.magnets, Profile.MAX_MAGNETS]),
		_open_magnet_modal, false)

func _open_magnet_modal() -> void:
	var enabled := Profile.magnets < Profile.MAX_MAGNETS and Profile.can_afford(Profile.MAGNET_PRICE)
	_open_item_modal(_make_magnet_icon(120), "Coin Magnet",
		"For one run, coins fly to your orb so you sweep the whole field. Worth more the higher you score.",
		"%d coins   ·   owned %d/%d" % [Profile.MAGNET_PRICE, Profile.magnets, Profile.MAX_MAGNETS],
		"BUY", _on_buy_magnet, enabled)

func _roll_card() -> PanelContainer:
	return _list_card(Skins.preview_texture("neon", 96), "Surprise Orb",
		_price_sub(Profile.RANDOM_SKIN_PRICE, "random orb"), _open_roll_modal, false)

func _open_roll_modal() -> void:
	_open_item_modal(Skins.preview_texture("neon", 120), "Surprise Orb",
		"Unlock a brand-new, one-of-a-kind procedurally-generated orb skin.",
		"%d coins" % Profile.RANDOM_SKIN_PRICE,
		"ROLL", _on_roll_skin, Profile.can_afford(Profile.RANDOM_SKIN_PRICE))

func _make_label(txt: String, size: int) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", size)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	return l

func _make_button(txt: String, size: int, primary: bool = false) -> Button:
	var b := Button.new()
	b.text = txt
	b.add_theme_font_size_override("font_size", size)
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.custom_minimum_size = Vector2(380, 96)
	_apply_button_style(b, primary)
	return b

func _btn_style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(20)
	s.set_border_width_all(2)
	s.border_color = border
	s.set_content_margin_all(16)
	s.shadow_color = Color(0, 0, 0, 0.35)
	s.shadow_size = 6
	s.shadow_offset = Vector2(0, 4)
	return s

# Pill-style button skin. `primary` gets the bright accent fill for main CTAs.
func _apply_button_style(b: Button, primary: bool) -> void:
	var base: Color
	var border: Color
	var hover: Color
	var pressed: Color
	var txt: Color
	if primary:
		base = Color(0.36, 0.42, 0.95)
		border = Color(0.66, 0.72, 1.0)
		hover = Color(0.46, 0.52, 1.0)
		pressed = Color(0.28, 0.33, 0.82)
		txt = Color(1, 1, 1)
	else:
		base = Color(0.16, 0.18, 0.27, 0.96)
		border = Color(0.42, 0.47, 0.62, 0.7)
		hover = Color(0.23, 0.26, 0.38, 0.98)
		pressed = Color(0.12, 0.14, 0.21)
		txt = Color(0.93, 0.95, 1.0)
	b.add_theme_stylebox_override("normal", _btn_style(base, border))
	b.add_theme_stylebox_override("hover", _btn_style(hover, border))
	b.add_theme_stylebox_override("pressed", _btn_style(pressed, border))
	b.add_theme_stylebox_override("focus", _btn_style(base, border))
	b.add_theme_stylebox_override("disabled",
		_btn_style(Color(0.12, 0.13, 0.18, 0.65), Color(0.25, 0.27, 0.34, 0.4)))
	b.add_theme_color_override("font_color", txt)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", txt)
	b.add_theme_color_override("font_disabled_color", Color(0.5, 0.53, 0.62))

# Procedural gold coin icon for the HUD counter.
func _make_coin_icon(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r := size * 0.5
	var rim := Color(0.82, 0.58, 0.1)
	var face := Color(1.0, 0.85, 0.32)
	var face_dk := Color(0.88, 0.66, 0.14)
	var shine := Color(1.0, 0.97, 0.78)
	for y in size:
		for x in size:
			var dx := (x + 0.5) - r
			var dy := (y + 0.5) - r
			var d := sqrt(dx * dx + dy * dy)
			if d > r:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var c: Color
			if d > r * 0.80:
				c = rim
			else:
				c = face.lerp(face_dk, clampf(d / (r * 0.80), 0.0, 1.0) * 0.7)
				# inner ring detail
				if d > r * 0.52 and d < r * 0.60:
					c = c.darkened(0.12)
				# top-left highlight
				var hl := Vector2(dx, dy).distance_to(Vector2(-r * 0.28, -r * 0.30))
				if hl < r * 0.26:
					c = c.lerp(shine, 0.55 * (1.0 - hl / (r * 0.26)))
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

# Procedural red heart icon for the lives counter (implicit heart curve).
func _make_heart_icon(size: int, fill: Color, shine: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for py in size:
		for px in size:
			var x := (px + 0.5) / float(size) * 2.8 - 1.4
			var y := 1.15 - (py + 0.5) / float(size) * 2.7
			var v := pow(x * x + y * y - 1.0, 3.0) - x * x * pow(y, 3.0)
			if v <= 0.0:
				# Soft top-left highlight for a little depth.
				var hl := Vector2(x, y).distance_to(Vector2(-0.35, 0.45))
				img.set_pixel(px, py, fill.lerp(shine, clampf(1.0 - hl / 0.7, 0.0, 1.0) * 0.6))
			else:
				img.set_pixel(px, py, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)

# Procedural kite/heater shield icon: flat rounded top, sides tapering to a point.
func _make_shield_icon(size: int, filled: bool = true) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var steel := Color(0.58, 0.66, 0.85) if filled else Color(0.25, 0.27, 0.33)
	var steel_dk := Color(0.34, 0.40, 0.58) if filled else Color(0.16, 0.17, 0.22)
	var edge := Color(0.18, 0.22, 0.34) if filled else Color(0.11, 0.12, 0.16)
	var ridge := Color(0.82, 0.88, 0.98) if filled else Color(0.34, 0.36, 0.42)
	var cx := size * 0.5
	var top := size * 0.07
	var bot := size * 0.96
	var half := size * 0.40  # half width at the top
	for py in size:
		for px in size:
			var ty := (py - top) / (bot - top)  # 0 = top, 1 = bottom point
			if ty < 0.0 or ty > 1.0:
				img.set_pixel(px, py, Color(0, 0, 0, 0))
				continue
			# Width: full across the top third, then curve smoothly to a point.
			var hw := half
			if ty > 0.34:
				hw = half * cos((ty - 0.34) / 0.66 * (PI * 0.5))
			# Round the two top corners a touch.
			if ty < 0.12:
				hw = minf(hw, half - (0.12 - ty) / 0.12 * (size * 0.10))
			var dx := absf(px - cx)
			if dx <= hw and hw > 0.0:
				var c: Color
				var t := dx / maxf(hw, 0.001)
				if dx > hw - size * 0.055 or ty > 0.965 or ty < 0.03:
					c = edge  # border
				elif dx < size * 0.045:
					c = ridge.lerp(steel, 0.35)  # center ridge highlight
				else:
					c = steel.lerp(steel_dk, t * 0.55)
				img.set_pixel(px, py, c)
			else:
				img.set_pixel(px, py, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)

# Shop preview for a particle effect: a dark orb wrapped in the effect's coloured
# glow (+ a few sparks). "" (None) is just a faint grey ring.
func _make_effect_icon(id: String, size: int = 96) -> ImageTexture:
	var col := Color(0.45, 0.47, 0.55)
	match id:
		"fire": col = Color(1.0, 0.5, 0.15)
		"electric": col = Color(0.5, 0.85, 1.0)
		"smoke": col = Color(0.62, 0.62, 0.68)
		"sparkle": col = Color(1.0, 0.88, 0.4)
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := size * 0.5
	var ballc := Color(0.16, 0.17, 0.23)
	for y in size:
		for x in size:
			var d := Vector2(x - c + 0.5, y - c + 0.5).length() / (size * 0.5)
			if d > 1.0:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			elif d < 0.42:
				img.set_pixel(x, y, ballc)
			else:
				var a := clampf(1.0 - (d - 0.42) / 0.58, 0.0, 1.0)
				img.set_pixel(x, y, Color(col.r, col.g, col.b, a * a))
	if id != "":
		for sp in [Vector2(0.72, 0.26), Vector2(0.3, 0.74), Vector2(0.8, 0.68), Vector2(0.26, 0.32)]:
			var px := int(sp.x * size)
			var py := int(sp.y * size)
			for oy in range(-2, 3):
				for ox in range(-2, 3):
					var qx := px + ox
					var qy := py + oy
					var dd := Vector2(ox, oy).length()
					if qx >= 0 and qx < size and qy >= 0 and qy < size and dd <= 2.2:
						img.set_pixel(qx, qy, Color(1, 1, 1, clampf(1.0 - dd / 2.2, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)

# Procedural horseshoe-magnet icon: red U-body, grey poles, open at the top.
func _make_magnet_icon(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := size * 0.5
	var ro := size * 0.42
	var ri := size * 0.24
	var red := Color(0.86, 0.18, 0.18)
	var red_dk := Color(0.6, 0.1, 0.12)
	var pole := Color(0.80, 0.84, 0.90)
	var open := 0.62       # half-angle of the top opening
	var pole_band := 0.5   # angular band at the tips that reads as the metal pole
	for y in size:
		for x in size:
			var dx := (x + 0.5) - c
			var dy := (y + 0.5) - c
			var r := sqrt(dx * dx + dy * dy)
			var aabs := absf(atan2(dx, -dy))  # 0 at top, PI at bottom
			if r >= ri and r <= ro and aabs > open:
				var col: Color
				if aabs < open + pole_band:
					col = pole
				else:
					var t := (r - ri) / (ro - ri)
					col = red.lerp(red_dk, absf(t - 0.5) * 1.2)
				img.set_pixel(x, y, col)
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)

func _make_screen() -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

func _make_vbox(parent: Control) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 16)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(v)
	return v

# --------------------------------------------------------------- State machine

func _set_state(s: int) -> void:
	state = s
	menu_root.visible = (s == State.MENU)
	gameover_root.visible = (s == State.GAMEOVER)
	shop_root.visible = (s == State.SHOP)
	outoflives_root.visible = (s == State.OUTOFLIVES)
	score_label.visible = (s == State.PLAYING)
	# Coin counter + equipped-ball preview show everywhere except overlays
	# (shop / out-of-lives gate, which have their own backdrops).
	if modal_root:
		modal_root.visible = false
	var overlay := s == State.SHOP or s == State.OUTOFLIVES
	coin_hud.visible = not overlay
	# Hearts + shields show together everywhere except the shop / out-of-lives overlays.
	lives_hud.visible = not overlay
	# Hearts are tappable (open the lives menu) only on menu / game-over.
	lives_hud.mouse_filter = Control.MOUSE_FILTER_STOP if (s == State.MENU or s == State.GAMEOVER) else Control.MOUSE_FILTER_IGNORE
	shield_hud.visible = not overlay
	coin_label.text = str(Profile.coins)
	_refresh_lives()
	_refresh_shield_hud()

# Lives = a row of hearts. Filled red for current lives, greyed for the rest;
# Unlimited Lives shows all five as gold.
func _refresh_lives() -> void:
	var unlimited := Ads.has_unlimited_lives()
	for i in _life_pips.size():
		if unlimited:
			_life_pips[i].texture = _heart_gold
		elif i < Profile.lives:
			_life_pips[i].texture = _heart_full
		else:
			_life_pips[i].texture = _heart_empty

# Shields = a row of shield pips (filled for carried, greyed for the rest).
func _refresh_shield_hud() -> void:
	for i in _shield_pips.size():
		_shield_pips[i].texture = _shield_full if i < Profile.shields else _shield_empty

# Entry point for RETRY / tap-to-start. Gated by lives: if the player is out
# (and hasn't bought Unlimited Lives), show the out-of-lives gate instead of starting.
func _start_game() -> void:
	Profile.refill_if_new_day()
	if not Ads.has_unlimited_lives() and not Profile.has_lives():
		_show_outoflives()
		return
	_begin_run()

func _on_lives_hud_input(event: InputEvent) -> void:
	if state != State.MENU and state != State.GAMEOVER:
		return
	if Ads.has_unlimited_lives():
		return  # nothing to refill/buy
	var released := false
	if event is InputEventScreenTouch and not event.pressed:
		released = true
	elif event is InputEventMouseButton and not event.pressed:
		released = true
	if released:
		_show_outoflives()

func _show_outoflives() -> void:
	# Doubles as the "lives menu" (tap the hearts): title reflects current lives.
	if Profile.has_lives():
		oot_title_label.text = "LIVES   %d / %d" % [Profile.lives, Profile.MAX_LIVES]
	else:
		oot_title_label.text = "OUT OF LIVES"
	oot_watch_btn.visible = Ads.is_rewarded_ready()
	var s := Profile.seconds_until_refill()
	oot_timer_label.text = "Free lives in %dh %dm" % [s / 3600, (s % 3600) / 60]
	_set_state(State.OUTOFLIVES)

func _begin_run() -> void:
	_clear_field()
	score = 0
	score_label.text = "0"
	_run_coins = 0
	coin_label.text = str(Profile.coins)
	player.reset()
	shake = 0.0
	_reward_action = ""
	_magnet_active = Profile.use_magnet()  # spend one magnet if the player has any
	_set_state(State.PLAYING)

func _clear_field() -> void:
	for w in walls:
		if is_instance_valid(w):
			w.queue_free()
	walls.clear()
	for c in coins:
		if is_instance_valid(c):
			c.queue_free()
	coins.clear()
	_newest_wall = null

func _game_over() -> void:
	shake = 0.5
	_freeze_field()
	if hit_sfx and hit_sfx.stream:
		hit_sfx.play()
	if score > best:
		best = score
		_save_best()
	final_label.text = "Score: %d" % score
	best_label.text = "Best: %d" % best
	coins_gained_label.text = "+%d coins" % _run_coins if _run_coins > 0 else ""
	# Each death costs a life (unless the player owns Unlimited Lives).
	if not Ads.has_unlimited_lives():
		Profile.lose_life()
	Profile.save()
	_set_state(State.GAMEOVER)

# Halt all world motion on death so the scene freezes behind the game-over UI.
func _freeze_field() -> void:
	for w in walls:
		if is_instance_valid(w):
			w.set_physics_process(false)
	for c in coins:
		if is_instance_valid(c):
			c.set_physics_process(false)

func _go_to_menu() -> void:
	Profile.refill_if_new_day()
	_clear_field()
	score = 0
	player.reset()
	shake = 0.0
	_set_state(State.MENU)

# ------------------------------------------------------------------ Ads / IAP

# Out-of-lives gate: watch a rewarded ad for +LIVES_PER_AD lives, then play on.
func _on_watch_ad_lives() -> void:
	if not Ads.is_rewarded_ready():
		return
	_reward_action = "lives"
	Ads.show_rewarded()

# Shop: watch a rewarded ad for free coins.
func _on_watch_ad_coins() -> void:
	if not Ads.is_rewarded_ready():
		return
	_reward_action = "coins"
	Ads.show_rewarded()

# Out-of-lives gate: buy the one-time Unlimited Lives entitlement.
func _on_buy_unlimited() -> void:
	Ads.purchase_remove_ads()

func _on_rewarded_completed(granted: bool) -> void:
	var action := _reward_action
	_reward_action = ""
	if not granted:
		return
	match action:
		"lives":
			Profile.add_lives(Profile.LIVES_PER_AD)
			_begin_run()  # they watched an ad specifically to keep playing
		"coins":
			Profile.add_coins(AD_COINS_REWARD)
			Profile.save()
			coin_label.text = str(Profile.coins)
			_refresh_shop()

func _on_ads_removed_changed(_removed: bool) -> void:
	# Unlimited Lives purchased: drop the gate. If we're sitting on it, play on.
	_refresh_lives()
	if state == State.OUTOFLIVES:
		_begin_run()

# --------------------------------------------------------------------- Shop

func _open_shop() -> void:
	_show_shop_tab("skins")
	shop_coin_label.text = str(Profile.coins)
	_set_state(State.SHOP)

func _close_shop() -> void:
	_set_state(State.MENU)

func _on_skin_pressed(id: String) -> void:
	if Profile.is_owned(id):
		Profile.equip(id)
	elif Profile.buy(id):
		Profile.equip(id)
	# else: not enough coins -- leave as-is.
	player.apply_skin(Profile.equipped)
	_refresh_shop()

func _on_buy_shield() -> void:
	if Profile.buy_shield():
		_refresh_shop()

func _on_buy_magnet() -> void:
	if Profile.buy_magnet():
		_refresh_shop()

func _on_roll_skin() -> void:
	var id := Profile.roll_random_skin()
	if id == "":
		return
	player.apply_skin(Profile.equipped)
	_show_shop_tab("skins")  # switch to skins to show the freshly-rolled orb
	shop_coin_label.text = str(Profile.coins)

func _refresh_shop() -> void:
	shop_coin_label.text = str(Profile.coins)
	coin_label.text = str(Profile.coins)
	_rebuild_shop_content()

# -------------------------------------------------------------------- Gameplay

func _process(delta: float) -> void:
	# Camera shake (juice) runs in every state.
	if shake > 0.001:
		shake = maxf(0.0, shake - delta * 2.5)
		cam.position = cam_base_pos + Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * shake
	else:
		cam.position = cam_base_pos

	# Spin the ball forward continuously so it reads as rolling into the
	# field, even when the player isn't dragging.
	if state == State.PLAYING:
		player.roll_speed = _current_speed()
	elif state == State.MENU:
		# On the menu the ball rolls in its travel direction (no forced
		# forward spin) as it wanders around, so the motion looks natural.
		player.roll_speed = 0.0
		_animate_menu_ball(delta)
	else:
		# GAME OVER / SHOP: world is frozen, ball stops spinning.
		player.roll_speed = 0.0

	if state != State.PLAYING:
		return
	_maybe_spawn()

# Lazily drift the ball around the lower play area on the main menu.
func _animate_menu_ball(delta: float) -> void:
	_menu_t += delta
	player.position.x = sin(_menu_t * 1.05) * (ARENA_HALF - 0.6)
	player.position.z = 1.4 + sin(_menu_t * 2.3 + 0.7) * 1.7

func _maybe_spawn() -> void:
	if _newest_wall == null or not is_instance_valid(_newest_wall) \
			or _newest_wall.position.z >= SPAWN_Z + SPAWN_SPACING:
		_spawn_wall()

func _spawn_wall() -> void:
	var w := Wall.new()
	add_child(w)
	w.setup(_generate_holes(), _current_speed(), player, SPAWN_Z)
	w.crossed.connect(_on_wall_crossed)
	_newest_wall = w
	walls.append(w)
	# A field of coins ahead of this wall -- denser as you climb, so a Coin Magnet
	# (which sweeps the whole width) is worth more and more the higher you score.
	_spawn_coins(SPAWN_Z + SPAWN_SPACING * 0.5)

func _spawn_coins(z: float) -> void:
	var count := clampi(2 + score / 8, 2, 7)
	for i in count:
		var c := Coin.new()
		add_child(c)
		# Spread across the full width (hard to grab them all by hand -- that's
		# what the magnet is for), with a little jitter + depth stagger.
		var x := lerpf(-ARENA_HALF, ARENA_HALF, (i + 0.5) / float(count)) + randf_range(-0.4, 0.4)
		var cz := z + randf_range(-2.2, 2.2)
		c.setup(_current_speed(), player, cz, clampf(x, -ARENA_HALF, ARENA_HALF))
		c.magnet = _magnet_active
		c.collected.connect(_on_coin_collected)
		coins.append(c)

func _on_coin_collected() -> void:
	if state != State.PLAYING:
		return
	_run_coins += 1
	Profile.add_coins(1)
	coin_label.text = str(Profile.coins)
	if coin_sfx and coin_sfx.stream:
		coin_sfx.play()

func _on_wall_crossed(survived: bool) -> void:
	if state != State.PLAYING:
		return
	if survived:
		score += 1
		score_label.text = str(score)
		shake = maxf(shake, 0.12)
		if score % MILESTONE_EVERY == 0:
			shake = maxf(shake, 0.3)
			if milestone_sfx and milestone_sfx.stream:
				milestone_sfx.play()
	else:
		# A carried shield absorbs the hit instead of ending the run.
		if Profile.use_shield():
			shake = maxf(shake, 0.5)
			if milestone_sfx and milestone_sfx.stream:
				milestone_sfx.play()
			_refresh_shield_hud()
		else:
			_game_over()

func _current_speed() -> float:
	return minf(8.0 + score * 0.55, 28.0)

func _generate_holes() -> Array:
	var num := clampi(1 + score / 6, 1, 4)
	var min_r := maxf(0.7, 1.5 - score * 0.03)
	var max_r := maxf(min_r + 0.4, 2.2 - score * 0.05)

	var result: Array = []
	var attempts := 0
	while result.size() < num and attempts < 200:
		attempts += 1
		var r := randf_range(min_r, max_r)
		if result.is_empty():
			# Guarantee the first hole comfortably fits the sphere.
			r = maxf(r, Player.RADIUS + 0.6)
		var hx := randf_range(-ARENA_HALF, ARENA_HALF)
		var hy := Player.RADIUS + randf_range(0.0, 0.5)
		var ok := true
		for h in result:
			if absf(hx - float(h["x"])) < r + float(h["radius"]) + 0.4:
				ok = false
				break
		if ok:
			result.append({ "x": hx, "y": hy, "radius": r })
	return result

# ------------------------------------------------------------------- Save/load

func _load_best() -> int:
	if FileAccess.file_exists(SAVE_PATH):
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f:
			return f.get_32()
	return 0

func _save_best() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_32(best)

# ----------------------------------------------------------------------- Input

func _unhandled_input(event: InputEvent) -> void:
	match state:
		State.MENU:
			pass  # PLAY / SHOP buttons handle input
		State.GAMEOVER:
			pass  # explicit RETRY / MENU / REVIVE buttons handle input
		State.SHOP:
			pass  # shop buttons handle their own input
		State.OUTOFLIVES:
			pass  # gate buttons (watch ad / unlimited / menu) handle their own input
		State.PLAYING:
			if event is InputEventScreenDrag:
				player.move_by(event.relative.x * DRAG_SENS, event.relative.y * DRAG_SENS)
			elif event is InputEventMouseMotion \
					and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
				player.move_by(event.relative.x * DRAG_SENS, event.relative.y * DRAG_SENS)

func _is_tap(event: InputEvent) -> bool:
	if event is InputEventScreenTouch and event.pressed:
		return true
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		return true
	if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
		return true
	return false
