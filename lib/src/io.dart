import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'patch_file.dart';

bool get isSupported => Platform.isAndroid || Platform.isIOS;

String get operatingSystem => Platform.operatingSystem;

/// A failed transfer; a later retry may succeed.
class PayloadDownloadException implements Exception {
  const PayloadDownloadException();
  @override
  String toString() => 'Patch download failed';
}

/// Plain HTTP to a LAN address, for development only: build with
/// `--dart-define=FLUTTER_PATCHER_INSECURE_HTTP=true`. A patch is executable
/// code, so on a network others can join, plain HTTP lets them choose what
/// the app runs. A release build leaves this off.
const allowInsecureHttp = bool.fromEnvironment(
  'FLUTTER_PATCHER_INSECURE_HTTP',
);

/// The RFC 1918 addresses a development machine and a phone share on a LAN.
bool isPrivateHost(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
    octets.add(value);
  }
  return octets[0] == 10 ||
      (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] == 192 && octets[1] == 168);
}

/// HTTPS, or HTTP to this device itself, where `flutter_patcher serve` is
/// reached through adb reverse. A build that opted in with
/// [allowInsecureHttp] also takes HTTP to a LAN address. Redirects and
/// ambient credentials are deliberately unsupported so a response cannot
/// send a download elsewhere.
Uri updateUri(String url) {
  final uri = Uri.parse(url);
  final local =
      uri.scheme == 'http' &&
      const {'127.0.0.1', '::1', 'localhost'}.contains(uri.host);
  final lan =
      allowInsecureHttp && uri.scheme == 'http' && isPrivateHost(uri.host);
  if (!(uri.scheme == 'https' || local || lan) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException(
      'Patch downloads require HTTPS without URL credentials',
    );
  }
  return uri;
}

/// The first [patchHeaderSize] bytes of the patch file at [url], or null when there is
/// none (404). Asks for just that range; a server that sends the whole file
/// is read no further.
Future<Uint8List?> readPatchHeader(
  String url, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final uri = updateUri(url);
  final client = HttpClient()..connectionTimeout = timeout;
  Future<Uint8List?> read() async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=0-${patchHeaderSize - 1}',
    );
    final response = await request.close();
    if (response.statusCode == HttpStatus.notFound) {
      await response.drain<void>();
      return null;
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('Patch check got HTTP ${response.statusCode}');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length >= patchHeaderSize) break;
    }
    if (bytes.length < patchHeaderSize) {
      throw const FormatException('Not a patch file');
    }
    return Uint8List.sublistView(bytes.takeBytes(), 0, patchHeaderSize);
  }

  try {
    return await read().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

File _payloadFile() => File(
  '${Directory.systemTemp.path}/flutter_patcher-'
  '${DateTime.now().microsecondsSinceEpoch}.fptc',
);

/// Downloads the patch file of [size] bytes to a new temporary file for
/// native verification. Never more than [size] bytes, and within two minutes.
Future<String> downloadPayload(
  String url,
  int size,
  void Function(int received) progress,
) async {
  final uri = updateUri(url);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final file = _payloadFile();
  final sink = file.openWrite();
  try {
    await () async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      // A compressed body's length is not the payload's; the size bound and
      // native digest check the decoded bytes.
      final identity =
          (response.headers.value(HttpHeaders.contentEncodingHeader) ??
                  'identity')
              .toLowerCase() ==
          'identity';
      if (response.statusCode != 200 ||
          (identity &&
              response.contentLength != -1 &&
              response.contentLength != size)) {
        throw const PayloadDownloadException();
      }
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        received += chunk.length;
        if (received > size) throw const PayloadDownloadException();
        sink.add(chunk);
        progress(received);
      }
      if (received != size) throw const PayloadDownloadException();
      await sink.flush();
    }().timeout(const Duration(seconds: 120));
    await sink.close();
    return file.path;
  } catch (_) {
    await sink.close().catchError((_) {});
    await deletePayload(file.path);
    throw const PayloadDownloadException();
  } finally {
    client.close(force: true);
  }
}

/// A patch file the app obtained itself, written for native verification.
Future<String> writePayload(List<int> bytes) async {
  final file = _payloadFile();
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Future<void> deletePayload(String path) async {
  try {
    await File(path).delete();
  } on FileSystemException {
    // Already gone.
  }
}
