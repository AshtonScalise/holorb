extends Node3D
class_name Wall

signal crossed(survived: bool)

const WIDTH := 10.0
const HEIGHT := 5.0
const THICK := 0.6
const DESPAWN_Z := 9.0

var speed := 8.0
var holes: Array = []

var _player: Node3D
var _evaluated := false

func setup(hole_data: Array, spd: float, player_node: Node3D, start_z: float) -> void:
	holes = hole_data
	speed = spd
	_player = player_node
	position = Vector3(0, 0, start_z)
	_build_mesh()

func _build_mesh() -> void:
	var combiner := CSGCombiner3D.new()
	add_child(combiner)

	var box := CSGBox3D.new()
	box.size = Vector3(WIDTH, HEIGHT, THICK)
	box.position = Vector3(0, HEIGHT / 2.0, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.23, 0.5, 0.9)
	mat.roughness = 0.55
	box.material = mat
	combiner.add_child(box)

	for h in holes:
		var cyl := CSGCylinder3D.new()
		cyl.radius = h["radius"]
		cyl.height = THICK * 4.0
		cyl.sides = 28
		cyl.operation = CSGShape3D.OPERATION_SUBTRACTION
		cyl.rotation = Vector3(PI / 2.0, 0, 0)
		cyl.position = Vector3(h["x"], h["y"], 0)
		combiner.add_child(cyl)

func _physics_process(delta: float) -> void:
	var prev_z := position.z
	position.z += speed * delta

	if not _evaluated and _player and prev_z < _player.position.z and position.z >= _player.position.z:
		_evaluated = true
		crossed.emit(_is_survived())

	if position.z > DESPAWN_Z:
		queue_free()

func _is_survived() -> bool:
	var p := Vector2(_player.position.x, Player.RADIUS)
	for h in holes:
		var center := Vector2(h["x"], h["y"])
		# Sphere must sit completely inside the circular opening.
		if p.distance_to(center) <= float(h["radius"]) - Player.RADIUS + 0.05:
			return true
	return false
