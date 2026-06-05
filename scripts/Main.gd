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
var hud_ball: TextureRect
var coins_gained_label: Label
var shop_root: Control
var shop_coin_label: Label
var _skin_buttons := {}
# Shop tabs (skins vs consumables) + item widgets
var shop_tab_skins_btn: Button
var shop_tab_items_btn: Button
var skins_view: VBoxContainer
var items_view: VBoxContainer
var shield_owned_label: Label
var shield_buy_btn: Button
var roll_btn: Button

# Lives + shields HUD
var lives_hud: HBoxContainer
var lives_count_label: Label
var shield_hud: HBoxContainer
var shield_count_label: Label

# Ads / IAP -- the out-of-lives gate (watch ad for lives, or buy Unlimited Lives)
var _reward_action := ""  # "lives" or "coins" -- what the next rewarded ad is for
var outoflives_root: Control
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
	_update_hud_ball()
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

	# Equipped-ball preview, top-left -- reflects the current skin live.
	hud_ball = TextureRect.new()
	hud_ball.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hud_ball.position = Vector2(26, 34)
	hud_ball.custom_minimum_size = Vector2(92, 92)
	hud_ball.size = Vector2(92, 92)
	hud_ball.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hud_ball.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(hud_ball)

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
	spacer.custom_minimum_size = Vector2(0, 60)
	mv.add_child(spacer)
	var hint := _make_label("Tap to Start", 48)
	mv.add_child(hint)
	var ctrl_hint := _make_label("drag to move  -  survive the walls", 30)
	mv.add_child(ctrl_hint)
	var msp := Control.new()
	msp.custom_minimum_size = Vector2(0, 40)
	mv.add_child(msp)
	var shop_btn := _make_button("SHOP", 36, true)
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

	# Persistent lives counter (heart + "n / max"), shown on menu & game-over.
	lives_hud = HBoxContainer.new()
	lives_hud.set_anchors_preset(Control.PRESET_TOP_WIDE)
	lives_hud.offset_top = 40
	lives_hud.offset_bottom = 108
	lives_hud.alignment = BoxContainer.ALIGNMENT_CENTER
	lives_hud.add_theme_constant_override("separation", 10)
	lives_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(lives_hud)
	var heart := TextureRect.new()
	heart.texture = _make_heart_icon(56)
	heart.custom_minimum_size = Vector2(56, 56)
	heart.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	heart.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lives_hud.add_child(heart)
	lives_count_label = _make_label("5 / 5", 44)
	lives_count_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.55))
	lives_hud.add_child(lives_count_label)

	# Shield counter (kite shield + "xN"), top-left during a run when you have any.
	shield_hud = HBoxContainer.new()
	shield_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	shield_hud.position = Vector2(30, 138)
	shield_hud.add_theme_constant_override("separation", 6)
	shield_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(shield_hud)
	var shield_icon := TextureRect.new()
	shield_icon.texture = _make_shield_icon(60)
	shield_icon.custom_minimum_size = Vector2(60, 60)
	shield_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	shield_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shield_hud.add_child(shield_icon)
	shield_count_label = _make_label("x0", 40)
	shield_count_label.add_theme_color_override("font_color", Color(0.78, 0.85, 1.0))
	shield_hud.add_child(shield_count_label)

	_build_shop()
	_build_outoflives()

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
	v.add_child(_make_label("OUT OF LIVES", 64))
	oot_timer_label = _make_label("", 32)
	oot_timer_label.add_theme_color_override("font_color", Color(0.7, 0.74, 0.85))
	v.add_child(oot_timer_label)
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 40)
	v.add_child(sp)
	oot_watch_btn = _make_button("WATCH AD    +%d  LIVES" % Profile.LIVES_PER_AD, 36, true)
	oot_watch_btn.pressed.connect(_on_watch_ad_lives)
	v.add_child(oot_watch_btn)
	var unl := _make_button("UNLIMITED LIVES", 32)
	unl.pressed.connect(_on_buy_unlimited)
	v.add_child(unl)
	var back := _make_button("MENU", 30)
	back.pressed.connect(_go_to_menu)
	v.add_child(back)

func _build_shop() -> void:
	shop_root = _make_screen()
	# Opaque-ish backdrop so the shop is readable and taps don't fall through.
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.11, 0.95)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	shop_root.add_child(bg)
	ui.add_child(shop_root)

	var v := _make_vbox(shop_root)
	v.add_child(_make_label("SHOP", 60))
	shop_coin_label = _make_label("Coins: 0", 38)
	shop_coin_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	v.add_child(shop_coin_label)
	# Free-coins rewarded-ad button (the coin faucet), always visible.
	ad_coins_btn = _make_button("WATCH AD   +%d  COINS" % AD_COINS_REWARD, 26, true)
	ad_coins_btn.custom_minimum_size = Vector2(420, 78)
	ad_coins_btn.pressed.connect(_on_watch_ad_coins)
	v.add_child(ad_coins_btn)

	# Tab row: SKINS / ITEMS.
	var tabs := HBoxContainer.new()
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	tabs.add_theme_constant_override("separation", 12)
	v.add_child(tabs)
	shop_tab_skins_btn = _make_button("SKINS", 28)
	shop_tab_skins_btn.custom_minimum_size = Vector2(210, 74)
	shop_tab_skins_btn.pressed.connect(_show_shop_tab.bind("skins"))
	tabs.add_child(shop_tab_skins_btn)
	shop_tab_items_btn = _make_button("ITEMS", 28)
	shop_tab_items_btn.custom_minimum_size = Vector2(210, 74)
	shop_tab_items_btn.pressed.connect(_show_shop_tab.bind("items"))
	tabs.add_child(shop_tab_items_btn)

	# Scrollable content area holding both views (only one visible at a time).
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(660, 620)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)

	skins_view = VBoxContainer.new()
	skins_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	skins_view.add_theme_constant_override("separation", 12)
	content.add_child(skins_view)

	items_view = VBoxContainer.new()
	items_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	items_view.add_theme_constant_override("separation", 18)
	content.add_child(items_view)
	_build_items_view()

	var back := _make_button("Back", 32)
	back.pressed.connect(_close_shop)
	v.add_child(back)

# The consumables tab: buy shields, roll a random "Surprise Orb" skin.
func _build_items_view() -> void:
	# --- Shield ---
	var srow := HBoxContainer.new()
	srow.alignment = BoxContainer.ALIGNMENT_CENTER
	srow.add_theme_constant_override("separation", 18)
	var sicon := TextureRect.new()
	sicon.texture = _make_shield_icon(96)
	sicon.custom_minimum_size = Vector2(96, 96)
	sicon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sicon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	srow.add_child(sicon)
	var scol := VBoxContainer.new()
	scol.add_theme_constant_override("separation", 6)
	shield_owned_label = _make_label("Shields  0 / %d" % Profile.MAX_SHIELDS, 30)
	scol.add_child(shield_owned_label)
	shield_buy_btn = _make_button("BUY   %d coins" % Profile.SHIELD_PRICE, 26)
	shield_buy_btn.custom_minimum_size = Vector2(320, 74)
	shield_buy_btn.pressed.connect(_on_buy_shield)
	scol.add_child(shield_buy_btn)
	srow.add_child(scol)
	items_view.add_child(srow)

	# --- Surprise Orb (random procedural skin) ---
	var rrow := HBoxContainer.new()
	rrow.alignment = BoxContainer.ALIGNMENT_CENTER
	rrow.add_theme_constant_override("separation", 18)
	var ricon := TextureRect.new()
	ricon.texture = Skins.preview_texture("neon", 96)
	ricon.custom_minimum_size = Vector2(96, 96)
	ricon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ricon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rrow.add_child(ricon)
	var rcol := VBoxContainer.new()
	rcol.add_theme_constant_override("separation", 6)
	rcol.add_child(_make_label("Surprise Orb", 30))
	roll_btn = _make_button("ROLL   %d coins" % Profile.RANDOM_SKIN_PRICE, 26)
	roll_btn.custom_minimum_size = Vector2(320, 74)
	roll_btn.pressed.connect(_on_roll_skin)
	rcol.add_child(roll_btn)
	rrow.add_child(rcol)
	items_view.add_child(rrow)

# One skin row (preview + buy/equip button). Used for catalog & random skins.
func _make_skin_row(id: String, nm: String) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pic := TextureRect.new()
	pic.texture = Skins.preview_texture(id, 96)
	pic.custom_minimum_size = Vector2(72, 72)
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(pic)
	var b := _make_button(nm, 30)
	b.custom_minimum_size = Vector2(360, 76)
	b.pressed.connect(_on_skin_pressed.bind(id))
	_skin_buttons[id] = b
	row.add_child(b)
	var rsp := Control.new()
	rsp.custom_minimum_size = Vector2(72, 0)
	rsp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(rsp)
	return row

# Rebuild the skins list = catalog skins + any owned random "Surprise Orb" skins.
func _rebuild_skins_view() -> void:
	for c in skins_view.get_children():
		skins_view.remove_child(c)
		c.queue_free()
	_skin_buttons = {}
	for s in Skins.CATALOG:
		skins_view.add_child(_make_skin_row(s["id"], s["name"]))
	for id in Profile.owned.keys():
		if Skins.is_random(id):
			skins_view.add_child(_make_skin_row(id, "Surprise Orb"))

func _show_shop_tab(which: String) -> void:
	var skins := which == "skins"
	skins_view.visible = skins
	items_view.visible = not skins
	_apply_button_style(shop_tab_skins_btn, skins)
	_apply_button_style(shop_tab_items_btn, not skins)

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
func _make_heart_icon(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var fill := Color(0.96, 0.30, 0.38)
	var shine := Color(1.0, 0.62, 0.66)
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
func _make_shield_icon(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var steel := Color(0.58, 0.66, 0.85)
	var steel_dk := Color(0.34, 0.40, 0.58)
	var edge := Color(0.18, 0.22, 0.34)
	var ridge := Color(0.82, 0.88, 0.98)
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

func _update_hud_ball() -> void:
	if hud_ball:
		hud_ball.texture = Skins.preview_texture(Profile.equipped, 96)

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
	var overlay := s == State.SHOP or s == State.OUTOFLIVES
	coin_hud.visible = not overlay
	hud_ball.visible = not overlay
	coin_label.text = str(Profile.coins)
	_refresh_lives()
	_refresh_shield_hud()

# Lives counter text + visibility (hidden during play/overlays and when the
# Unlimited Lives entitlement is owned -- there's no limit to show then).
func _refresh_lives() -> void:
	var unlimited := Ads.has_unlimited_lives()
	lives_hud.visible = (not unlimited) and (state == State.MENU or state == State.GAMEOVER)
	if not unlimited:
		lives_count_label.text = "%d / %d" % [Profile.lives, Profile.MAX_LIVES]

# Shield counter: shown only during a run, and only when you're carrying shields.
func _refresh_shield_hud() -> void:
	shield_hud.visible = (state == State.PLAYING) and (Profile.shields > 0)
	shield_count_label.text = "x%d" % Profile.shields

# Entry point for RETRY / tap-to-start. Gated by lives: if the player is out
# (and hasn't bought Unlimited Lives), show the out-of-lives gate instead of starting.
func _start_game() -> void:
	Profile.refill_if_new_day()
	if not Ads.has_unlimited_lives() and not Profile.has_lives():
		_show_outoflives()
		return
	_begin_run()

func _show_outoflives() -> void:
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
	_rebuild_skins_view()
	_show_shop_tab("skins")
	_refresh_shop()
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
	_update_hud_ball()
	_refresh_shop()

func _on_buy_shield() -> void:
	if Profile.buy_shield():
		_refresh_shop()

func _on_roll_skin() -> void:
	var id := Profile.roll_random_skin()
	if id == "":
		return
	player.apply_skin(Profile.equipped)
	_update_hud_ball()
	_rebuild_skins_view()
	_show_shop_tab("skins")  # show off the freshly-rolled (and equipped) orb
	_refresh_shop()

func _refresh_shop() -> void:
	shop_coin_label.text = "Coins: %d" % Profile.coins
	coin_label.text = str(Profile.coins)
	# Consumables tab
	if shield_owned_label:
		shield_owned_label.text = "Shields  %d / %d" % [Profile.shields, Profile.MAX_SHIELDS]
	if shield_buy_btn:
		shield_buy_btn.disabled = Profile.shields >= Profile.MAX_SHIELDS \
			or not Profile.can_afford(Profile.SHIELD_PRICE)
	if roll_btn:
		roll_btn.disabled = not Profile.can_afford(Profile.RANDOM_SKIN_PRICE)
	# Skins tab (catalog + owned random skins; _skin_buttons is rebuilt per open)
	for id in _skin_buttons.keys():
		var b: Button = _skin_buttons[id]
		var s: Dictionary = Skins.get_skin(id)
		var nm := str(s["name"])
		var price := int(s["price"])
		var equipped: bool = Profile.equipped == id
		if equipped:
			b.text = "%s  -  Equipped" % nm
			b.disabled = false
		elif Profile.is_owned(id):
			b.text = "%s  -  Tap to equip" % nm
			b.disabled = false
		else:
			b.text = "%s  -  %d" % [nm, price]
			b.disabled = not Profile.can_afford(price)
		_apply_button_style(b, equipped)

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
	# Drop a collectable coin in the gap ahead of this wall.
	_spawn_coin(SPAWN_Z + SPAWN_SPACING * 0.5)

func _spawn_coin(z: float) -> void:
	var c := Coin.new()
	add_child(c)
	c.setup(_current_speed(), player, z, randf_range(-ARENA_HALF, ARENA_HALF))
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
			if _is_tap(event):
				_start_game()
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
