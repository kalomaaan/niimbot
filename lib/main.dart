import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'niimbot.dart';

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
  final List<ScanResult> _results = [];
  final List<String> _log = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  BluetoothDevice? _connected;
  NiimbotPrinter? _printer;
  bool _busy = false;

  // Paper is hardcoded to 45 x 15 mm. B1 = 203 dpi = 8 dots/mm, so:
  //   width  = 45 mm * 8 = 360 px (across the printhead)
  //   height = 15 mm * 8 = 120 px (feed direction)
  static const int labelWidth = 360;
  static const int labelHeight = 120;

  void _addLog(String msg) {
    if (!mounted) return;
    setState(() => _log.insert(0, msg));
  }

  Future<bool> _ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final ok = statuses[Permission.bluetoothScan]?.isGranted == true &&
        statuses[Permission.bluetoothConnect]?.isGranted == true;
    if (!ok) _addLog('Bluetooth permissions denied.');
    return ok;
  }

  Future<void> _scan() async {
    if (!await _ensurePermissions()) return;
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _addLog('Turn Bluetooth on first.');
      return;
    }
    setState(() {
      _results.clear();
      _busy = true;
    });
    _addLog('Scanning...');
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        _results
          ..clear()
          ..addAll(results.where((r) => r.device.platformName.isNotEmpty));
      });
    });
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    await FlutterBluePlus.isScanning.where((s) => s == false).first;
    setState(() => _busy = false);
    _addLog('Scan done (${_results.length} named devices).');
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() => _busy = true);
    try {
      _addLog('Connecting to ${device.platformName}...');
      await device.connect(timeout: const Duration(seconds: 15));
      var mtu = 23;
      try {
        mtu = await device.requestMtu(512);
      } catch (_) {/* keep default */}
      _addLog('Connected. MTU=$mtu. Discovering services...');

      final services = await device.discoverServices();
      BluetoothCharacteristic? target;
      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.uuid == niimbotChar ||
              (s.uuid == niimbotService &&
                  c.properties.writeWithoutResponse)) {
            target = c;
          }
        }
      }
      if (target == null) {
        _addLog('NIIMBOT characteristic not found.');
        await device.disconnect();
        return;
      }
      if (target.properties.notify) {
        await target.setNotifyValue(true);
        target.lastValueStream.listen((v) {
          if (v.isNotEmpty) _addLog('<- ${_hex(v)}');
        });
      }
      _connected = device;
      _printer = NiimbotPrinter(target, log: _addLog, mtu: mtu);
      _addLog('Ready to print.');
    } catch (e) {
      _addLog('Connect failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _printTestLabel() async {
    final printer = _printer;
    if (printer == null) return;
    setState(() => _busy = true);
    try {
      // Random Code 39 numeric payload.
      final rnd = Random();
      final code =
          List.generate(8, (_) => rnd.nextInt(10).toString()).join();
      _addLog('Barcode: $code');
      final rows = await _renderLabel(code, labelWidth, labelHeight);
      await printer.printImage(rows);
    } catch (e) {
      _addLog('Print failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Draw the test label (4 corner stars + Code 39 barcode + digits) and
  /// rasterize to a 1-bit grid. true => black (printed) dot.
  Future<List<List<bool>>> _renderLabel(
      String code, int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final w = width.toDouble();
    final h = height.toDouble();
    final black = Paint()..color = const Color(0xFF000000);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFFFFFFF));

    // Corner stars — confirm the printer detected the full label area.
    const inset = 10.0;
    const starR = 6.0;
    _drawStar(canvas, const Offset(inset, inset), starR, black);
    _drawStar(canvas, Offset(w - inset, inset), starR, black);
    _drawStar(canvas, Offset(inset, h - inset), starR, black);
    _drawStar(canvas, Offset(w - inset, h - inset), starR, black);

    // Code 39 barcode, centered horizontally.
    final modules = _code39Modules(code); // list of (isBar, widthInModules)
    final totalModules =
        modules.fold<int>(0, (sum, m) => sum + m.$2);
    final barAreaW = w * 0.66;
    final moduleW = barAreaW / totalModules;
    final barHeight = h * 0.42;
    final barTop = h * 0.16;
    var x = (w - barAreaW) / 2;
    for (final m in modules) {
      final mw = m.$2 * moduleW;
      if (m.$1) {
        canvas.drawRect(Rect.fromLTWH(x, barTop, mw, barHeight), black);
      }
      x += mw;
    }

    // Human-readable digits below the bars.
    final pb = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.center,
      fontSize: 22,
      fontWeight: FontWeight.bold,
    ))
      ..pushStyle(ui.TextStyle(color: const Color(0xFF000000)))
      ..addText(code);
    final paragraph = pb.build()
      ..layout(ui.ParagraphConstraints(width: w));
    canvas.drawParagraph(paragraph, Offset(0, barTop + barHeight + 4));

    final image = await recorder.endRecording().toImage(width, height);
    final bytes =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final px = bytes!.buffer.asUint8List();

    return List.generate(height, (y) {
      return List.generate(width, (xx) {
        final i = (y * width + xx) * 4;
        final lum = (px[i] + px[i + 1] + px[i + 2]) / 3;
        return lum < 128; // dark pixel => print
      });
    });
  }

  /// Draw a small filled 5-point star centered at [c].
  void _drawStar(Canvas canvas, Offset c, double r, Paint paint) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final radius = i.isEven ? r : r / 2.3;
      final angle = -pi / 2 + i * pi / 5;
      final p = c + Offset(cos(angle) * radius, sin(angle) * radius);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  // Code 39: 9 elements per char (bar/space alternating, starting with a bar);
  // 'n' = narrow (1 module), 'w' = wide (2 modules). Chars are wrapped in the
  // '*' start/stop guard and separated by a 1-module space.
  static const Map<String, String> _code39 = {
    '0': 'nnnwwnwnn', '1': 'wnnwnnnnw', '2': 'nnwwnnnnw', '3': 'wnwwnnnnn',
    '4': 'nnnwwnnnw', '5': 'wnnwwnnnn', '6': 'nnwwwnnnn', '7': 'nnnwnnwnw',
    '8': 'wnnwnnwnn', '9': 'nnwwnnwnn', '*': 'nwnnwnwnn',
  };

  List<(bool, int)> _code39Modules(String data) {
    final chars = '*$data*';
    final out = <(bool, int)>[];
    for (var ci = 0; ci < chars.length; ci++) {
      final pattern = _code39[chars[ci]]!;
      for (var i = 0; i < pattern.length; i++) {
        out.add((i.isEven, pattern[i] == 'w' ? 2 : 1));
      }
      if (ci != chars.length - 1) out.add((false, 1)); // inter-char gap
    }
    return out;
  }

  String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connected != null;
    return Scaffold(
      appBar: AppBar(title: const Text('NIIMBOT B1')),
      body: Column(
        children: [
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
                        (_busy || !connected) ? null : _printTestLabel,
                    icon: const Icon(Icons.print),
                    label: const Text('Print Test Label'),
                  ),
                ),
              ],
            ),
          ),
          if (connected)
            ListTile(
              leading: const Icon(Icons.bluetooth_connected,
                  color: Colors.teal),
              title: Text(_connected!.platformName),
              trailing: TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        await _connected?.disconnect();
                        setState(() {
                          _connected = null;
                          _printer = null;
                        });
                        _addLog('Disconnected.');
                      },
                child: const Text('Disconnect'),
              ),
            ),
          if (!connected)
            Expanded(
              flex: 2,
              child: ListView(
                children: _results
                    .map((r) => ListTile(
                          leading: const Icon(Icons.print_outlined),
                          title: Text(r.device.platformName),
                          subtitle: Text(r.device.remoteId.str),
                          trailing: Text('${r.rssi} dBm'),
                          onTap:
                              _busy ? null : () => _connect(r.device),
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
