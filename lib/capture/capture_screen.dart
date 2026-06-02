import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_doc_scanner/flutter_doc_scanner.dart';
import 'package:path_provider/path_provider.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  bool _scanning = false;
  String? _error;

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
    });

    try {
      final result = await FlutterDocScanner().getScannedDocumentAsImages(
        page: 1,
        imageFormat: ImageFormat.jpeg,
      );

      if (!mounted) return;

      if (result == null || result.images.isEmpty) {
        // User cancelled.
        setState(() => _scanning = false);
        return;
      }

      final file = await _resolveToFile(result.images.first);
      if (mounted) Navigator.of(context).pop(file);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = e.message ?? e.code;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = e.toString();
      });
    }
  }

  /// On iOS the scanner returns a direct file path; on Android it returns a
  /// content:// URI. Copy to the app cache dir so the rest of the pipeline
  /// always receives a regular File.
  Future<File> _resolveToFile(String path) async {
    if (!path.startsWith('content://')) return File(path);

    final bytes = await _readContentUri(path);
    final dir = await getTemporaryDirectory();
    final dest = File('${dir.path}/scan_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await dest.writeAsBytes(bytes);
    return dest;
  }

  static const _channel = MethodChannel('dev.homr/content_resolver');

  Future<Uint8List> _readContentUri(String uri) async {
    final bytes = await _channel.invokeMethod<Uint8List>('readBytes', {'uri': uri});
    if (bytes == null) throw Exception('Failed to read content URI: $uri');
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Sheet Music')),
      body: Center(
        child: _scanning
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Opening scanner…'),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null) ...[
                    Text(
                      'Scanner error: $_error',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                  ],
                  FilledButton.icon(
                    onPressed: _scan,
                    icon: const Icon(Icons.document_scanner),
                    label: const Text('Scan'),
                  ),
                ],
              ),
      ),
    );
  }
}
