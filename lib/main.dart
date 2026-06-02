import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'capture/capture_screen.dart';
import 'capture/crop_screen.dart';
import 'capture/review_screen.dart';
import 'omr_result_screen.dart';

void main() {
  runApp(const HomrApp());
}

class HomrApp extends StatelessWidget {
  const HomrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Homr',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  CropResult? _lastCrop;

  Future<void> _openScanner() async {
    final file = await Navigator.push<File>(
      context,
      MaterialPageRoute(builder: (_) => const CaptureScreen()),
    );
    if (file == null || !mounted) return;

    final png = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(builder: (_) => ReviewScreen(scanned: file)),
    );
    if (png == null || !mounted) return;

    final crop = await Navigator.push<CropResult>(
      context,
      MaterialPageRoute(builder: (_) => CropScreen(thresholdedPng: png)),
    );
    if (crop == null || !mounted) return;
    setState(() => _lastCrop = crop);

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => OmrResultScreen(cropResult: crop)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Homr')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_lastCrop != null) ...[
                Text('Song', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                Image.memory(_lastCrop!.songBytes, height: 150),
                const SizedBox(height: 12),
                Text('Title', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                Image.memory(_lastCrop!.titleBytes, height: 80),
                const SizedBox(height: 24),
              ],
              FilledButton.icon(
                onPressed: _openScanner,
                icon: const Icon(Icons.document_scanner),
                label: Text(_lastCrop == null ? 'Scan Sheet Music' : 'Scan Again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
