# NIIMBOT B1 — Flutter test printer

Minimal Android app: scan for a NIIMBOT B1 over Bluetooth LE, connect, and
print a "HELLO WORLD" test label. No backend, no accounts — sideload the APK
and print.

## How it works

The B1 speaks a simple framed serial protocol over a single BLE characteristic:

```
55 55 | type | len | data... | checksum | AA AA      checksum = XOR(type, len, data)
```

Printing a label is a fixed sequence of packets:

| Step | Cmd  | Meaning            |
|------|------|--------------------|
| 1    | 0x21 | set density        |
| 2    | 0x23 | set label type     |
| 3    | 0x01 | start print        |
| 4    | 0x03 | start page         |
| 5    | 0x13 | set dimension (rows, cols) |
| 6    | 0x85 | one packed bitmap row (repeat per row) |
| 7    | 0xE3 | end page           |
| 8    | 0xF3 | end print          |

BLE transport:
- Service `e7810a71-73ae-499d-8c15-faa9aef0c3f2`
- Characteristic `bef8d6c9-9c21-4c9e-b632-bd58c1009f9f` (NOTIFY + WRITE_NO_RESPONSE)

Text is rasterized to a 1-bit grid with `dart:ui` (`lib/main.dart`), then each
row is packed MSB-first and sent (`lib/niimbot.dart`).

Protocol reference: [niim.blue wiki](https://printers.niim.blue/interfacing/proto/)
and [AndBondStyle/niimprint](https://github.com/AndBondStyle/niimprint)
(tested on the B1).

## Get the APK (no local Flutter needed)

GitHub Actions builds and signs (debug key — installable) the APK for you.

1. Push this repo to GitHub.
2. Tag a release:
   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```
3. The **Build APK** workflow runs, attaches `niimbot-b1.apk` to the GitHub
   Release. (Or trigger it manually from the Actions tab and grab the artifact.)
4. On your phone, enable "install unknown apps", download and install the APK.

## Use it

1. Power on the B1, make sure it has a label roll.
2. Open the app → **Scan** → grant Bluetooth permissions.
3. Tap your printer in the list (name usually starts with `B1`).
4. Tap **Print Hello World**. Watch the green log for progress.

## Local build (optional)

Needs the [Flutter SDK](https://docs.flutter.dev/get-started/install).

```bash
flutter create --platforms=android --project-name niimbot_b1 --org dev.niimbot .
cp _overrides/AndroidManifest.xml android/app/src/main/AndroidManifest.xml
flutter pub get
flutter run            # or: flutter build apk --release
```

> `android/` is generated, not committed (see `.gitignore`). The custom
> Bluetooth manifest lives in `_overrides/` and is copied in after
> `flutter create`.

## Tweaks

- Label size / text: `labelWidth`, `labelHeight`, and the `_renderText('HELLO\nWORLD', ...)`
  call in `lib/main.dart`. Width must be a multiple of 8 (B1 head ≈ 384 px max).
- Print darkness: `density` arg in `printImage` (1–5, default 3).
