extends Node
## Player profile autoload ("Profile"): coin wallet + owned/equipped ball skins,
## persisted to user://profile.cfg.

const PATH := "user://profile.cfg"

## Lives gate: players get MAX_LIVES per day (refilled at local midnight), lose one
## on each death, and can watch a rewarded ad for +LIVES_PER_AD when they run out.
const MAX_LIVES := 5
const LIVES_PER_AD := 3

## Consumables -- coin sinks so coins are always worth earning.
const MAX_SHIELDS := 5      # carry up to this many single-use shields into a run
const SHIELD_PRICE := 75    # coins per shield
const MAX_MAGNETS := 5      # single-use coin magnets (one consumed per run)
const MAGNET_PRICE := 50    # coins per magnet
const RANDOM_SKIN_PRICE := 150  # coins for a "Surprise Orb" random skin

var coins := 0
var owned := { "checker": true }
var equipped := "checker"
var owned_effects := { "": true }   # particle effects owned (none is always owned)
var equipped_effect := ""           # currently equipped effect ("" = none)
var lives := MAX_LIVES
var last_refill := ""  # "YYYY-MM-DD" (local) of the last daily refill
var shields := 0       # stackable single-use shields (each absorbs one hit)
var magnets := 0       # stackable single-use coin magnets (one consumed per run)

func _ready() -> void:
	_load()
	refill_if_new_day()

# ---------------------------------------------------------------------- Lives

func _today_str() -> String:
	var d := Time.get_date_dict_from_system()
	return "%04d-%02d-%02d" % [d["year"], d["month"], d["day"]]

## Refill lives to full once per local calendar day.
func refill_if_new_day() -> void:
	var today := _today_str()
	if last_refill != today:
		last_refill = today
		lives = MAX_LIVES
		save()

func has_lives() -> bool:
	return lives > 0

func lose_life() -> void:
	if lives > 0:
		lives -= 1
		save()

func add_lives(n: int) -> void:
	lives = clampi(lives + n, 0, MAX_LIVES)
	save()

## Seconds until the next local midnight (when lives refill).
func seconds_until_refill() -> int:
	var t := Time.get_time_dict_from_system()
	return 86400 - (int(t["hour"]) * 3600 + int(t["minute"]) * 60 + int(t["second"]))

# --------------------------------------------------------------- Consumables

func add_shields(n: int) -> void:
	shields = clampi(shields + n, 0, MAX_SHIELDS)
	save()

## Consume one shield. Returns true if there was one to spend.
func use_shield() -> bool:
	if shields > 0:
		shields -= 1
		save()
		return true
	return false

## Buy one shield with coins. Returns true on success.
func buy_shield() -> bool:
	if shields >= MAX_SHIELDS or coins < SHIELD_PRICE:
		return false
	coins -= SHIELD_PRICE
	shields += 1
	save()
	return true

## Consume one magnet for a run. Returns true if there was one to spend.
func use_magnet() -> bool:
	if magnets > 0:
		magnets -= 1
		save()
		return true
	return false

func buy_magnet() -> bool:
	if magnets >= MAX_MAGNETS or coins < MAGNET_PRICE:
		return false
	coins -= MAGNET_PRICE
	magnets += 1
	save()
	return true

## Buy a fresh random "Surprise Orb" skin and equip it. Returns the new id, or "".
func roll_random_skin() -> String:
	if coins < RANDOM_SKIN_PRICE:
		return ""
	coins -= RANDOM_SKIN_PRICE
	var id := Skins.new_random_id()
	while owned.has(id):
		id = Skins.new_random_id()
	owned[id] = true
	equipped = id
	save()
	return id

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

# -------------------------------------------------------------- Effects (mix & match)

func is_effect_owned(id: String) -> bool:
	return id == "" or owned_effects.has(id)

func buy_effect(id: String) -> bool:
	if is_effect_owned(id):
		return true
	var e := Skins.get_effect(id)
	var price: int = e["price"]
	if coins < price:
		return false
	coins -= price
	owned_effects[id] = true
	save()
	return true

func equip_effect(id: String) -> void:
	if is_effect_owned(id):
		equipped_effect = id
		save()

func save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("profile", "coins", coins)
	cf.set_value("profile", "owned", owned.keys())
	cf.set_value("profile", "equipped", equipped)
	cf.set_value("profile", "lives", lives)
	cf.set_value("profile", "last_refill", last_refill)
	cf.set_value("profile", "shields", shields)
	cf.set_value("profile", "magnets", magnets)
	cf.set_value("profile", "owned_effects", owned_effects.keys())
	cf.set_value("profile", "equipped_effect", equipped_effect)
	cf.save(PATH)

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) == OK:
		coins = int(cf.get_value("profile", "coins", 0))
		owned = {}
		for id in cf.get_value("profile", "owned", ["checker"]):
			owned[id] = true
		equipped = str(cf.get_value("profile", "equipped", "checker"))
		lives = int(cf.get_value("profile", "lives", MAX_LIVES))
		last_refill = str(cf.get_value("profile", "last_refill", ""))
		shields = int(cf.get_value("profile", "shields", 0))
		magnets = int(cf.get_value("profile", "magnets", 0))
		owned_effects = { "": true }
		for eid in cf.get_value("profile", "owned_effects", []):
			owned_effects[eid] = true
		equipped_effect = str(cf.get_value("profile", "equipped_effect", ""))
	# Always own the default skin.
	if not owned.has("checker"):
		owned["checker"] = true
	if not is_owned(equipped):
		equipped = "checker"
	if not is_effect_owned(equipped_effect):
		equipped_effect = ""
