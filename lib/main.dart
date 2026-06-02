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

  // Paper hardcoded to 45 x 15 mm. B1 = 203 dpi = 8 dots/mm:
  //   width  = 45 mm * 8 = 360 px (across the printhead)
  //   height = 15 mm * 8 = 120 px (feed direction)
  static const int labelWidth = 360;
  static const int labelHeight = 120;

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
      client.startHeartbeat();
      setState(() {
        _client = client;
        _connected = true;
        _deviceName = result.deviceName ?? device.platformName;
      });
      _addLog('Connected: ${result.deviceName ?? device.platformName}. Model auto-detected.');
    } catch (e) {
      _addLog('Connect failed: $e');
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
      // Random numeric payload for the barcode.
      final rnd = Random();
      final code =
          List.generate(8, (_) => rnd.nextInt(10).toString()).join();
      _addLog('Barcode: $code');

      final page = PrintPage(labelWidth, labelHeight);

      // A star in each corner — confirms the printer detected the full
      // 45 x 15 mm label area.
      await page.addText('*',
          const TextOptions(x: 12, y: 8, fontSize: 22, align: HAlignment.left, vAlign: VAlignment.top));
      await page.addText('*',
          const TextOptions(x: labelWidth - 12, y: 8, fontSize: 22, align: HAlignment.right, vAlign: VAlignment.top));
      await page.addText('*',
          const TextOptions(x: 12, y: labelHeight - 8, fontSize: 22, align: HAlignment.left, vAlign: VAlignment.bottom));
      await page.addText('*',
          const TextOptions(x: labelWidth - 12, y: labelHeight - 8, fontSize: 22, align: HAlignment.right, vAlign: VAlignment.bottom));

      // Code 128 barcode (bars only) ...
      page.addBarcode(
        code,
        const BarcodeOptions(
          encoding: BarcodeEncoding.code128,
          x: labelWidth ~/ 2,
          y: 30,
          width: 250,
          height: 46,
          align: HAlignment.center,
          vAlign: VAlignment.top,
        ),
      );
      // ... with the human-readable number printed underneath.
      await page.addText(
        code,
        const TextOptions(
          x: labelWidth ~/ 2,
          y: 96,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          align: HAlignment.center,
          vAlign: VAlignment.middle,
        ),
      );

      // The library handles the full B1 handshake + encoding internally.
      client.stopHeartbeat();
      client.packetIntervalMs = 0;
      final task = client.createPrintTask(const PrintOptions(
        totalPages: 1,
        density: 3,
        labelType: LabelType.withGaps,
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

  @override
  void dispose() {
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
              trailing: TextButton(
                onPressed: _busy ? null : _disconnect,
                child: const Text('Disconnect'),
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
