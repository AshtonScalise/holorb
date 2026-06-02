class_name Skins
## Procedural ball-skin catalog. No art assets needed -- every skin is generated
## in code so it ships tiny and is easy to extend. Each skin has surface detail
## so the ball's rolling rotation stays visible.

const CATALOG := [
	{ "id": "checker", "name": "Classic", "price": 0 },
	{ "id": "beach", "name": "Beach Ball", "price": 50 },
	{ "id": "watermelon", "name": "Watermelon", "price": 120 },
	{ "id": "eye", "name": "Eyeball", "price": 200 },
	{ "id": "neon", "name": "Neon", "price": 350 },
	{ "id": "gold", "name": "Gold", "price": 600 },
]

static func get_skin(id: String) -> Dictionary:
	for s in CATALOG:
		if s["id"] == id:
			return s
	return CATALOG[0]

static func make_material(id: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.roughness = 0.35
	m.metallic = 0.05
	var tex := _albedo_texture(id)
	m.albedo_texture = tex
	match id:
		"eye":
			m.roughness = 0.18
		"neon":
			m.emission_enabled = true
			m.emission_texture = tex
			m.emission = Color(0.1, 1.0, 1.0)
			m.emission_energy_multiplier = 1.5
		"gold":
			m.metallic = 1.0
			m.roughness = 0.24
	return m

# The texture actually wrapped on the 3D ball. Most skins use a repeating flat
# pattern (distortion is invisible); the eye needs a sphere-correct version so
# the iris stays a perfect circle once mapped onto the sphere.
static func _albedo_texture(id: String) -> ImageTexture:
	if id == "eye":
		return _eye_sphere(256, 128)
	return ImageTexture.create_from_image(_pattern_image(id))

# Equirectangular eye: colour each texel by its angular distance from a fixed
# direction on the sphere, so the iris is a spherical cap (a true circle on the
# ball) no matter how the texture stretches across the UVs.
static func _eye_sphere(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var white := Color(0.97, 0.97, 0.98)
	var iris := Color(0.2, 0.55, 0.85)
	var iris_in := Color(0.4, 0.72, 0.96)
	var pupil := Color(0.05, 0.05, 0.07)
	var center := _sphere_dir(0.5, 0.5)
	var pupil_a := deg_to_rad(15.0)
	var iris_a := deg_to_rad(33.0)
	for y in h:
		for x in w:
			var d := _sphere_dir((x + 0.5) / float(w), (y + 0.5) / float(h))
			var ang := acos(clampf(d.dot(center), -1.0, 1.0))
			var c := white
			if ang < pupil_a:
				c = pupil
			elif ang < iris_a:
				c = iris_in.lerp(iris, (ang - pupil_a) / (iris_a - pupil_a))
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

# Surface direction for a sphere UV, matching Godot's SphereMesh layout. (Any
# axis convention works here -- a spherical cap stays circular under rotation.)
static func _sphere_dir(u: float, v: float) -> Vector3:
	var phi := u * TAU
	var theta := v * PI
	var st := sin(theta)
	return Vector3(sin(phi) * st, cos(theta), cos(phi) * st)

# The flat pattern that wraps onto the ball for a given skin.
static func _pattern_image(id: String) -> Image:
	match id:
		"beach":
			return _stripes(192, 96, [
				Color(0.95, 0.25, 0.25), Color(0.98, 0.8, 0.2),
				Color(0.2, 0.6, 0.95), Color(0.3, 0.8, 0.4),
				Color(0.95, 0.96, 0.98)]).get_image()
		"watermelon":
			return _stripes(192, 96, [
				Color(0.25, 0.66, 0.27), Color(0.11, 0.42, 0.15)]).get_image()
		"eye":
			return _eye(128, 128).get_image()
		"neon":
			return _checker(128, 128, 8, 8, Color(0.0, 0.9, 0.9), Color(0.0, 0.18, 0.22)).get_image()
		"gold":
			return _checker(64, 32, 8, 4, Color(1.0, 0.85, 0.32), Color(0.74, 0.54, 0.12)).get_image()
		_:  # "checker" / default
			return _checker(128, 64, 8, 4, Color(0.95, 0.32, 0.26), Color(0.98, 0.86, 0.55)).get_image()

# A round, shaded swatch of the skin for menus -- reads as a little ball.
static func preview_texture(id: String, size: int = 96) -> ImageTexture:
	var pattern := _pattern_image(id)
	var pw := pattern.get_width()
	var ph := pattern.get_height()
	var glow := id == "neon"
	var out := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r := size * 0.5
	var light := Vector3(-0.4, -0.55, 0.73).normalized()
	for y in size:
		for x in size:
			var dx := (x + 0.5) - r
			var dy := (y + 0.5) - r
			var rr := r * r
			var dd := dx * dx + dy * dy
			if dd > rr:
				out.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			# Sample the wrapped pattern with a simple planar map.
			var u := float(x) / float(size)
			var v := float(y) / float(size)
			var col := pattern.get_pixel(
				clampi(int(u * pw), 0, pw - 1),
				clampi(int(v * ph), 0, ph - 1))
			# Spherical diffuse shading from the surface normal.
			var nz := sqrt(maxf(0.0, rr - dd)) / r
			var nrm := Vector3(dx / r, dy / r, nz).normalized()
			var diff := clampf(nrm.dot(light), 0.0, 1.0)
			var shade := 0.4 + 0.85 * diff if not glow else 0.7 + 0.6 * diff
			# Soft specular highlight.
			var spec := pow(diff, 18.0) * 0.6
			col = Color(
				clampf(col.r * shade + spec, 0.0, 1.0),
				clampf(col.g * shade + spec, 0.0, 1.0),
				clampf(col.b * shade + spec, 0.0, 1.0), 1.0)
			out.set_pixel(x, y, col)
	return ImageTexture.create_from_image(out)

static func _checker(w: int, h: int, cols: int, rows: int, a: Color, b: Color) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var cx := (x * cols) / w
			var cy := (y * rows) / h
			img.set_pixel(x, y, a if (cx + cy) % 2 == 0 else b)
	return ImageTexture.create_from_image(img)

static func _stripes(w: int, h: int, colors: Array) -> ImageTexture:
	var n := colors.size()
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			img.set_pixel(x, y, colors[(x * n) / w])
	return ImageTexture.create_from_image(img)

static func _eye(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var cx := w * 0.5
	var cy := h * 0.5
	var white := Color(0.97, 0.97, 0.98)
	var iris := Color(0.2, 0.55, 0.85)
	var pupil := Color(0.05, 0.05, 0.07)
	for y in h:
		for x in w:
			var d := Vector2(x - cx, y - cy).length()
			var c := white
			if d < h * 0.16:
				c = pupil
			elif d < h * 0.32:
				c = iris
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)
