import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// `SHGetKnownFolderPath(FOLDERID_Music)`.
///
/// `package:win32` 6.4.0 declara `platforms: windows` y un app de cuatro
/// plataformas no puede depender de él. La llamada es la misma, vía FFI,
/// y solo abre `shell32.dll` cuando el proceso es Windows.
final class _KnownFolderGuid extends Struct {
  @Uint32()
  external int data1;

  @Uint16()
  external int data2;

  @Uint16()
  external int data3;

  @Uint8()
  external int b0;

  @Uint8()
  external int b1;

  @Uint8()
  external int b2;

  @Uint8()
  external int b3;

  @Uint8()
  external int b4;

  @Uint8()
  external int b5;

  @Uint8()
  external int b6;

  @Uint8()
  external int b7;
}

typedef _SHGetKnownFolderPathNative =
    Int32 Function(
      Pointer<_KnownFolderGuid> rfid,
      Uint32 dwFlags,
      Pointer hToken,
      Pointer<Pointer<Utf16>> ppszPath,
    );
typedef _SHGetKnownFolderPathDart =
    int Function(
      Pointer<_KnownFolderGuid> rfid,
      int dwFlags,
      Pointer hToken,
      Pointer<Pointer<Utf16>> ppszPath,
    );
typedef _CoTaskMemFreeNative = Void Function(Pointer pv);
typedef _CoTaskMemFreeDart = void Function(Pointer pv);
typedef _CoInitializeExNative =
    Int32 Function(Pointer pvReserved, Uint32 dwCoInit);
typedef _CoInitializeExDart = int Function(Pointer pvReserved, int dwCoInit);

const int _coInitApartmentThreaded = 0x2;

/// FOLDERID_Music `{4BD8D571-6D19-48D3-BE97-422220080E43}`.
Pointer<_KnownFolderGuid> _musicGuid() {
  final Pointer<_KnownFolderGuid> guid = calloc<_KnownFolderGuid>();
  guid.ref.data1 = 0x4BD8D571;
  guid.ref.data2 = 0x6D19;
  guid.ref.data3 = 0x48D3;
  guid.ref.b0 = 0xBE;
  guid.ref.b1 = 0x97;
  guid.ref.b2 = 0x42;
  guid.ref.b3 = 0x22;
  guid.ref.b4 = 0x20;
  guid.ref.b5 = 0x08;
  guid.ref.b6 = 0x0E;
  guid.ref.b7 = 0x43;
  return guid;
}

String? _readPath(
  _SHGetKnownFolderPathDart getPath,
  _CoTaskMemFreeDart freeMem,
) {
  final Pointer<_KnownFolderGuid> guid = _musicGuid();
  final Pointer<Pointer<Utf16>> out = calloc<Pointer<Utf16>>();
  try {
    final int hr = getPath(guid, 0, nullptr, out);
    if (hr != 0 || out.value == nullptr) return null;
    final String path = out.value.toDartString();
    freeMem(out.value);
    if (path.isEmpty) return null;
    return path;
  } finally {
    calloc.free(guid);
    calloc.free(out);
  }
}

/// Ruta real de Música, también si OneDrive o el usuario la movieron.
/// Null si la API falla: el llamador usa el respaldo histórico.
String? windowsKnownMusicFolder() {
  if (!Platform.isWindows) return null;
  try {
    final DynamicLibrary shell = DynamicLibrary.open('shell32.dll');
    final DynamicLibrary ole = DynamicLibrary.open('ole32.dll');
    final _SHGetKnownFolderPathDart getPath = shell
        .lookupFunction<_SHGetKnownFolderPathNative, _SHGetKnownFolderPathDart>(
          'SHGetKnownFolderPath',
        );
    final _CoTaskMemFreeDart freeMem = ole
        .lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFreeDart>(
          'CoTaskMemFree',
        );
    final String? first = _readPath(getPath, freeMem);
    if (first != null) return first;
    final _CoInitializeExDart coInit = ole
        .lookupFunction<_CoInitializeExNative, _CoInitializeExDart>(
          'CoInitializeEx',
        );
    coInit(nullptr, _coInitApartmentThreaded);
    return _readPath(getPath, freeMem);
  } catch (_) {
    return null;
  }
}

/// Respaldo histórico: `%USERPROFILE%\Music`, o `C:\Music`.
String legacyWindowsMusicFolder() {
  final String? userProfile = Platform.environment['USERPROFILE'];
  if (userProfile != null && userProfile.isNotEmpty) {
    return '$userProfile\\Music';
  }
  return r'C:\Music';
}
