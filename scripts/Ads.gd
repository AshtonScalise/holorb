extends Node
## Ad + in-app-purchase layer (autoload singleton "Ads").
##
## The PUBLIC API is platform-agnostic. On MOBILE (Android + iOS), when the
## AdMob and store-billing plugins are installed, real ads / purchases are used.
## On desktop / in the editor (or whenever a plugin is missing) it falls back to
## stubs so the game stays fully playable.
##
## Ads use Google AdMob on BOTH Android and iOS (the Google Mobile Ads SDK ships
## for both; a cross-platform Godot AdMob plugin exposes one "AdMob" singleton).
## "Remove Ads" billing differs per store: Google Play Billing on Android,
## StoreKit on iOS -- both are funnelled through the same public API below.
##
## The native plugins are compiled into the mobile export -- they don't exist in
## the editor, so all plugin access is guarded behind OS/singleton checks and
## never runs on desktop. See ANDROID_SETUP.md and IOS_SETUP.md for install steps.

signal rewarded_completed(reward_granted: bool)
signal ads_removed_changed(removed: bool)

# ======================= CONFIG -- fill in before release ====================
## Keep true while developing so Google's TEST ads are served. Set to false for
## the production build so your real ad units are used (serving real ads on a
## debug build risks an AdMob policy strike).
const USE_TEST_ADS := true

# Google's official sample ad unit IDs -- safe to use during development.
const TEST_INTERSTITIAL_ID := "ca-app-pub-3940256099942544/1033173712"
const TEST_REWARDED_ID := "ca-app-pub-3940256099942544/5224354917"

# TODO(release): paste your real AdMob ad unit IDs here.
const REAL_INTERSTITIAL_ID := "ca-app-pub-0000000000000000/0000000000"
const REAL_REWARDED_ID := "ca-app-pub-0000000000000000/0000000000"

## Google Play Billing product ID for the non-consumable "remove ads" purchase
## (must match the product you create in the Play Console).
const REMOVE_ADS_PRODUCT := "remove_ads"

## Engine singleton names registered by the plugins. If your plugin registers a
## different name, change it here (see its README / export logs).
const ADMOB_SINGLETON := "AdMob"                      # AdMob plugin (Android + iOS)
const BILLING_SINGLETON := "GodotGooglePlayBilling"   # Android: Google Play Billing
const IOS_IAP_SINGLETON := "InAppStore"               # iOS: StoreKit (godot-ios-plugins)
# =============================================================================

## Show an interstitial once every this many plays (a "play" = one run started).
const INTERSTITIAL_EVERY_N_PLAYS := 3
const SAVE_PATH := "user://ads.save"

var ads_removed := false
var _play_count := 0

# --- backend state (mobile only; stay null/false on desktop) ---
var _admob = null
var _billing = null      # Android Google Play Billing singleton
var _ios_iap = null      # iOS StoreKit singleton
var _interstitial_loaded := false
var _rewarded_loaded := false
var _reward_earned := false  # set when the user earns a rewarded ad's reward

func _ready() -> void:
	set_process(false)  # only iOS billing needs per-frame polling (enabled below)
	_load()
	_init_admob()
	_init_billing()

## True on a real phone/tablet (Android or iOS), false in the editor / desktop.
func _is_mobile() -> bool:
	var n := OS.get_name()
	return n == "Android" or n == "iOS"

func _has_admob() -> bool:
	return _admob != null

func _has_billing() -> bool:
	return _billing != null or _ios_iap != null

func _interstitial_id() -> String:
	return TEST_INTERSTITIAL_ID if USE_TEST_ADS else REAL_INTERSTITIAL_ID

func _rewarded_id() -> String:
	return TEST_REWARDED_ID if USE_TEST_ADS else REAL_REWARDED_ID

func _connect_if(obj, sig: String, cb: Callable) -> void:
	if obj != null and obj.has_signal(sig) and not obj.is_connected(sig, cb):
		obj.connect(sig, cb)

# ================================ AdMob ======================================

func _init_admob() -> void:
	if not _is_mobile():
		return
	if not Engine.has_singleton(ADMOB_SINGLETON):
		push_warning("[Ads] AdMob singleton '%s' not found -- ads disabled." % ADMOB_SINGLETON)
		return
	_admob = Engine.get_singleton(ADMOB_SINGLETON)
	# Lifecycle signals (names follow the common Godot AdMob plugins; verify
	# against your plugin's README and adjust if they differ).
	_connect_if(_admob, "initialization_complete", _on_admob_initialized)
	_connect_if(_admob, "interstitial_loaded", _on_interstitial_loaded)
	_connect_if(_admob, "interstitial_failed_to_load", _on_interstitial_failed)
	_connect_if(_admob, "interstitial_closed", _on_interstitial_closed)
	_connect_if(_admob, "rewarded_ad_loaded", _on_rewarded_loaded)
	_connect_if(_admob, "rewarded_ad_failed_to_load", _on_rewarded_failed)
	_connect_if(_admob, "rewarded_ad_dismissed", _on_rewarded_dismissed)
	_connect_if(_admob, "user_earned_rewarded", _on_user_earned_reward)
	if _admob.has_method("initialize"):
		_admob.initialize()
	else:
		_on_admob_initialized()

func _on_admob_initialized(_data = null) -> void:
	_load_interstitial()
	_load_rewarded()

func _load_interstitial() -> void:
	if _has_admob() and _admob.has_method("load_interstitial"):
		_admob.load_interstitial(_interstitial_id())

func _load_rewarded() -> void:
	if _has_admob() and _admob.has_method("load_rewarded_ad"):
		_admob.load_rewarded_ad(_rewarded_id())

func _on_interstitial_loaded(_a = null) -> void:
	_interstitial_loaded = true

func _on_interstitial_failed(_a = null, _b = null) -> void:
	_interstitial_loaded = false

func _on_interstitial_closed(_a = null) -> void:
	_interstitial_loaded = false
	_load_interstitial()  # preload the next one

func _on_rewarded_loaded(_a = null) -> void:
	_rewarded_loaded = true

func _on_rewarded_failed(_a = null, _b = null) -> void:
	_rewarded_loaded = false

func _on_user_earned_reward(_a = null, _b = null) -> void:
	_reward_earned = true

func _on_rewarded_dismissed(_a = null) -> void:
	_rewarded_loaded = false
	rewarded_completed.emit(_reward_earned)
	_reward_earned = false
	_load_rewarded()  # preload the next one

# ============================= Remove Ads (IAP) ==============================

func purchase_remove_ads() -> void:
	# Android (Google Play Billing): grant arrives via the purchases_updated callback.
	if _billing != null and _billing.has_method("purchase"):
		_billing.purchase(REMOVE_ADS_PRODUCT)
		return
	# iOS (StoreKit): grant arrives via the polled pending-event queue.
	if _ios_iap != null and _ios_iap.has_method("purchase"):
		_ios_iap.purchase({"product_id": REMOVE_ADS_PRODUCT})
		return
	# Editor / desktop stub: simulate an instant successful purchase. Never
	# auto-grant on a real device with no billing backend (that'd be a free unlock).
	if not _is_mobile():
		print("[Ads] purchase_remove_ads (stub) -> granting")
		_grant_remove_ads()
	else:
		push_warning("[Ads] No billing backend available -- purchase unavailable.")

func restore_purchases() -> void:
	if _billing != null and _billing.has_method("queryPurchases"):
		_billing.queryPurchases("inapp")
		return
	if _ios_iap != null and _ios_iap.has_method("restore_purchases"):
		_ios_iap.restore_purchases()
		return
	print("[Ads] restore_purchases (stub)")

func _grant_remove_ads() -> void:
	if ads_removed:
		return
	ads_removed = true
	_save()
	ads_removed_changed.emit(true)

# ================================ Billing ====================================

func _init_billing() -> void:
	match OS.get_name():
		"Android":
			_init_billing_android()
		"iOS":
			_init_billing_ios()

# --- Android: Google Play Billing (signal-based) ---
func _init_billing_android() -> void:
	if not Engine.has_singleton(BILLING_SINGLETON):
		push_warning("[Ads] Billing singleton '%s' not found -- IAP disabled." % BILLING_SINGLETON)
		return
	_billing = Engine.get_singleton(BILLING_SINGLETON)
	_connect_if(_billing, "connected", _on_billing_connected)
	_connect_if(_billing, "purchases_updated", _on_purchases_updated)
	_connect_if(_billing, "query_purchases_response", _on_query_purchases)
	_connect_if(_billing, "purchase_acknowledged", _on_purchase_acknowledged)
	if _billing.has_method("startConnection"):
		_billing.startConnection()

# --- iOS: StoreKit (poll-based; the plugin queues events we drain in _process) ---
func _init_billing_ios() -> void:
	if not Engine.has_singleton(IOS_IAP_SINGLETON):
		push_warning("[Ads] iOS IAP singleton '%s' not found -- IAP disabled." % IOS_IAP_SINGLETON)
		return
	_ios_iap = Engine.get_singleton(IOS_IAP_SINGLETON)
	set_process(true)  # drain StoreKit events each frame
	# Restore any previously-owned "remove ads" entitlement on launch.
	if _ios_iap.has_method("restore_purchases"):
		_ios_iap.restore_purchases()

func _process(_delta: float) -> void:
	# Only iOS StoreKit needs polling; set_process is off otherwise.
	if _ios_iap == null:
		return
	if not _ios_iap.has_method("get_pending_event_count"):
		return
	while _ios_iap.get_pending_event_count() > 0:
		_handle_ios_iap_event(_ios_iap.get_pending_event())

func _handle_ios_iap_event(event) -> void:
	if typeof(event) != TYPE_DICTIONARY:
		return
	var type: String = str(event.get("type", ""))
	var result: String = str(event.get("result", ""))
	var product_id: String = str(event.get("product_id", ""))
	# A successful purchase or restore of our product grants the entitlement.
	if (type == "purchase" or type == "restore") and result == "ok" \
			and product_id == REMOVE_ADS_PRODUCT:
		_grant_remove_ads()
		# Tell StoreKit the transaction is handled so it isn't re-delivered.
		if _ios_iap.has_method("finish_transaction"):
			_ios_iap.finish_transaction(product_id)

func _on_billing_connected() -> void:
	# Restore any previously-owned "remove ads" entitlement.
	if _billing.has_method("queryPurchases"):
		_billing.queryPurchases("inapp")

func _on_query_purchases(result) -> void:
	# result.purchases is the owned list (shape per the billing plugin).
	if typeof(result) == TYPE_DICTIONARY and result.has("purchases"):
		_process_purchases(result["purchases"])

func _on_purchases_updated(purchases) -> void:
	_process_purchases(purchases)

func _process_purchases(purchases) -> void:
	if typeof(purchases) != TYPE_ARRAY:
		return
	for p in purchases:
		var skus = p.get("skus", p.get("products", []))
		if REMOVE_ADS_PRODUCT in skus:
			_grant_remove_ads()
			# Acknowledge so Google doesn't auto-refund after 3 days.
			if not p.get("is_acknowledged", false) and _billing.has_method("acknowledgePurchase"):
				_billing.acknowledgePurchase(p.get("purchase_token", ""))

func _on_purchase_acknowledged(_token = null) -> void:
	pass  # entitlement already granted in _process_purchases

# --------------------------------------------------------------- Interstitial

## Call once when a run starts so the play-count cadence advances.
func notify_play() -> void:
	_play_count += 1

## True when this play lands on the interstitial cadence (and ads aren't removed).
func is_interstitial_due() -> bool:
	if ads_removed:
		return false
	return _play_count % INTERSTITIAL_EVERY_N_PLAYS == 0

## Shows an interstitial if one is ready. Returns true if an ad was shown
## (so the caller can decide whether to show the post-ad card).
func show_interstitial() -> bool:
	if ads_removed:
		return false
	if _has_admob():
		if _interstitial_loaded and _admob.has_method("show_interstitial"):
			_admob.show_interstitial()
			return true
		_load_interstitial()  # wasn't ready; load for next time
		return false
	# Editor / desktop stub (pretend an ad ran). On a device with no AdMob,
	# don't fake it -- report "no ad shown" so the post-ad card is skipped.
	if not _is_mobile():
		print("[Ads] interstitial shown (stub)")
		return true
	return false

# ------------------------------------------------------- Rewarded (revive etc.)

func is_rewarded_ready() -> bool:
	if _has_admob():
		return _rewarded_loaded
	return not _is_mobile()  # stub "ready" only in the editor / desktop

func show_rewarded() -> void:
	if _has_admob():
		if _rewarded_loaded and _admob.has_method("show_rewarded_ad"):
			_reward_earned = false
			_admob.show_rewarded_ad()
		else:
			_load_rewarded()
			rewarded_completed.emit(false)  # nothing to show -> no reward
		return
	# Editor / desktop stub: grant instantly so the flow is testable. On a real
	# device with no AdMob, emit "no reward" instead of handing out a free one.
	if not _is_mobile():
		print("[Ads] rewarded shown (stub) -> reward granted")
		rewarded_completed.emit(true)
	else:
		rewarded_completed.emit(false)

# ----------------------------------------------------------------- Persistence

func _load() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f:
			ads_removed = f.get_8() == 1

func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_8(1 if ads_removed else 0)
