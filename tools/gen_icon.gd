extends SceneTree
## Generates the app icons from the DEFAULT ball skin ("checker" / "Classic")
## using the game's own Skins.preview_texture(), so the launcher icon matches
## the orb the player starts with. Run headless:
##   Godot --headless --path . --script res://tools/gen_icon.gd
## Outputs (res://):
##   icon.png              512x512  full-bleed ball (project + legacy launcher)
##   icon_foreground.png   432x432  ball padded into the adaptive-icon safe zone
##   icon_background.png   432x432  solid backdrop for the adaptive icon

const DEFAULT_SKIN := "checker"
const BG_COLOR := Color(0.082, 0.086, 0.125, 1.0)  # deep slate so the ball pops

func _init() -> void:
	# Full-bleed icon: ball fills the whole canvas (transparent corners).
	var icon: Image = Skins.preview_texture(DEFAULT_SKIN, 512).get_image()
	_save(icon, "res://icon.png")

	# Adaptive background: solid color (Android masks/crops the adaptive icon).
	var bg := Image.create(432, 432, false, Image.FORMAT_RGBA8)
	bg.fill(BG_COLOR)
	_save(bg, "res://icon_background.png")

	# Adaptive foreground: ball scaled into the ~66% safe zone, centered.
	var fg := Image.create(432, 432, false, Image.FORMAT_RGBA8)
	fg.fill(Color(0, 0, 0, 0))
	var ball: Image = Skins.preview_texture(DEFAULT_SKIN, 264).get_image()
	var off := int((432 - 264) / 2.0)
	fg.blend_rect(ball, Rect2i(0, 0, 264, 264), Vector2i(off, off))
	_save(fg, "res://icon_foreground.png")

	# App Store icon: 1024x1024, fully OPAQUE (Apple rejects alpha) -- ball on
	# the solid backdrop so the rounded corners aren't transparent/black.
	var appstore := Image.create(1024, 1024, false, Image.FORMAT_RGBA8)
	appstore.fill(Color(BG_COLOR.r, BG_COLOR.g, BG_COLOR.b, 1.0))
	var ball_big: Image = Skins.preview_texture(DEFAULT_SKIN, 1024).get_image()
	appstore.blend_rect(ball_big, Rect2i(0, 0, 1024, 1024), Vector2i(0, 0))
	appstore.convert(Image.FORMAT_RGB8)  # drop the alpha CHANNEL (Apple rejects it)
	_save(appstore, "res://icon_appstore_1024.png")

	print("[gen_icon] wrote icon.png, icon_foreground.png, icon_background.png, icon_appstore_1024.png")
	quit()

func _save(img: Image, path: String) -> void:
	var err := img.save_png(path)
	if err != OK:
		push_error("[gen_icon] failed to save %s (err %d)" % [path, err])
