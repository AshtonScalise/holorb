extends Node3D

enum State { MENU, PLAYING, GAMEOVER, SHOP, POSTAD }

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
var revive_btn: Button
var remove_ads_btn: Button
var menu_btn: Button
var coin_label: Label
var coin_hud: HBoxContainer
var hud_ball: TextureRect
var coins_gained_label: Label
var shop_root: Control
var shop_coin_label: Label
var _skin_buttons := {}

# Ads / IAP
var _revived_this_run := false
var _reward_action := ""  # "revive" or "coins" -- what the next rewarded ad is for
var postad_root: Control
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
	revive_btn = _make_button("REVIVE  (Watch Ad)", 38)
	revive_btn.pressed.connect(_on_revive_pressed)
	gv.add_child(revive_btn)
	var retry_btn := _make_button("RETRY", 38, true)
	retry_btn.pressed.connect(_start_game)
	gv.add_child(retry_btn)
	menu_btn = _make_button("MENU", 34)
	menu_btn.pressed.connect(_go_to_menu)
	gv.add_child(menu_btn)
	remove_ads_btn = _make_button("Remove Ads", 30)
	remove_ads_btn.pressed.connect(_on_remove_ads_pressed)
	gv.add_child(remove_ads_btn)

	_build_shop()
	_build_postad()

# Card shown right after an interstitial ad: upsell Remove Ads, or carry on.
func _build_postad() -> void:
	postad_root = _make_screen()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.10, 0.96)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	postad_root.add_child(bg)
	ui.add_child(postad_root)

	var v := _make_vbox(postad_root)
	v.add_child(_make_label("Thanks for playing!", 52))
	var sub := _make_label("Ads keep Holorb free", 32)
	sub.add_theme_color_override("font_color", Color(0.7, 0.74, 0.85))
	v.add_child(sub)
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 50)
	v.add_child(sp)
	var play_on := _make_button("TRY AGAIN", 40, true)
	play_on.pressed.connect(_begin_run)
	v.add_child(play_on)
	var rm := _make_button("REMOVE ADS", 34)
	rm.pressed.connect(_on_remove_ads_from_card)
	v.add_child(rm)

func _build_shop() -> void:
	shop_root = _make_screen()
	# Opaque-ish backdrop so the shop is readable and taps don't fall through.
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.11, 0.92)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	shop_root.add_child(bg)
	ui.add_child(shop_root)

	var v := _make_vbox(shop_root)
	v.add_child(_make_label("SHOP", 72))
	shop_coin_label = _make_label("Coins: 0", 40)
	shop_coin_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	v.add_child(shop_coin_label)
	# Free-coins rewarded-ad button, separate from the skin list.
	ad_coins_btn = _make_button("WATCH AD   +%d  COINS" % AD_COINS_REWARD, 30, true)
	ad_coins_btn.pressed.connect(_on_watch_ad_coins)
	v.add_child(ad_coins_btn)
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 20)
	v.add_child(sp)
	for s in Skins.CATALOG:
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 16)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var pic := TextureRect.new()
		pic.texture = Skins.preview_texture(s["id"], 96)
		pic.custom_minimum_size = Vector2(80, 80)
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(pic)
		var b := _make_button(s["name"], 34)
		b.custom_minimum_size = Vector2(380, 84)
		b.pressed.connect(_on_skin_pressed.bind(s["id"]))
		_skin_buttons[s["id"]] = b
		row.add_child(b)
		# Invisible right spacer (= preview width) keeps the BUTTON centered on
		# screen, aligned with the WATCH AD / Back buttons; preview sits in the
		# left gutter.
		var rsp := Control.new()
		rsp.custom_minimum_size = Vector2(80, 0)
		rsp.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(rsp)
		v.add_child(row)
	var sp2 := Control.new()
	sp2.custom_minimum_size = Vector2(0, 30)
	v.add_child(sp2)
	var back := _make_button("Back", 34)
	back.pressed.connect(_close_shop)
	v.add_child(back)

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
	postad_root.visible = (s == State.POSTAD)
	score_label.visible = (s == State.PLAYING)
	# Coin counter + equipped-ball preview show everywhere except overlays
	# (shop / post-ad card, which have their own backdrops).
	var overlay := s == State.SHOP or s == State.POSTAD
	coin_hud.visible = not overlay
	hud_ball.visible = not overlay
	coin_label.text = str(Profile.coins)

# Entry point for RETRY / tap-to-start. Counts the play and, on the interstitial
# cadence, shows the ad + post-ad card before the run actually begins.
func _start_game() -> void:
	var was_gameover := state == State.GAMEOVER
	Ads.notify_play()
	# Only surface the post-ad card if an interstitial actually played.
	if was_gameover and Ads.is_interstitial_due() and Ads.show_interstitial():
		_set_state(State.POSTAD)
	else:
		_begin_run()

func _begin_run() -> void:
	_clear_field()
	score = 0
	score_label.text = "0"
	_run_coins = 0
	coin_label.text = str(Profile.coins)
	player.reset()
	shake = 0.0
	_revived_this_run = false
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
	Profile.save()
	_update_gameover_buttons()
	_set_state(State.GAMEOVER)

# Halt all world motion on death so the scene freezes behind the game-over UI.
func _freeze_field() -> void:
	for w in walls:
		if is_instance_valid(w):
			w.set_physics_process(false)
	for c in coins:
		if is_instance_valid(c):
			c.set_physics_process(false)

func _update_gameover_buttons() -> void:
	revive_btn.visible = (not _revived_this_run) and Ads.is_rewarded_ready()
	remove_ads_btn.visible = not Ads.ads_removed

func _go_to_menu() -> void:
	_clear_field()
	score = 0
	player.reset()
	shake = 0.0
	_set_state(State.MENU)

# ------------------------------------------------------------------ Ads / IAP

func _on_revive_pressed() -> void:
	if _revived_this_run or not Ads.is_rewarded_ready():
		return
	_reward_action = "revive"
	Ads.show_rewarded()

func _on_watch_ad_coins() -> void:
	if not Ads.is_rewarded_ready():
		return
	_reward_action = "coins"
	Ads.show_rewarded()

func _on_remove_ads_pressed() -> void:
	Ads.purchase_remove_ads()

# Remove Ads tapped on the post-ad card -- buy, then carry on into the run.
func _on_remove_ads_from_card() -> void:
	Ads.purchase_remove_ads()
	_begin_run()

func _on_rewarded_completed(granted: bool) -> void:
	var action := _reward_action
	_reward_action = ""
	if not granted:
		return
	match action:
		"revive":
			_do_revive()
		"coins":
			Profile.add_coins(AD_COINS_REWARD)
			Profile.save()
			coin_label.text = str(Profile.coins)
			_refresh_shop()

func _on_ads_removed_changed(_removed: bool) -> void:
	if remove_ads_btn:
		remove_ads_btn.visible = false
	if ad_coins_btn:
		ad_coins_btn.visible = true  # rewarded coins still available after removing ads

func _do_revive() -> void:
	# Clear the field so the player isn't instantly re-killed; keep score & coins.
	_clear_field()
	_revived_this_run = true
	player.reset()
	shake = 0.0
	_set_state(State.PLAYING)

# --------------------------------------------------------------------- Shop

func _open_shop() -> void:
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

func _refresh_shop() -> void:
	shop_coin_label.text = "Coins: %d" % Profile.coins
	coin_label.text = str(Profile.coins)
	for s in Skins.CATALOG:
		var b: Button = _skin_buttons[s["id"]]
		var id: String = s["id"]
		var equipped := Profile.equipped == id
		if equipped:
			b.text = "%s  -  Equipped" % s["name"]
			b.disabled = false
		elif Profile.is_owned(id):
			b.text = "%s  -  Tap to equip" % s["name"]
			b.disabled = false
		else:
			b.text = "%s  -  %d" % [s["name"], s["price"]]
			b.disabled = not Profile.can_afford(int(s["price"]))
		# Highlight the equipped skin with the accent style.
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
		State.POSTAD:
			pass  # TRY AGAIN / REMOVE ADS buttons handle their own input
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
