# iOS: Ads + In-App Purchases setup

`scripts/Ads.gd` is cross-platform. It uses **AdMob** for ads on **both** Android
and iOS, and **StoreKit** for the "Remove Ads" purchase on iOS (Google Play
Billing on Android). On iOS it activates when the native plugins are installed,
and falls back to stubs in the editor/desktop so the game stays playable.

> iOS plugins are native libraries (`.xcframework` / `.a` + a `.gdip` config)
> linked into the Xcode project Godot generates. They do **not** run in the
> editor — test ads/IAP on a real device or the iOS Simulator build.

---

## 0. Prerequisites (one-time)

- **Godot 4.6** with the iOS export template installed (already done in this repo).
- **Xcode** (16.x is installed here) + an **Apple Developer Program** membership
  ($99/yr) — required to sign, run on device, and submit to the App Store.
- A **Bundle Identifier** registered in your Apple Developer account. Match it to
  the export preset's `application/bundle_identifier`. Recommended:
  `com.currenox.holorb` (mirrors the Android package).
- In `Editor ▸ Editor Settings ▸ Export ▸ iOS`, no SDK path is needed (Xcode is
  auto-detected via `xcrun`).

The iOS export produces an **Xcode project**, not a finished `.ipa`. You open it
in Xcode, set the team/signing, then **Archive ▸ Distribute** to the App Store.

---

## 1. AdMob plugin (iOS)

1. In **AdMob**, register the **iOS** app (separate from the Android one) and
   create an **Interstitial** and a **Rewarded** ad unit. Note the iOS **App ID**
   (`ca-app-pub-XXXX~YYYY`) and the two iOS **ad unit IDs**.
2. Install a Godot 4 **iOS AdMob** plugin that registers the same `"AdMob"`
   singleton (e.g. the Poing Studios *Godot AdMob* plugin ships iOS support, or
   another maintained Godot 4.x iOS AdMob addon). Enable it in `Project ▸ Plugins`.
3. Add your AdMob **iOS App ID** to the app's `Info.plist` as `GADApplicationIdentifier`
   (the plugin's export settings or its README show where).
4. iOS ads use the SAME code path and the SAME `Ads.gd` IDs you already have:
   - `REAL_INTERSTITIAL_ID` / `REAL_REWARDED_ID` — **but those are per-platform**.
     If your AdMob plugin needs different IDs on iOS, branch them in `Ads.gd`
     (e.g. `OS.get_name() == "iOS"`). Keep `USE_TEST_ADS = true` while developing.

`Ads.gd` already initializes AdMob on iOS (`_is_mobile()` covers `"iOS"`) and uses
the same signals/methods as Android (`initialize`, `load_interstitial`,
`show_interstitial`, `load_rewarded_ad`, `show_rewarded_ad`, etc.). If your iOS
plugin uses different names, the `has_signal`/`has_method` guards degrade
gracefully — update the names in `Ads.gd` to match its README.

### App Tracking Transparency (ATT) — required
iOS requires the **ATT** prompt before serving personalized ads. Add
`NSUserTrackingUsageDescription` to `Info.plist` and request authorization
(`ATTrackingManager`) — most AdMob plugins expose an ATT/UMP consent call. Invoke
it before loading the first ad. Also add the AdMob **SKAdNetwork identifiers** to
`Info.plist` (Google publishes the list) so ad attribution works.

---

## 2. StoreKit "Remove Ads" (iOS IAP)

1. In **App Store Connect**, create a **Non-Consumable** in-app purchase with
   product ID `remove_ads` (must match `REMOVE_ADS_PRODUCT` in `Ads.gd`).
2. Install the **`InAppStore`** iOS plugin (from *godot-ios-plugins*), which
   registers the `"InAppStore"` singleton. Enable it in `Project ▸ Plugins`.
3. `Ads.gd` already:
   - calls `InAppStore.restore_purchases()` on launch to restore the entitlement,
   - launches the purchase on `purchase_remove_ads()` via
     `InAppStore.purchase({"product_id": "remove_ads"})`,
   - **polls** the StoreKit event queue each frame (`get_pending_event_count` /
     `get_pending_event`) and grants + `finish_transaction()` on success,
   - persists `ads_removed` locally.
4. If your IAP plugin registers a different singleton name, update
   `IOS_IAP_SINGLETON` in `Ads.gd`. If its event shape differs (`type`/`result`/
   `product_id` keys), adjust `_handle_ios_iap_event()`.
5. Test IAP with a **Sandbox tester** account (App Store Connect ▸ Users and
   Access ▸ Sandbox) signed in on the device.

---

## 3. Build & submit

1. In the iOS export preset set the **Bundle Identifier**, app name, version, and
   required privacy strings (ATT, etc.). Enable the plugins.
2. Export → opens/produces an Xcode project. In Xcode: select your **Team**, fix
   signing, pick a device or "Any iOS Device", then **Product ▸ Archive**.
3. From the Organizer, **Distribute App ▸ App Store Connect**.
4. Fill out the **App Privacy** questionnaire in App Store Connect (declare the
   ads SDK's data collection / tracking) — required, mirrors Play's Data safety.

---

## 4. Quick test checklist

- [ ] Device build runs; `USE_TEST_ADS = true` shows Google **test** ads on iOS.
- [ ] ATT prompt appears on first launch before the first ad loads.
- [ ] Interstitial on the play cadence; rewarded on **REVIVE** and shop
      **WATCH AD → +50 coins** (reward only when the ad completes).
- [ ] **Remove Ads** purchase (Sandbox tester) hides ads and **persists** across
      restarts; reinstall + **Restore Purchases** re-grants it.
- [ ] Switch to real IDs + `USE_TEST_ADS = false` only for the App Store build.
