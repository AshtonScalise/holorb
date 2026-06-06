extends Node3D
class_name Coin

signal collected

const RADIUS := 0.32
const PICKUP_DIST := 0.95
const DESPAWN_Z := 9.0
const FLOAT_Y := 0.6
const ATTRACT_RANGE := 7.5   # magnet starts pulling within this distance
const MAGNET_PULL := 24.0     # how fast a magnetized coin homes in

var speed := 8.0
var magnet := false          # set per-coin when the Coin Magnet item is active
var _player: Node3D
var _mesh: MeshInstance3D

func setup(spd: float, player_node: Node3D, start_z: float, x: float) -> void:
	speed = spd
	_player = player_node
	position = Vector3(x, FLOAT_Y, start_z)
	_build()

func _build() -> void:
	_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = RADIUS
	cyl.bottom_radius = RADIUS
	cyl.height = 0.1
	_mesh.mesh = cyl
	# Stand the disc up so it faces the camera, then it spins for a coin shimmer.
	_mesh.rotation_degrees = Vector3(90, 0, 0)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.84, 0.2)
	m.metallic = 0.7
	m.roughness = 0.3
	m.emission_enabled = true
	m.emission = Color(0.9, 0.65, 0.05)
	m.emission_energy_multiplier = 0.5
	_mesh.material_override = m
	add_child(_mesh)

func _physics_process(delta: float) -> void:
	position.z += speed * delta
	_mesh.rotate_y(delta * 5.0)

	# Coin Magnet: home in on the player once close enough.
	if magnet and _player:
		var to := _player.position - position
		to.y = 0.0
		if to.length() < ATTRACT_RANGE:
			var step := MAGNET_PULL * delta
			position.x = move_toward(position.x, _player.position.x, step)
			position.z = move_toward(position.z, _player.position.z, step)

	if _player:
		var dx := position.x - _player.position.x
		var dz := position.z - _player.position.z
		if dx * dx + dz * dz < PICKUP_DIST * PICKUP_DIST:
			collected.emit()
			queue_free()
			return

	if position.z > DESPAWN_Z:
		queue_free()
