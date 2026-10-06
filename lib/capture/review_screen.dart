import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:homr_flutter/homr_flutter.dart';
import 'package:homr_flutter/preprocessing.dart';
import 'package:path_provider/path_provider.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.scanned});

  final File scanned;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  Uint8List? _originalPng;
  Uint8List? _thresholdedPng;
  String? _error;

  @override
  void initState() {
    super.initState();
    _runPreprocess();
  }

  Future<void> _runPreprocess() async {
    try {
      final bytes = await widget.scanned.readAsBytes();
      final result = await preprocessImage(bytes);
      if (mounted) {
        setState(() {
          _originalPng = result.original;
          _thresholdedPng = result.thresholded;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Review Scan')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildImages(context)),
            _buildActions(context),
          ],
        ),
      ),
    );
  }

  Widget _buildImages(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ScanPreview(
            label: 'Original (1920 px)',
            child: _originalPng != null
                ? Image.memory(_originalPng!, fit: BoxFit.contain)
                : const AspectRatio(
                    aspectRatio: 1.5,
                    child: Center(child: CircularProgressIndicator()),
                  ),
          ),
          const SizedBox(height: 12),
          _ScanPreview(
            label: 'Thresholded (B&W)',
            child: _buildThresholded(),
          ),
        ],
      ),
    );
  }

  Widget _buildThresholded() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Processing error: $_error',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    if (_thresholdedPng == null) {
      return const AspectRatio(
        aspectRatio: 1.5,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Image.memory(_thresholdedPng!, fit: BoxFit.contain);
  }

  Widget _buildActions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('Scan Again'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _thresholdedPng == null
                      ? null
                      : () => Navigator.of(context).pop(_thresholdedPng),
                  child: const Text('Continue'),
                ),
              ),
            ],
          ),
          if (!kReleaseMode) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _thresholdedPng == null ? null : () => _saveForTesting(context),
                icon: const Icon(Icons.save_alt, size: 16),
                label: const Text('Save for testing'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _saveForTesting(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final nameController = TextEditingController(
      text: 'scan_${DateTime.now().millisecondsSinceEpoch}',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save test images'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Base name (without .png)',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              onSubmitted: (_) => Navigator.of(ctx).pop(true),
            ),
            const SizedBox(height: 8),
            Text(
              'Saves {name}.png (colour) and {name}_bw.png (thresholded)',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Save')),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final name = nameController.text.trim().replaceAll(RegExp(r'[^\w\-]'), '_');
    if (name.isEmpty) return;

    try {
      final dir = await getApplicationDocumentsDirectory();

      final colourFile = File('${dir.path}/$name.png');
      await colourFile.writeAsBytes(_originalPng!);

      final bwFile = File('${dir.path}/${name}_bw.png');
      await bwFile.writeAsBytes(_thresholdedPng!);

      // ignore: avoid_print
      print('[SaveForTesting] colour: ${colourFile.path}');
      // ignore: avoid_print
      print('[SaveForTesting] bw:     ${bwFile.path}');

      messenger.showSnackBar(
        SnackBar(
          content: Text('Saved $name.png and ${name}_bw.png to Documents'),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }
}

class _ScanPreview extends StatelessWidget {
  const _ScanPreview({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: child,
        ),
      ],
    );
  }
}
