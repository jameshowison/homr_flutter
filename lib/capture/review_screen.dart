import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'image_preprocessor.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.scanned});

  final File scanned;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
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
      final png = await preprocessImage(bytes);
      if (mounted) setState(() => _thresholdedPng = png);
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
            label: 'Scanned',
            child: Image.file(widget.scanned, fit: BoxFit.contain),
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
      child: Row(
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
    );
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
