# NIIMBOT B1 — Flutter test printer

Minimal Android app: scan for a NIIMBOT B1 over Bluetooth LE, connect, and
print a test label. No backend, no accounts — sideload the APK and print.

The test label (hardcoded **45 × 15 mm**, 360 × 120 px at 203 dpi) contains:
- a **Code 39 barcode** of a random 8-digit number, with the digits printed below it
- a **star in each corner** — if all four print, the printer detected the full
  label size correctly.

## How it works

Printing is done through the [`niim_blue_flutter`](https://pub.dev/packages/niim_blue_flutter)
package (a Dart port of niimbluelib). It picks the correct **B1 print task**,
performs the request/response **handshake** the printer needs between each
setup packet (the missing piece when driving the protocol by hand — without it
the B1 just feeds a blank label), and encodes the page. The app only builds the
label (`PrintPage` with `addBarcode` + `addText`) and calls
`printInit → printPage → waitForFinished`.

For reference, the underlying B1 protocol is a framed serial protocol over a
single BLE characteristic:

```
55 55 | type | len | data... | checksum | AA AA      checksum = XOR(type, len, data)
```

Printing a label on the **B1** is this exact sequence (matches niimbluelib's
`B1PrintTask` — the generic D11 forms make the B1 feed a *blank* label):

| Step | Cmd  | Data                              | Meaning            |
|------|------|-----------------------------------|--------------------|
| 1    | 0x21 | `[density]`                       | set density (1–5)  |
| 2    | 0x23 | `[1]`                             | label type = WithGaps |
| 3    | 0x01 | `[00 01 00 00 00 00 00]`          | print start (**7-byte**, 1 page) |
| 4    | 0x03 | *(none)*                          | page start         |
| 5    | 0x13 | `[rows, cols, copies]` (3×u16 BE) | page size (**6-byte**) |
| 6    | 0x85 | `[y, c0, c1, c2, 1, ...rowbits]`  | bitmap row; c0–c2 = black-pixel counts per third (**must be real**, not 0) |
| 7    | 0xE3 | *(none)*                          | page end           |
| 8    | 0xF3 | *(none)*                          | print end          |

B1 printhead = 384 px wide, 203 dpi. The three count bytes split the row into
three 16-byte chunks; the B1 drops rows whose counts are zero.

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
4. Tap **Print Test Label**. Watch the green log for the barcode value + progress.

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

- Label size: `labelWidth` / `labelHeight` in `lib/main.dart` (currently 45 × 15 mm
  → 360 × 120 px). Width must be a multiple of 8 (B1 head = 384 px max).
- Label content: `_renderLabel` in `lib/main.dart` (barcode, stars, digits).
- Print darkness: `density` arg in `printImage` (1–5, default 3).
