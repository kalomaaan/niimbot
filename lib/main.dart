import 'dart:async';
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

  // Label canvas size. Width must be a multiple of 8. B1 head is ~384 px max;
  // 320 x 96 suits a small "hello world" test label.
  static const int labelWidth = 320;
  static const int labelHeight = 96;

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

  Future<void> _printHelloWorld() async {
    final printer = _printer;
    if (printer == null) return;
    setState(() => _busy = true);
    try {
      final rows = await _renderText('HELLO\nWORLD', labelWidth, labelHeight);
      await printer.printImage(rows);
    } catch (e) {
      _addLog('Print failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Rasterize centered text to a 1-bit grid. true => black (printed) dot.
  Future<List<List<bool>>> _renderText(
      String text, int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.center,
      fontSize: 40,
      fontWeight: FontWeight.bold,
    ))
      ..pushStyle(ui.TextStyle(color: const Color(0xFF000000)))
      ..addText(text);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: width.toDouble()));
    canvas.drawParagraph(
        paragraph, Offset(0, (height - paragraph.height) / 2));

    final image = await recorder.endRecording().toImage(width, height);
    final bytes =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final px = bytes!.buffer.asUint8List();

    return List.generate(height, (y) {
      return List.generate(width, (x) {
        final i = (y * width + x) * 4;
        final lum = (px[i] + px[i + 1] + px[i + 2]) / 3;
        return lum < 128; // dark pixel => print
      });
    });
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
                        (_busy || !connected) ? null : _printHelloWorld,
                    icon: const Icon(Icons.print),
                    label: const Text('Print Hello World'),
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
