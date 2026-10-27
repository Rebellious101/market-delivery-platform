import 'dart:convert';
import 'dart:io';

class LocalStorage {
  LocalStorage._();

  static final LocalStorage instance = LocalStorage._();

  Map<String, dynamic> _data = {};
  File? _storageFile;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final file = await _resolveStorageFile();
      _storageFile = file;
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is Map<String, dynamic>) {
            _data = decoded;
          }
        }
      }
    } catch (_) {
      _data = {};
    }
  }

  Future<File> _resolveStorageFile() async {
    final candidates = <Directory>[
      Directory('${Directory.systemTemp.parent.path}/app_flutter'),
      Directory('${Directory.systemTemp.parent.path}/files'),
      Directory('${Directory.systemTemp.parent.path}/Documents'),
      Directory('${Directory.systemTemp.path}/prestij_market_storage'),
    ];

    for (final dir in candidates) {
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        final testFile = File('${dir.path}/prestij_market_state.json');
        return testFile;
      } catch (_) {
        continue;
      }
    }

    return File('${Directory.systemTemp.path}/prestij_market_state.json');
  }

  dynamic read(String key) => _data[key];

  Future<void> write(String key, dynamic value) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    await _flush();
  }

  Future<void> remove(String key) async {
    _data.remove(key);
    await _flush();
  }

  Future<void> _flush() async {
    try {
      final file = _storageFile ?? await _resolveStorageFile();
      _storageFile = file;
      await file.writeAsString(jsonEncode(_data), flush: true);
    } catch (_) {}
  }
}

