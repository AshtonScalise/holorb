extends Node
## Player profile autoload ("Profile"): coin wallet + owned/equipped ball skins,
## persisted to user://profile.cfg.

const PATH := "user://profile.cfg"

var coins := 0
var owned := { "checker": true }
var equipped := "checker"

func _ready() -> void:
	_load()

func add_coins(n: int) -> void:
	coins += n

func can_afford(price: int) -> bool:
	return coins >= price

func is_owned(id: String) -> bool:
	return owned.has(id)

## Returns true if the skin is now owned (already owned, or purchase succeeded).
func buy(id: String) -> bool:
	if is_owned(id):
		return true
	var s := Skins.get_skin(id)
	var price: int = s["price"]
	if coins < price:
		return false
	coins -= price
	owned[id] = true
	save()
	return true

func equip(id: String) -> void:
	if is_owned(id):
		equipped = id
		save()

func save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("profile", "coins", coins)
	cf.set_value("profile", "owned", owned.keys())
	cf.set_value("profile", "equipped", equipped)
	cf.save(PATH)

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) == OK:
		coins = int(cf.get_value("profile", "coins", 0))
		owned = {}
		for id in cf.get_value("profile", "owned", ["checker"]):
			owned[id] = true
		equipped = str(cf.get_value("profile", "equipped", "checker"))
	# Always own the default skin.
	if not owned.has("checker"):
		owned["checker"] = true
	if not is_owned(equipped):
		equipped = "checker"
