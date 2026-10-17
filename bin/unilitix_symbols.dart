// Uploads Dart `--split-debug-info` symbol files to Unilitix so obfuscated
// release stack traces can be symbolicated on the server.
//
//   flutter build apk --release --obfuscate --split-debug-info=build/symbols
//   dart run unilitix:unilitix_symbols upload build/symbols \
//       --app-version 3.4.0 --build-number 120
//
// The API key is read from UNILITIX_API_KEY (preferred) or --api-key. It is
// never printed. Each `*.symbols` file is sent with the platform and
// architecture parsed from its name (`app.android-arm64.symbols`), plus the
// app version and build number the crash reports carry, so the server can
// pair a report's `buildId` with the right file.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _defaultApi = 'https://api.unilitix.com';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first != 'upload' || args.contains('--help')) {
    _usage();
    exit(args.contains('--help') ? 0 : 64);
  }
  final opts = _parse(args.sublist(1));
  final dir = opts.positional.isEmpty ? null : opts.positional.first;
  if (dir == null) {
    stderr.writeln('error: path to the --split-debug-info directory required');
    _usage();
    exit(64);
  }
  final apiKey =
      Platform.environment['UNILITIX_API_KEY'] ?? opts.named['api-key'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('error: set UNILITIX_API_KEY or pass --api-key');
    exit(64);
  }
  final appVersion = opts.named['app-version'];
  final buildNumber = opts.named['build-number'];
  if (appVersion == null || buildNumber == null) {
    stderr.writeln('error: --app-version and --build-number are required '
        '(the values your app reports; see pubspec.yaml `version`)');
    exit(64);
  }
  final apiUrl = opts.named['api-url'] ?? _defaultApi;

  final files = Directory(dir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.symbols'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stderr.writeln('error: no *.symbols files in $dir — build with '
        '--split-debug-info=$dir first');
    exit(66);
  }

  var failed = 0;
  for (final f in files) {
    final name = f.uri.pathSegments.last; // app.android-arm64.symbols
    final target = _targetOf(name);
    final req = http.MultipartRequest('POST', Uri.parse('$apiUrl/v1/symbols'))
      ..headers['x-unilitix-key'] = apiKey
      ..fields['platform'] = target.platform
      ..fields['arch'] = target.arch
      ..fields['appVersion'] = appVersion
      ..fields['buildNumber'] = buildNumber
      ..files.add(
          await http.MultipartFile.fromPath('symbols', f.path, filename: name));
    stdout.write('$name (${_human(f.lengthSync())}) … ');
    try {
      final streamed = await req.send().timeout(const Duration(minutes: 5));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        stdout.writeln('ok');
      } else if (resp.statusCode == 404) {
        stdout.writeln('skipped');
        stderr.writeln('  this API does not accept symbol uploads yet '
            '(HTTP 404 from $apiUrl/v1/symbols)');
        failed++;
      } else {
        stdout.writeln('failed');
        stderr.writeln('  HTTP ${resp.statusCode}: ${_trim(resp.body)}');
        failed++;
      }
    } catch (e) {
      stdout.writeln('failed');
      stderr.writeln('  ${e.runtimeType}');
      failed++;
    }
  }
  exit(failed == 0 ? 0 : 1);
}

class _Target {
  final String platform;
  final String arch;
  const _Target(this.platform, this.arch);
}

/// `app.android-arm64.symbols` → android / arm64; `app.ios-arm64.symbols`
/// → ios / arm64. Unknown names are sent as `unknown` so nothing is lost.
_Target _targetOf(String fileName) {
  final m = RegExp(r'\.([a-z]+)-([a-z0-9_]+)\.symbols$').firstMatch(fileName);
  if (m == null) return const _Target('unknown', 'unknown');
  return _Target(m.group(1)!, m.group(2)!);
}

class _Opts {
  final Map<String, String> named = {};
  final List<String> positional = [];
}

_Opts _parse(List<String> args) {
  final o = _Opts();
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--')) {
      final eq = a.indexOf('=');
      if (eq > 0) {
        o.named[a.substring(2, eq)] = a.substring(eq + 1);
      } else if (i + 1 < args.length) {
        o.named[a.substring(2)] = args[++i];
      }
    } else {
      o.positional.add(a);
    }
  }
  return o;
}

String _human(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _trim(String body) {
  final line = const LineSplitter().convert(body).firstOrNull ?? '';
  return line.length > 200 ? '${line.substring(0, 200)}…' : line;
}

void _usage() {
  stdout.writeln('''
Usage: dart run unilitix:unilitix_symbols upload <split-debug-info dir>
         --app-version <x.y.z> --build-number <n> [--api-url <url>] [--api-key <key>]

Uploads every *.symbols file in the directory. The key is read from the
UNILITIX_API_KEY environment variable when --api-key is not given.''');
}
