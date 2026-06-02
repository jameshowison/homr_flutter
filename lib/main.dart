import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'capture/capture_screen.dart';
import 'capture/review_screen.dart';

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
  Uint8List? _lastThresholded;

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
    if (png != null) setState(() => _lastThresholded = png);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Homr')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_lastThresholded != null) ...[
              Image.memory(_lastThresholded!, height: 200),
              const SizedBox(height: 24),
            ],
            FilledButton.icon(
              onPressed: _openScanner,
              icon: const Icon(Icons.document_scanner),
              label: Text(_lastThresholded == null ? 'Scan Sheet Music' : 'Scan Again'),
            ),
          ],
        ),
      ),
    );
  }
}
