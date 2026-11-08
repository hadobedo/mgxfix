# MGXFix

Makes the **8BitDo Ultimate MGX** work as a normal game controller
(rootless / roothide), where 8BitDo's own app sees it but no game does.

Verified on iOS 17.1.1 (iPhone 13 Pro, roothide). The patch is version-agnostic
— it only lowers a plist compatibility field in memory — so it should apply to
any iOS whose GameController database contains the MGX mapping.

## Root cause

iOS 17.1.1 handles the MGX correctly almost all the way through:

| Stage | Result |
|---|---|
| BLE HID-over-GATT pairing | works |
| `bluetoothd` enumerates the HID service (report map, report characteristics, input reports) | works |
| `BTLEServer` publishes an `IOHIDUserDevice` (report IDs 1 and 5) | works |
| `gamecontrollerd` opens it and matches it in the GameController device database by VID/PID (`0x2DC8:0x200B`) | works — `Matched com.8BitDo.UltimateMGX.Bluetooth` |
| Personality (the element mapping) loads | **fails** |

The failure is a **version gate**:

```
GameControllerConfigService: Skipping loading device personality:
    Personality definition requires version '11.4.7'
GameControllerConfigService: Found matching device definition
    com.8BitDo.UltimateMGX.Bluetooth ... but did not find a compatible personality.
gamecontrollerd: <IOHIDDevice> is NOT a supported game controller.
```

The MGX mapping ships in a **downloaded** GameController database asset
(`/var/MobileAsset/AssetsV2/com_apple_MobileAsset_GameController_DB1`), whose
personalities declare `CompatibilityVersion` 11.4.7 / 10.1.36 — newer than
iOS 17.1.1's `GameControllerFoundation`.

This is why 8BitDo controllers "gained iOS support" in **iOS 18.5**: not a new
driver, just a runtime new enough for the gate to pass.

Opening the gate exposes a second problem: the asset lists
`WithBackButtons.plist` first, whose model declares `button.p1`/`button.p2`
paddles. Loading it against a base MGX fails driver configuration with
`GCGenericDeviceError Code=2`. Selecting `Default.plist` fixes that.

## The fix

A single tweak injected into **`GameControllerConfigService`** that patches the
plists **in memory** as they load — nothing on disk is modified:

1. `CompatibilityVersion` → `1.0.0` for any personality
2. Force `Personalities/8BitDo/UltimateMGX/Default.plist` for
   `com.8BitDo.UltimateMGX.Bluetooth` in the device database

With those two changes the controller publishes as a real `GCController` and
works in games.

## Build

```sh
scripts/build.sh rootless    # or: roothide
```

Uses the persistent mixed toolchain (see `../MIXED_TOOLCHAIN.md`):
`THEOS=/home/nick/roothide-theos`, `TARGET_CC/CXX/LD` = `cc-mixed`/`cxx-mixed`.
The bundled clang 11 emits an incompatible arm64e ABI that crashes daemons on
load.

## Notes

- Only `GameControllerConfigService` is hooked — the device itself is published
  and matched by iOS without help.
- The personality is only read when a device connects, and the service is
  on-demand, so the fix applies on the next controller connect (no respring).
- Earlier iterations in this repo's history (a virtual-controller daemon, a
  bluetoothd `isDeviceSupported` hook, a libSandy sandbox escape) were dead
  ends; the device is published fine and the gate is purely in GameController's
  database layer.
