import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Publica el núcleo de esta canción para que el hilo Rust
/// (`master_rewrite`, karaoke) se ancle al leer `GMX_MASTER_CORE`.
class MasterAffinity {
  static const String envKey = 'GMX_MASTER_CORE';

  static void publish(int core) {
    try {
      _set(envKey, '$core');
    } catch (e) {
      debugPrint('MASTER afinidad no publicada: $e');
    }
  }

  static void clear() {
    try {
      _set(envKey, '');
    } catch (e) {
      debugPrint('MASTER afinidad no limpiada: $e');
    }
  }

  /// Lo que quedó publicado. Null si está vacío o no es un número.
  static int? current() {
    try {
      final String? raw = _get(envKey);
      if (raw == null || raw.isEmpty) return null;
      return int.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  static void _set(String key, String value) {
    if (Platform.isWindows) {
      final Pointer<Utf16> k = key.toNativeUtf16();
      final Pointer<Utf16> v = value.toNativeUtf16();
      try {
        _kernel()
            .lookupFunction<
              Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
              int Function(Pointer<Utf16>, Pointer<Utf16>)
            >('SetEnvironmentVariableW')(k, v);
      } finally {
        malloc.free(k);
        malloc.free(v);
      }
      return;
    }
    final Pointer<Utf8> k = key.toNativeUtf8();
    final Pointer<Utf8> v = value.toNativeUtf8();
    try {
      _libc()
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('setenv')(k, v, 1);
    } finally {
      malloc.free(k);
      malloc.free(v);
    }
  }

  static String? _get(String key) {
    if (Platform.isWindows) {
      final Pointer<Utf16> k = key.toNativeUtf16();
      final Pointer<Uint16> buf = calloc<Uint16>(32767);
      try {
        final int n = _kernel()
            .lookupFunction<
              Uint32 Function(Pointer<Utf16>, Pointer<Uint16>, Uint32),
              int Function(Pointer<Utf16>, Pointer<Uint16>, int)
            >('GetEnvironmentVariableW')(k, buf, 32767);
        if (n == 0) return null;
        return buf.cast<Utf16>().toDartString();
      } finally {
        malloc.free(k);
        calloc.free(buf);
      }
    }
    final Pointer<Utf8> k = key.toNativeUtf8();
    try {
      final Pointer<Utf8> p = _libc()
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)
          >('getenv')(k);
      if (p == nullptr) return null;
      return p.toDartString();
    } finally {
      malloc.free(k);
    }
  }

  static DynamicLibrary _libc() => DynamicLibrary.process();

  static DynamicLibrary _kernel() => DynamicLibrary.open('kernel32.dll');
}
