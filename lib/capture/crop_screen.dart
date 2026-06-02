import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';

class CropResult {
  const CropResult({required this.songBytes, required this.titleBytes});
  final Uint8List songBytes;
  final Uint8List titleBytes;
}

class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.thresholdedPng});

  final Uint8List thresholdedPng;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  File? _sourceFile;
  Uint8List? _songBytes;
  Uint8List? _titleBytes;
  bool _saving = true;

  @override
  void initState() {
    super.initState();
    _saveSourceFile();
  }

  Future<void> _saveSourceFile() async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/homr_threshold_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(widget.thresholdedPng);
    if (mounted) setState(() { _sourceFile = file; _saving = false; });
  }

  Future<void> _cropSong() async {
    final source = _sourceFile;
    if (source == null) return;
    final cropped = await ImageCropper().cropImage(
      sourcePath: source.path,
      uiSettings: [
        IOSUiSettings(
          title: 'Song Area',
          doneButtonTitle: 'Done',
          cancelButtonTitle: 'Cancel',
          rotateButtonsHidden: true,
          resetButtonHidden: true,
          aspectRatioLockEnabled: false,
        ),
      ],
    );
    if (cropped == null || !mounted) return;
    final bytes = await cropped.readAsBytes();
    setState(() => _songBytes = bytes);
  }

  Future<void> _cropTitle() async {
    final source = _sourceFile;
    if (source == null) return;
    final cropped = await ImageCropper().cropImage(
      sourcePath: source.path,
      uiSettings: [
        IOSUiSettings(
          title: 'Title Area',
          doneButtonTitle: 'Done',
          cancelButtonTitle: 'Cancel',
          rotateButtonsHidden: true,
          resetButtonHidden: true,
          aspectRatioLockEnabled: false,
        ),
      ],
    );
    if (cropped == null || !mounted) return;
    final bytes = await cropped.readAsBytes();
    setState(() => _titleBytes = bytes);
  }

  void _continue() {
    final song = _songBytes;
    final title = _titleBytes;
    if (song == null || title == null) return;
    Navigator.of(context).pop(CropResult(songBytes: song, titleBytes: title));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Crop Regions')),
      body: _saving
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Image.memory(
                            widget.thresholdedPng,
                            fit: BoxFit.contain,
                          ),
                          const SizedBox(height: 20),
                          _CropStepCard(
                            step: 1,
                            title: 'Song area',
                            instruction:
                                'Crop tightly around the music — exclude the title.',
                            cropBytes: _songBytes,
                            onCrop: _cropSong,
                          ),
                          const SizedBox(height: 12),
                          if (_songBytes != null)
                            _CropStepCard(
                              step: 2,
                              title: 'Title area',
                              instruction:
                                  'Crop tightly around the title line.',
                              cropBytes: _titleBytes,
                              onCrop: _cropTitle,
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(null),
                            child: const Text('Start Over'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: (_songBytes != null && _titleBytes != null)
                                ? _continue
                                : null,
                            child: const Text('Continue'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _CropStepCard extends StatelessWidget {
  const _CropStepCard({
    required this.step,
    required this.title,
    required this.instruction,
    required this.cropBytes,
    required this.onCrop,
  });

  final int step;
  final String title;
  final String instruction;
  final Uint8List? cropBytes;
  final VoidCallback onCrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: theme.colorScheme.primary,
                  child: Text(
                    '$step',
                    style: TextStyle(
                      color: theme.colorScheme.onPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(instruction, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            if (cropBytes != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(cropBytes!, fit: BoxFit.contain),
              ),
              const SizedBox(height: 8),
            ],
            OutlinedButton(
              onPressed: onCrop,
              child: Text(cropBytes == null ? 'Select Area' : 'Re-select'),
            ),
          ],
        ),
      ),
    );
  }
}
