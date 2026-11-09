import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef DownloadProgressCallback =
    void Function(int downloadedBytes, int totalBytes, double speedBytesPerSec);

class DownloadController {
  bool _isCancelled = false;
  bool _isPaused = false;
  HttpClientRequest? _activeRequest;
  IOSink? _activeSink;

  bool get isCancelled => _isCancelled;
  bool get isPaused => _isPaused;

  void pause() {
    _isPaused = true;
    try {
      _activeRequest?.abort();
    } catch (_) {}
    try {
      _activeSink?.close();
    } catch (_) {}
  }

  void cancel() {
    _isCancelled = true;
    try {
      _activeRequest?.abort();
    } catch (_) {}
    try {
      _activeSink?.close();
    } catch (_) {}
  }
}

class DownloadService {
  static Future<Directory> getDownloadsDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final newDir = Directory(p.join(docs.path, 'CCloudPlusDownloads'));
    final legacyDir = Directory(p.join(docs.path, 'CinevexDownloads'));

    // Migrate from legacy folder if present
    if (await legacyDir.exists() && !await newDir.exists()) {
      try {
        await legacyDir.rename(newDir.path);
      } catch (_) {
        return legacyDir;
      }
    }

    if (!await newDir.exists()) {
      await newDir.create(recursive: true);
    }
    return newDir;
  }

  static String sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  static Future<void> downloadFile({
    required String url,
    required String destinationPath,
    required DownloadController controller,
    required DownloadProgressCallback onProgress,
  }) async {
    final partFilePath = '$destinationPath.part';
    final partFile = File(partFilePath);
    int existingBytes = 0;

    if (await partFile.exists()) {
      existingBytes = await partFile.length();
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);

    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);
      controller._activeRequest = request;

      if (existingBytes > 0) {
        request.headers.add(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
      }

      final response = await request.close();

      int totalBytes = existingBytes;
      if (response.statusCode == HttpStatus.partialContent) {
        // 206 Partial Content
        final contentLength = response.contentLength;
        if (contentLength > 0) {
          totalBytes = existingBytes + contentLength;
        }
      } else if (response.statusCode == HttpStatus.ok) {
        // Server doesn't support range or starting fresh
        existingBytes = 0;
        totalBytes = response.contentLength > 0 ? response.contentLength : 0;
        if (await partFile.exists()) {
          await partFile.delete();
        }
      } else {
        throw HttpException(
          'HTTP Error ${response.statusCode}: ${response.reasonPhrase}',
          uri: uri,
        );
      }

      final sink = partFile.openWrite(
        mode: existingBytes > 0 ? FileMode.append : FileMode.write,
      );
      controller._activeSink = sink;

      int currentBytes = existingBytes;
      DateTime lastSampleTime = DateTime.now();
      int bytesSinceSample = 0;
      double currentSpeed = 0.0;

      await for (final chunk in response) {
        if (controller.isCancelled || controller.isPaused) {
          break;
        }

        sink.add(chunk);
        currentBytes += chunk.length;
        bytesSinceSample += chunk.length;

        final now = DateTime.now();
        final elapsed = now.difference(lastSampleTime).inMilliseconds;
        if (elapsed >= 500) {
          currentSpeed = (bytesSinceSample * 1000.0) / elapsed;
          lastSampleTime = now;
          bytesSinceSample = 0;

          onProgress(currentBytes, totalBytes, currentSpeed);
        }
      }

      await sink.flush();
      await sink.close();

      if (controller.isCancelled) {
        if (await partFile.exists()) {
          await partFile.delete();
        }
        return;
      }

      if (controller.isPaused) {
        return;
      }

      // Final progress update
      onProgress(currentBytes, totalBytes, 0.0);

      // Rename .part to final destination
      final finalFile = File(destinationPath);
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await partFile.rename(destinationPath);
    } finally {
      try {
        await controller._activeSink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }
}
