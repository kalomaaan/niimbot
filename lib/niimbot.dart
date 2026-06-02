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

  /// B1 printhead resolution in pixels (drives the per-row count chunking).
  static const int printheadPixels = 384;

  set mtu(int value) => _mtu = value;

  /// Print a 1-bit image. [rows] is row-major: rows[y][x] == true => black dot.
  /// Width (rows[y].length) must be a multiple of 8.
  ///
  /// Packet sequence matches niimbluelib's B1PrintTask exactly:
  ///   setDensity, setLabelType, printStart(7b),
  ///   pageStart, setPageSize(6b), <bitmap rows>, pageEnd, printEnd.
  /// Using the 1-byte printStart / 4-byte page size (the D11 forms) makes the
  /// B1 feed a *blank* label — which is what bit us the first time.
  Future<void> printImage(List<List<bool>> rows, {int density = 3}) async {
    final height = rows.length;
    final width = rows.isEmpty ? 0 : rows.first.length;

    _log('Init: density=$density, type=WithGaps, 7-byte printStart');
    await _send(NiimbotPacket(0x21, [density])); // SetDensity
    await _send(NiimbotPacket(0x23, [1])); // SetLabelType (1 = WithGaps)
    // printStart7b: totalPages=1 (u16 BE), 4 reserved zeros, pageColor=0.
    await _send(NiimbotPacket(0x01, [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]));

    await _send(NiimbotPacket(0x03, const [])); // PageStart (command only)
    // setPageSize6b: rows (height), cols (width), copies — big-endian u16 each.
    await _send(NiimbotPacket(0x13, [
      (height >> 8) & 0xFF, height & 0xFF, //
      (width >> 8) & 0xFF, width & 0xFF, //
      0x00, 0x01, // copies = 1
    ]));

    _log('Sending $height rows ($width px wide)...');
    for (var y = 0; y < height; y++) {
      await _send(_encodeRow(y, rows[y]));
    }

    await _send(NiimbotPacket(0xE3, const [])); // PageEnd (command only)
    await Future.delayed(const Duration(milliseconds: 300));
    await _send(NiimbotPacket(0xF3, const [])); // PrintEnd (command only)
    _log('Print job sent.');
  }

  /// Encode one image row into a 0x85 (PrintBitmapRow) packet.
  /// Bits are packed MSB-first: x=0 -> bit 7 of the first byte.
  /// Header: y (u16 BE), 3 black-pixel "part" counts, repeat = 1.
  /// The B1 needs the real per-third counts; zeros make it drop the row.
  NiimbotPacket _encodeRow(int y, List<bool> row) {
    final width = row.length;
    final lineBytes = Uint8List((width + 7) ~/ 8);
    for (var x = 0; x < width; x++) {
      if (row[x]) {
        lineBytes[x >> 3] |= 0x80 >> (x & 7);
      }
    }
    // Split the row into three equal byte-chunks and count set bits in each.
    final chunk = printheadPixels ~/ 8 ~/ 3; // 16 bytes for a 384px head
    final parts = <int>[0, 0, 0];
    for (var b = 0; b < lineBytes.length; b++) {
      final idx = chunk > 0 ? b ~/ chunk : 0;
      if (idx > 2) continue;
      parts[idx] += _popcount(lineBytes[b]);
    }
    for (var i = 0; i < 3; i++) {
      if (parts[i] > 255) parts[i] = 255;
    }
    final header = <int>[(y >> 8) & 0xFF, y & 0xFF, parts[0], parts[1], parts[2], 1];
    return NiimbotPacket(0x85, [...header, ...lineBytes]);
  }

  int _popcount(int v) {
    var c = 0;
    var x = v;
    while (x != 0) {
      c += x & 1;
      x >>= 1;
    }
    return c;
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
