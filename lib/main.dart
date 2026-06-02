import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:niim_blue_flutter/niim_blue_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const NiimbotApp());

class NiimbotApp extends StatelessWidget {
  const NiimbotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NIIMBOT B1',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  NiimbotBluetoothClient? _client;
  List<BluetoothDevice> _devices = [];
  final List<String> _log = [];
  bool _busy = false;
  bool _connected = false;
  String _deviceName = 'Connected';

  // Label size is entered in mm (read it off the label pack — the printer
  // can't report physical size, only an RFID product id). B1 = 203 dpi ≈
  // 8 dots/mm, so px = mm * 8.
  static const int dotsPerMm = 8;
  final _widthMmCtrl = TextEditingController(text: '45');
  final _heightMmCtrl = TextEditingController(text: '15');

  int get _labelWidth => (int.tryParse(_widthMmCtrl.text) ?? 45) * dotsPerMm;
  int get _labelHeight => (int.tryParse(_heightMmCtrl.text) ?? 15) * dotsPerMm;

  // Label feed mode.
  //  - withGaps: printer hunts to the next die-cut gap. On 2R twin rolls the
  //    gap is every 30mm (per pair), so it prints the top 15mm and ejects the
  //    blank bottom 15mm.
  //  - continuous: printer feeds exactly the page height (15mm), printing one
  //    twin label per print with no waste. Default for the 45x15/2R roll.
  LabelType _labelType = LabelType.continuous;

  // 45x15/2R rolls have a see-through gap only every 30mm (per pair). Printing
  // both twins at once (2-up) lets the printer align off that real gap, so it
  // never drifts and never wastes the bottom label.
  bool _twinUp = true;

  void _addLog(String msg) {
    if (!mounted) return;
    setState(() => _log.insert(0, msg));
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final info = await DeviceInfoPlugin().androidInfo;
    final List<Permission> needed = info.version.sdkInt >= 31
        ? [Permission.bluetoothScan, Permission.bluetoothConnect]
        : [Permission.bluetooth, Permission.location];
    final statuses = await needed.request();
    final ok = statuses.values.every((s) => s.isGranted);
    if (!ok) _addLog('Bluetooth permissions denied.');
    return ok;
  }

  Future<void> _scan() async {
    if (!await _ensurePermissions()) return;
    setState(() => _busy = true);
    _addLog('Scanning...');
    try {
      final found = await NiimbotBluetoothClient.listDevices(
        timeout: const Duration(seconds: 4),
      );
      final connected = FlutterBluePlus.connectedDevices;
      final seen = <String>{};
      final unique = <BluetoothDevice>[];
      for (final d in [...found, ...connected]) {
        if (seen.add(d.remoteId.str)) unique.add(d);
      }
      setState(() => _devices = unique);
      _addLog('Found ${unique.length} device(s).');
    } catch (e) {
      _addLog('Scan failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() => _busy = true);
    _addLog('Connecting to ${device.platformName}...');
    try {
      final client = NiimbotBluetoothClient();
      client.setDevice(device);
      final result = await client.connect();
      setState(() {
        _client = client;
        _connected = true;
        _deviceName = result.deviceName ?? device.platformName;
      });
      _addLog('Connected: ${result.deviceName ?? device.platformName}. Model auto-detected.');
      // Surface whatever the RFID tag knows about the loaded roll. It carries
      // a product barcode + paper count + type, but NOT physical mm.
      try {
        final rfid = await client.abstraction.rfidInfo();
        _addLog('RFID: present=${rfid.tagPresent} '
            'barcode=${rfid.barCode} type=${rfid.consumablesType} '
            'paper=${rfid.usedPaper}/${rfid.allPaper}');
      } catch (e) {
        _addLog('RFID read failed (non-genuine roll?): $e');
      }
      client.startHeartbeat();
    } catch (e) {
      _addLog('Connect failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _calibrate() async {
    final client = _client;
    if (client == null || !client.isConnected()) return;
    setState(() => _busy = true);
    _addLog('Calibrating paper (feeds a label to re-learn the gap)...');
    try {
      client.stopHeartbeat();
      final ok = await client.abstraction.labelPositioningCalibration(1);
      client.startHeartbeat();
      _addLog('Calibrate: ${ok ? 'ok' : 'failed'}');
    } catch (e) {
      _client?.startHeartbeat();
      _addLog('Calibrate failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final client = _client;
    if (client == null) return;
    try {
      await client.disconnect();
    } catch (_) {}
    setState(() {
      _client = null;
      _connected = false;
    });
    _addLog('Disconnected.');
  }

  Future<void> _printTestLabel() async {
    final client = _client;
    if (client == null || !client.isConnected()) {
      _addLog('Not connected.');
      return;
    }
    setState(() => _busy = true);
    try {
      final w = _labelWidth;
      final h = _labelHeight; // one twin label (e.g. 15mm = 120px)
      final twin = _twinUp;
      final pageH = twin ? h * 2 : h;
      final page = PrintPage(w, pageH);

      // Each twin gets its own (different) barcode. 2-up uses the real 30mm
      // gap for alignment, so it never drifts and never leaves a blank.
      final code1 = _randomCode();
      await _drawLabel(page, code1, 0, w, h);
      if (twin) {
        final code2 = _randomCode();
        await _drawLabel(page, code2, h, w, h);
        _addLog('2-up: $code1 (top) + $code2 (bottom)');
      } else {
        _addLog('Barcode: $code1');
      }
      _addLog('Page ${w}x$pageH px, '
          'mode=${twin ? "2-up/WithGaps" : _labelType.name}');

      // The library handles the full B1 handshake + encoding internally.
      client.stopHeartbeat();
      client.packetIntervalMs = 0;
      final task = client.createPrintTask(PrintOptions(
        totalPages: 1,
        density: 3,
        // 2-up relies on the real 30mm die-cut gap for alignment.
        labelType: twin ? LabelType.withGaps : _labelType,
        statusPollIntervalMs: 100,
        statusTimeoutMs: 8000,
      ));
      if (task == null) {
        throw Exception('Printer model not detected.');
      }
      _addLog('Printing...');
      await task.printInit();
      await task.printPage(page.toEncodedImage(), 1);
      await task.waitForFinished();
      client.startHeartbeat();
      _addLog('Done.');
    } catch (e) {
      _client?.startHeartbeat();
      _addLog('Print failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _randomCode() =>
      List.generate(8, (_) => Random().nextInt(10).toString()).join();

  /// Draw one label (corner ticks + barcode + digits) into the band of [page]
  /// starting at y = [oy], height [h], width [w].
  Future<void> _drawLabel(
      PrintPage page, String code, int oy, int w, int h) async {
    const inset = 8;
    const arm = 14;
    _addCorner(page, inset, oy + inset, 1, 1, arm);
    _addCorner(page, w - 1 - inset, oy + inset, -1, 1, arm);
    _addCorner(page, inset, oy + h - 1 - inset, 1, -1, arm);
    _addCorner(page, w - 1 - inset, oy + h - 1 - inset, -1, -1, arm);

    page.addBarcode(
      code,
      BarcodeOptions(
        encoding: BarcodeEncoding.code128,
        x: w ~/ 2,
        y: oy + 20,
        width: (w * 0.7).round(),
        height: 44,
        align: HAlignment.center,
        vAlign: VAlignment.top,
      ),
    );
    await page.addText(
      code,
      TextOptions(
        x: w ~/ 2,
        y: oy + h - 16,
        fontSize: 16,
        fontWeight: FontWeight.bold,
        align: HAlignment.center,
        vAlign: VAlignment.middle,
      ),
    );
  }

  /// Draw an L-shaped corner tick. ([cx],[cy]) is the corner; ([dx],[dy]) the
  /// direction (±1) the two arms extend.
  void _addCorner(PrintPage p, int cx, int cy, int dx, int dy, int len) {
    p.addLine(LineOptions(x: cx, y: cy, endX: cx + dx * len, endY: cy, thickness: 2));
    p.addLine(LineOptions(x: cx, y: cy, endX: cx, endY: cy + dy * len, thickness: 2));
  }

  @override
  void dispose() {
    _widthMmCtrl.dispose();
    _heightMmCtrl.dispose();
    _client?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NIIMBOT B1')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _widthMmCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Width (mm)', isDense: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _heightMmCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Height (mm)', isDense: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<LabelType>(
                    value: _labelType,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Feed', isDense: true),
                    items: const [
                      DropdownMenuItem(
                          value: LabelType.continuous,
                          child: Text('Continuous')),
                      DropdownMenuItem(
                          value: LabelType.withGaps, child: Text('Gaps')),
                      DropdownMenuItem(
                          value: LabelType.black, child: Text('Black mark')),
                    ],
                    onChanged: (_twinUp || _busy)
                        ? null
                        : (v) => setState(() => _labelType = v ?? _labelType),
                  ),
                ),
              ],
            ),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: const Text('Twin roll — 2 labels per feed (2-up)'),
            subtitle: const Text('For 45×15/2R: aligns off the 30mm gap, no waste'),
            value: _twinUp,
            onChanged: _busy ? null : (v) => setState(() => _twinUp = v),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _scan,
                    icon: const Icon(Icons.bluetooth_searching),
                    label: const Text('Scan'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        (_busy || !_connected) ? null : _printTestLabel,
                    icon: const Icon(Icons.print),
                    label: const Text('Print Test Label'),
                  ),
                ),
              ],
            ),
          ),
          if (_connected)
            ListTile(
              leading: const Icon(Icons.bluetooth_connected, color: Colors.teal),
              title: Text(_deviceName),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _busy ? null : _calibrate,
                    child: const Text('Calibrate'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _disconnect,
                    child: const Text('Disconnect'),
                  ),
                ],
              ),
            ),
          if (!_connected)
            Expanded(
              flex: 2,
              child: ListView(
                children: _devices
                    .map((d) => ListTile(
                          leading: const Icon(Icons.print_outlined),
                          title: Text(d.platformName.isEmpty
                              ? '(unnamed)'
                              : d.platformName),
                          subtitle: Text(d.remoteId.str),
                          onTap: _busy ? null : () => _connect(d),
                        ))
                    .toList(),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            flex: 3,
            child: Container(
              color: Colors.black,
              padding: const EdgeInsets.all(8),
              child: ListView(
                children: _log
                    .map((l) => Text(l,
                        style: const TextStyle(
                            color: Colors.greenAccent,
                            fontFamily: 'monospace',
                            fontSize: 12)))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
