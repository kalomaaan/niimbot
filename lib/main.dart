import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

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

  // B1 = 203 dpi ≈ 8 dots/mm. One twin label default 45 x 15 mm.
  static const int dotsPerMm = 8;
  final _widthMmCtrl = TextEditingController(text: '45');
  final _heightMmCtrl = TextEditingController(text: '15');

  // Label A (top) and B (bottom). On a 45x15/2R roll the see-through gap is
  // every 30mm, so we always print the pair in one WithGaps job (2-up): the
  // printer locks to the 2mm gap and prints both twins, no waste.
  final _nameACtrl = TextEditingController(text: 'Product A');
  final _codeACtrl = TextEditingController(text: '12345678');
  final _nameBCtrl = TextEditingController(text: 'Product B');
  final _codeBCtrl = TextEditingController(text: '87654321');
  bool _twoDifferent = false; // false = same label on both twins

  int get _labelWidth => (int.tryParse(_widthMmCtrl.text) ?? 45) * dotsPerMm;
  int get _labelHeight => (int.tryParse(_heightMmCtrl.text) ?? 15) * dotsPerMm;

  void _addLog(String msg) {
    if (!mounted) return;
    setState(() => _log.insert(0, msg));
  }

  // ---- Bluetooth ----------------------------------------------------------

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final info = await DeviceInfoPlugin().androidInfo;
    final needed = info.version.sdkInt >= 31
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
          timeout: const Duration(seconds: 4));
      final seen = <String>{};
      final unique = <BluetoothDevice>[];
      for (final d in [...found, ...FlutterBluePlus.connectedDevices]) {
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
      _addLog('Connected: $_deviceName');
      try {
        final rfid = await client.abstraction.rfidInfo();
        _addLog('RFID: present=${rfid.tagPresent} '
            'type=${rfid.consumablesType} paper=${rfid.usedPaper}/${rfid.allPaper}');
      } catch (_) {}
      client.startHeartbeat();
    } catch (e) {
      _addLog('Connect failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    try {
      await _client?.disconnect();
    } catch (_) {}
    setState(() {
      _client = null;
      _connected = false;
    });
    _addLog('Disconnected.');
  }

  // ---- Printing -----------------------------------------------------------

  Future<void> _print() async {
    final client = _client;
    if (client == null || !client.isConnected()) {
      _addLog('Not connected.');
      return;
    }
    setState(() => _busy = true);
    try {
      final w = _labelWidth;
      final h = _labelHeight;

      final nameA = _nameACtrl.text.trim();
      final codeA = _codeOrRandom(_codeACtrl.text);
      final nameB = _twoDifferent ? _nameBCtrl.text.trim() : nameA;
      final codeB = _twoDifferent ? _codeOrRandom(_codeBCtrl.text) : codeA;

      final page = PrintPage(w, h * 2);
      await _drawLabel(page, nameA, codeA, 0, w, h);
      await _drawLabel(page, nameB, codeB, h, w, h);
      _addLog(_twoDifferent
          ? '2-up: [$nameA:$codeA] + [$nameB:$codeB]'
          : '2-up (same): [$nameA:$codeA] x2');

      client.stopHeartbeat();
      client.packetIntervalMs = 0;
      final task = client.createPrintTask(const PrintOptions(
        totalPages: 1,
        density: 3,
        labelType: LabelType.withGaps, // locks to the real 30mm gap
        statusPollIntervalMs: 100,
        statusTimeoutMs: 8000,
      ));
      if (task == null) throw Exception('Printer model not detected.');
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

  String _codeOrRandom(String s) {
    final t = s.trim();
    if (t.isNotEmpty) return t;
    return List.generate(8, (_) => Random().nextInt(10).toString()).join();
  }

  /// One label template into the band at y=[oy], size [w] x [h]:
  ///   • product name, top-centered, auto-shrunk to fit the width
  ///   • Code 128 barcode, centered
  ///   • the number tucked tight under the bars (no wasted gap)
  Future<void> _drawLabel(
      PrintPage page, String name, String code, int oy, int w, int h) async {
    const margin = 8;

    // Product name — shrink font until it fits the printable width.
    if (name.isNotEmpty) {
      final fs = _fitFontSize(name, (w - 2 * margin).toDouble(), 24, 9);
      await page.addText(
        name,
        TextOptions(
          x: w ~/ 2,
          y: oy + 3,
          fontSize: fs,
          fontWeight: FontWeight.bold,
          align: HAlignment.center,
          vAlign: VAlignment.top,
        ),
      );
    }

    // Barcode bars.
    const barTop = 30;
    const barH = 44;
    page.addBarcode(
      code,
      BarcodeOptions(
        encoding: BarcodeEncoding.code128,
        x: w ~/ 2,
        y: oy + barTop,
        width: (w * 0.74).round(),
        height: barH,
        align: HAlignment.center,
        vAlign: VAlignment.top,
      ),
    );

    // Number — large, tucked right under (slightly into) the bars, no gap.
    await page.addText(
      code,
      TextOptions(
        x: w ~/ 2,
        y: oy + barTop + barH - 4,
        fontSize: 22,
        fontWeight: FontWeight.bold,
        align: HAlignment.center,
        vAlign: VAlignment.top,
      ),
    );
  }

  /// Largest integer font size (between [minFont] and [maxFont]) whose single
  /// line fits within [maxWidth] pixels.
  int _fitFontSize(String text, double maxWidth, int maxFont, int minFont) {
    for (int fs = maxFont; fs > minFont; fs--) {
      final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
        fontSize: fs.toDouble(),
        fontWeight: FontWeight.bold,
      ))
        ..addText(text);
      final p = builder.build()
        ..layout(const ui.ParagraphConstraints(width: 100000));
      if (p.longestLine <= maxWidth) return fs;
    }
    return minFont;
  }

  @override
  void dispose() {
    for (final c in [
      _widthMmCtrl,
      _heightMmCtrl,
      _nameACtrl,
      _codeACtrl,
      _nameBCtrl,
      _codeBCtrl
    ]) {
      c.dispose();
    }
    _client?.disconnect();
    super.dispose();
  }

  // ---- UI -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NIIMBOT B1')),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(child: _numField(_widthMmCtrl, 'Width (mm)')),
                    const SizedBox(width: 12),
                    Expanded(child: _numField(_heightMmCtrl, 'Height (mm)')),
                  ]),
                  const SizedBox(height: 8),
                  _textField(_nameACtrl, 'Product name (top)'),
                  _textField(_codeACtrl, 'Barcode (top)'),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Two different labels (top / bottom)'),
                    subtitle: const Text(
                        'Off = same label printed on both twins'),
                    value: _twoDifferent,
                    onChanged:
                        _busy ? null : (v) => setState(() => _twoDifferent = v),
                  ),
                  if (_twoDifferent) ...[
                    _textField(_nameBCtrl, 'Product name (bottom)'),
                    _textField(_codeBCtrl, 'Barcode (bottom)'),
                  ],
                  const SizedBox(height: 8),
                  Row(children: [
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
                        onPressed: (_busy || !_connected) ? null : _print,
                        icon: const Icon(Icons.print),
                        label: const Text('Print'),
                      ),
                    ),
                  ]),
                  if (_connected)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.bluetooth_connected,
                          color: Colors.teal),
                      title: Text(_deviceName),
                      trailing: TextButton(
                        onPressed: _busy ? null : _disconnect,
                        child: const Text('Disconnect'),
                      ),
                    ),
                  if (!_connected)
                    ..._devices.map((d) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.print_outlined),
                          title: Text(d.platformName.isEmpty
                              ? '(unnamed)'
                              : d.platformName),
                          subtitle: Text(d.remoteId.str),
                          onTap: _busy ? null : () => _connect(d),
                        )),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          SizedBox(
            height: 150,
            child: Container(
              width: double.infinity,
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

  Widget _numField(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label, isDense: true),
      );

  Widget _textField(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: TextField(
          controller: c,
          decoration: InputDecoration(labelText: label, isDense: true),
        ),
      );
}
