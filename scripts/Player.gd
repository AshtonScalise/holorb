extends Node3D
class_name Player

const RADIUS := 0.5
const WASD_SPEED := 9.0

var min_x := -4.0
var max_x := 4.0
var min_z := -2.5
var max_z := 4.0

var roll_speed := 0.0  # apparent forward (world) speed, drives continuous rolling

var ball: MeshInstance3D
var fx: CPUParticles3D = null  # current skin's particle effect (or null)
var _last_pos: Vector3

func _ready() -> void:
	ball = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = RADIUS
	sm.height = RADIUS * 2.0
	ball.mesh = sm
	ball.position = Vector3(0, RADIUS, 0)
	add_child(ball)
	apply_skin(Profile.equipped)
	apply_effect(Profile.equipped_effect)
	reset()

func apply_skin(id: String) -> void:
	if ball:
		ball.material_override = Skins.make_material(id)

# Attach (or clear) a particle effect that orbits the ball, independent of the
# skin. CPUParticles3D keeps this gl_compatibility/mobile friendly.
func apply_effect(effect: String) -> void:
	if fx:
		fx.queue_free()
		fx = null
	if effect == "":
		return
	fx = CPUParticles3D.new()
	fx.position = Vector3(0, RADIUS, 0)
	fx.local_coords = false  # leave a trail in world space as the ball moves
	fx.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	fx.emission_sphere_radius = RADIUS * 0.9

	var quad := QuadMesh.new()
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	pm.vertex_color_use_as_albedo = true
	pm.albedo_texture = _soft_particle_tex()
	pm.cull_mode = BaseMaterial3D.CULL_DISABLED
	pm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD

	match effect:
		"fire":
			fx.amount = 28
			fx.lifetime = 0.6
			fx.direction = Vector3(0, 1, 0)
			fx.spread = 22.0
			fx.gravity = Vector3(0, 2.0, 0)
			fx.initial_velocity_min = 0.6
			fx.initial_velocity_max = 1.4
			fx.scale_amount_min = 0.5
			fx.scale_amount_max = 1.0
			fx.color = Color(1.0, 0.55, 0.15)
			fx.color_ramp = _ramp(Color(1.0, 0.85, 0.35, 1.0), Color(0.9, 0.12, 0.0, 0.0))
			quad.size = Vector2(0.42, 0.42)
		"electric":
			fx.amount = 24
			fx.lifetime = 0.35
			fx.spread = 180.0
			fx.gravity = Vector3.ZERO
			fx.initial_velocity_min = 1.3
			fx.initial_velocity_max = 2.6
			fx.scale_amount_min = 0.25
			fx.scale_amount_max = 0.55
			fx.color = Color(0.5, 0.85, 1.0)
			fx.color_ramp = _ramp(Color(0.7, 0.95, 1.0, 1.0), Color(0.2, 0.5, 1.0, 0.0))
			quad.size = Vector2(0.22, 0.22)
		"smoke":
			pm.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
			fx.amount = 18
			fx.lifetime = 1.4
			fx.direction = Vector3(0, 1, 0)
			fx.spread = 28.0
			fx.gravity = Vector3(0, 0.8, 0)
			fx.initial_velocity_min = 0.3
			fx.initial_velocity_max = 0.7
			fx.scale_amount_min = 0.8
			fx.scale_amount_max = 1.7
			fx.color = Color(0.5, 0.5, 0.55)
			fx.color_ramp = _ramp(Color(0.55, 0.55, 0.6, 0.55), Color(0.3, 0.3, 0.35, 0.0))
			quad.size = Vector2(0.5, 0.5)
		"sparkle":
			fx.amount = 20
			fx.lifetime = 0.8
			fx.spread = 180.0
			fx.gravity = Vector3(0, -0.5, 0)
			fx.initial_velocity_min = 0.3
			fx.initial_velocity_max = 0.9
			fx.scale_amount_min = 0.18
			fx.scale_amount_max = 0.5
			fx.color = Color(1.0, 0.9, 0.45)
			fx.color_ramp = _ramp(Color(1.0, 0.97, 0.7, 1.0), Color(1.0, 0.8, 0.2, 0.0))
			quad.size = Vector2(0.18, 0.18)

	quad.material = pm
	fx.mesh = quad
	add_child(fx)

func _ramp(a: Color, b: Color) -> Gradient:
	var g := Gradient.new()
	g.set_color(0, a)
	g.set_color(1, b)
	return g

func _soft_particle_tex() -> ImageTexture:
	var sz := 48
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var c := sz * 0.5
	for y in sz:
		for x in sz:
			var d := Vector2(x - c + 0.5, y - c + 0.5).length() / (sz * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	return ImageTexture.create_from_image(img)

func reset() -> void:
	position = Vector3(0, 0, 2.5)
	_last_pos = position

func move_by(dx: float, dz: float) -> void:
	position.x = clampf(position.x + dx, min_x, max_x)
	position.z = clampf(position.z + dz, min_z, max_z)

func _process(delta: float) -> void:
	# Optional desktop WASD / arrow-key support.
	var ix := 0.0
	var iz := 0.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		ix -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		ix += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		iz -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		iz += 1.0
	if ix != 0.0 or iz != 0.0:
		move_by(ix * WASD_SPEED * delta, iz * WASD_SPEED * delta)

	# Continuous forward roll so the ball reads as rolling into the field,
	# matching the world/ground scrolling past it.
	if roll_speed != 0.0:
		var fwd_axis := Vector3(-1.0, 0.0, 0.0)
		ball.transform.basis = Basis(fwd_axis, roll_speed * delta / RADIUS) * ball.transform.basis

	# Extra rolling from the player's own drag movement this frame.
	var move := position - _last_pos
	move.y = 0.0
	var dist := move.length()
	if dist > 0.0001:
		var axis := Vector3(move.z, 0.0, -move.x).normalized()
		ball.transform.basis = Basis(axis, dist / RADIUS) * ball.transform.basis

	ball.transform.basis = ball.transform.basis.orthonormalized()
	_last_pos = position
