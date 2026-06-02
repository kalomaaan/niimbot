import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// NIIMBOT serial-over-BLE service / characteristic.
/// Same UUIDs across D11/B21/B1 etc. The characteristic has
/// NOTIFY + WRITE_NO_RESPONSE properties.
final Guid niimbotService = Guid('e7810a71-73ae-499d-8c15-faa9aef0c3f2');
final Guid niimbotChar = Guid('bef8d6c9-9c21-4c9e-b632-bd58c1009f9f');

/// One NIIMBOT protocol packet:
///   55 55 | type | len | data... | checksum | AA AA
/// checksum = XOR of (type, len, every data byte).
class NiimbotPacket {
  final int type;
  final List<int> data;

  NiimbotPacket(this.type, this.data);

  Uint8List toBytes() {
    final len = data.length;
    int checksum = type ^ len;
    for (final b in data) {
      checksum ^= b;
    }
    final out = <int>[0x55, 0x55, type, len, ...data, checksum, 0xAA, 0xAA];
    return Uint8List.fromList(out);
  }
}

typedef LogFn = void Function(String message);

/// Drives a NIIMBOT printer over a single BLE characteristic.
class NiimbotPrinter {
  final BluetoothCharacteristic _char;
  final LogFn _log;
  int _mtu;

  NiimbotPrinter(this._char, {required LogFn log, int mtu = 23})
      : _log = log,
        _mtu = mtu;

  set mtu(int value) => _mtu = value;

  /// Print a 1-bit image. [rows] is row-major: rows[y][x] == true => black dot.
  /// Width (rows[y].length) must be a multiple of 8.
  Future<void> printImage(List<List<bool>> rows, {int density = 3}) async {
    final height = rows.length;
    final width = rows.isEmpty ? 0 : rows.first.length;

    _log('Configuring: density=$density, label type=1');
    await _send(NiimbotPacket(0x21, [density])); // SET_LABEL_DENSITY
    await _send(NiimbotPacket(0x23, [1])); // SET_LABEL_TYPE (1 = gap/with-gaps)
    await _send(NiimbotPacket(0x01, [1])); // START_PRINT
    await _send(NiimbotPacket(0x03, [1])); // START_PAGE_PRINT

    // SET_DIMENSION: rows (height) then cols (width), big-endian u16 each.
    await _send(NiimbotPacket(0x13, [
      (height >> 8) & 0xFF,
      height & 0xFF,
      (width >> 8) & 0xFF,
      width & 0xFF,
    ]));

    _log('Sending $height rows ($width px wide)...');
    for (var y = 0; y < height; y++) {
      await _send(_encodeRow(y, rows[y]));
    }

    await _send(NiimbotPacket(0xE3, [1])); // END_PAGE_PRINT
    await Future.delayed(const Duration(milliseconds: 300));
    await _send(NiimbotPacket(0xF3, [1])); // END_PRINT
    _log('Print job sent.');
  }

  /// Encode one image row into a 0x85 (PrintBitmapRow) packet.
  /// Bits are packed MSB-first: x=0 -> bit 7 of the first byte.
  NiimbotPacket _encodeRow(int y, List<bool> row) {
    final width = row.length;
    final lineBytes = Uint8List((width + 7) ~/ 8);
    for (var x = 0; x < width; x++) {
      if (row[x]) {
        lineBytes[x >> 3] |= 0x80 >> (x & 7);
      }
    }
    // Header: y (u16 BE), 3 "black count" bytes (0 is accepted), repeat = 1.
    final header = <int>[(y >> 8) & 0xFF, y & 0xFF, 0, 0, 0, 1];
    return NiimbotPacket(0x85, [...header, ...lineBytes]);
  }

  /// Write a packet, splitting across the negotiated MTU. The printer
  /// reassembles the byte stream by the 55 55 ... AA AA framing, so chunking
  /// mid-packet is safe.
  Future<void> _send(NiimbotPacket packet) async {
    final bytes = packet.toBytes();
    final chunk = (_mtu - 3).clamp(20, 512);
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = (i + chunk < bytes.length) ? i + chunk : bytes.length;
      await _char.write(bytes.sublist(i, end), withoutResponse: true);
      await Future.delayed(const Duration(milliseconds: 8));
    }
  }
}
