# Android: Ads + In-App Purchases setup

`scripts/Ads.gd` already contains the full game-side logic. It uses **real**
AdMob + Google Play Billing on Android when the plugins are installed, and
**stubs** on desktop so the editor keeps working. This doc is the native side:
installing the plugins and filling in your IDs.

> The plugins are native Android libraries (AARs) compiled into the export.
> They do **not** run in the editor — test ads/IAP on a real device or emulator.

---

## 0. Prerequisites (one-time)

- Godot **4.6** with the **Android Build Template** installed
  (`Project ▸ Install Android Build Template…`).
- **JDK 17**, **Android SDK** (easiest via Android Studio).
- In `Editor ▸ Editor Settings ▸ Export ▸ Android`, set the SDK paths and a
  debug keystore.
- In the export preset: enable **Use Gradle Build** (required for plugins) and
  enable the **Internet** permission (ads need network).

---

## 1. AdMob plugin

1. Create an **AdMob account**, register the app, and create two ad units:
   an **Interstitial** and a **Rewarded** unit. Note your **AdMob App ID**
   (`ca-app-pub-XXXX~YYYY`) and the two **ad unit IDs** (`…/ZZZZ`).
2. Install a Godot 4 AdMob plugin (e.g. **Poing Studios – Godot AdMob**, or
   another maintained Godot 4.x AdMob addon). Drop it in `res://addons/…`,
   enable it in `Project ▸ Plugins`, and follow its README.
3. Add your **AdMob App ID** to the Android manifest (the plugin's README shows
   where — usually a `<meta-data>` tag, or a plugin export setting).
4. Put your real ad unit IDs in `Ads.gd` (`REAL_INTERSTITIAL_ID`,
   `REAL_REWARDED_ID`) and flip `USE_TEST_ADS = false` **only for release
   builds**. Keep `USE_TEST_ADS = true` while developing.

### Verify the singleton name & signal names
`Ads.gd` looks up `Engine.get_singleton("AdMob")` and connects these signals:

```
initialization_complete, interstitial_loaded, interstitial_failed_to_load,
interstitial_closed, rewarded_ad_loaded, rewarded_ad_failed_to_load,
rewarded_ad_dismissed, user_earned_rewarded
```

and calls these methods:

```
initialize(), load_interstitial(id), show_interstitial(),
load_rewarded_ad(id), show_rewarded_ad()
```

Different plugins use slightly different names. Check your plugin's README (or
the export/logcat output) and, if needed, update `ADMOB_SINGLETON` and the
signal/method names in `Ads.gd`. The `has_signal`/`has_method` guards mean a
mismatch degrades gracefully (no ads) instead of crashing.

---

## 2. Google Play Billing (Remove Ads)

1. In the **Play Console**, create a **one-time (non-consumable) product** with
   ID `remove_ads` (must match `REMOVE_ADS_PRODUCT` in `Ads.gd`).
2. Install the **`GodotGooglePlayBilling`** plugin (Godot 4.x build), enable it.
3. `Ads.gd` already:
   - connects on startup and **restores** the entitlement (`queryPurchases`),
   - launches the purchase on `purchase_remove_ads()`,
   - **acknowledges** the purchase (required — Google auto-refunds
     unacknowledged purchases after 3 days),
   - persists `ads_removed` locally.
4. Billing only works for an app uploaded to a Play **testing track** with
   **license testers** added — you can't test IAP from a raw sideloaded APK.

If your billing plugin registers a different singleton name, update
`BILLING_SINGLETON` in `Ads.gd`.

---

## 3. Consent (GDPR / UMP) — required for ads

AdMob requires a consent flow (Google **UMP**). Most AdMob plugins expose a
consent/UMP call — invoke it in `Ads._init_admob()` **before** loading the first
ad, per the plugin's docs. Also fill out the **Data safety** form in the Play
Console (declare the ads SDK's data collection).

---

## 4. Quick test checklist

- [ ] Debug build runs on device; `USE_TEST_ADS = true` shows Google **test** ads.
- [ ] Interstitial appears on the cadence (every `INTERSTITIAL_EVERY_N_PLAYS`
      plays) → followed by the in-game post-ad card.
- [ ] Rewarded ad on **REVIVE** and on the shop **WATCH AD → +50 coins** button;
      reward only granted when the ad completes.
- [ ] **Remove Ads** purchase (Play testing track) hides ads and **persists**
      across restarts; reinstall + restore works.
- [ ] Switch to real IDs + `USE_TEST_ADS = false` only for the production build.
