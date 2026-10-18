import 'dart:convert' show utf8;

import 'sha256.dart';

/// Limits for power-outage contribution. Identical to the Android
/// implementation in `PowerSignals.java`.
abstract final class PowerLimits {
  /// Events kept on the device; the oldest are dropped first.
  static const int maxQueued = 500;

  /// Events per `POST /v1/signals/power`.
  static const int maxEventsPerRequest = 200;

  /// Events older than this are dropped, never sent.
  static const Duration maxEventAge = Duration(hours: 48);

  /// Events stamped further in the future than this (bad clock) are dropped.
  static const Duration maxClockSkew = Duration(minutes: 5);

  /// A location fix older than this is not used for a cell.
  static const Duration maxLocationAge = Duration(hours: 24);

  /// The same transition recorded twice within this window is one event.
  static const Duration dedupeWindow = Duration(seconds: 2);

  /// H3 resolution of the cell sent with each request (~5 km²).
  static const int h3Resolution = 7;
}

/// One charging observation.
///
/// Stored as a single line, `type,epochMillis[,0|1]`, the same format the
/// Android receiver writes, so both platforms share one set of rules.
class PowerSignal {
  /// `connect`, `disconnect` or `sample`.
  final String type;
  final int tsMs;

  /// Only for `sample`: whether the device was plugged in.
  final bool? charging;

  const PowerSignal._(this.type, this.tsMs, this.charging);

  const PowerSignal.connect(int tsMs) : this._('connect', tsMs, null);
  const PowerSignal.disconnect(int tsMs) : this._('disconnect', tsMs, null);
  const PowerSignal.sample(int tsMs, {required bool charging})
      : this._('sample', tsMs, charging);

  String toLine() =>
      charging == null ? '$type,$tsMs' : '$type,$tsMs,${charging! ? 1 : 0}';

  /// Null for anything malformed.
  static PowerSignal? parse(String line) {
    final p = line.split(',');
    if (p.length < 2) return null;
    final ts = int.tryParse(p[1]);
    if (ts == null) return null;
    switch (p[0]) {
      case 'connect':
        return p.length == 2 ? PowerSignal.connect(ts) : null;
      case 'disconnect':
        return p.length == 2 ? PowerSignal.disconnect(ts) : null;
      case 'sample':
        if (p.length != 3 || (p[2] != '0' && p[2] != '1')) return null;
        return PowerSignal.sample(ts, charging: p[2] == '1');
      default:
        return null;
    }
  }

  /// Wire form: `{"type": "disconnect", "ts": "..."}` or
  /// `{"type": "sample", "charging": true, "ts": "..."}`.
  Map<String, dynamic> toJson() => {
        'type': type,
        if (charging != null) 'charging': charging,
        'ts': DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true)
            .toIso8601String(),
      };

  bool isLive(int nowMs) =>
      tsMs >= nowMs - PowerLimits.maxEventAge.inMilliseconds &&
      tsMs <= nowMs + PowerLimits.maxClockSkew.inMilliseconds;
}

/// The on-device queue of power signals (iOS; Android keeps the same lines
/// in a file written by its broadcast receiver). Pure logic: persistence is
/// the caller's, via [lines].
class PowerSignalQueue {
  final List<String> _lines;

  PowerSignalQueue([List<String>? lines]) : _lines = [...?lines];

  List<String> get lines => List.unmodifiable(_lines);

  int get length => _lines.length;

  bool get isEmpty => _lines.isEmpty;

  /// Adds [s], dropping a transition that repeats the previous one within
  /// [PowerLimits.dedupeWindow], and keeping the newest
  /// [PowerLimits.maxQueued]. Returns whether it was added.
  bool add(PowerSignal s) {
    if (_lines.isNotEmpty && s.type != 'sample') {
      final last = PowerSignal.parse(_lines.last);
      if (last != null &&
          last.type == s.type &&
          (last.tsMs - s.tsMs).abs() <
              PowerLimits.dedupeWindow.inMilliseconds) {
        return false;
      }
    }
    _lines.add(s.toLine());
    if (_lines.length > PowerLimits.maxQueued) {
      _lines.removeRange(0, _lines.length - PowerLimits.maxQueued);
    }
    return true;
  }

  /// Drops malformed lines and everything outside the 48 h window.
  void prune(int nowMs) {
    _lines.removeWhere((l) => !(PowerSignal.parse(l)?.isLive(nowMs) ?? false));
  }

  /// Live signals, oldest first, in requests of at most
  /// [PowerLimits.maxEventsPerRequest].
  List<List<PowerSignal>> batches(int nowMs) {
    final live = <PowerSignal>[];
    for (final l in _lines) {
      final s = PowerSignal.parse(l);
      if (s != null && s.isLive(nowMs)) live.add(s);
    }
    live.sort((a, b) => a.tsMs.compareTo(b.tsMs));
    const n = PowerLimits.maxEventsPerRequest;
    final out = <List<PowerSignal>>[];
    for (var i = 0; i < live.length; i += n) {
      out.add(live.sublist(i, i + n < live.length ? i + n : live.length));
    }
    return out;
  }

  /// Removes one queued line per signal in [done] (delivered or rejected).
  void remove(Iterable<PowerSignal> done) {
    for (final s in done) {
      _lines.remove(s.toLine());
    }
  }

  void clear() => _lines.clear();

  /// Replaces the contents with persisted [lines] (newest [PowerLimits.maxQueued]).
  void replaceAll(List<String> lines) {
    _lines
      ..clear()
      ..addAll(lines.length > PowerLimits.maxQueued
          ? lines.sublist(lines.length - PowerLimits.maxQueued)
          : lines);
  }
}

/// The request's `device`: the first 32 hex characters (128 bits) of
/// SHA-256("unilitix-power-v1|installId|salt|yyyy-MM-dd"), the date in UTC.
///
/// It changes every UTC day, so the server can count distinct devices in a
/// cell on a day but cannot follow a device across days. The salt is random,
/// generated on the device and never sent, so the server cannot recompute
/// it from the install id it receives with analytics sessions.
String powerDeviceHash(String installId, String salt, DateTime now) {
  final d = now.toUtc();
  final date = '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  return sha256Hex(utf8.encode('unilitix-power-v1|$installId|$salt|$date'))
      .substring(0, 32);
}

/// Request body for `POST /v1/signals/power`.
Map<String, dynamic> powerRequestBody(
        String cell, String device, List<PowerSignal> events) =>
    {
      'cell': cell,
      'device': device,
      'events': [for (final e in events) e.toJson()],
    };
