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
	reset()

func apply_skin(id: String) -> void:
	if ball:
		ball.material_override = Skins.make_material(id)

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
