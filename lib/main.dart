import 'dart:io';

import 'package:flutter/material.dart';

import 'capture/capture_screen.dart';

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
  File? _lastScan;

  Future<void> _openScanner() async {
    final file = await Navigator.push<File>(
      context,
      MaterialPageRoute(builder: (_) => const CaptureScreen()),
    );
    if (file != null) {
      setState(() => _lastScan = file);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Homr')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_lastScan != null) ...[
              Image.file(_lastScan!, height: 200),
              const SizedBox(height: 8),
              Text(
                _lastScan!.path.split('/').last,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
            ],
            FilledButton.icon(
              onPressed: _openScanner,
              icon: const Icon(Icons.document_scanner),
              label: Text(_lastScan == null ? 'Scan Sheet Music' : 'Scan Again'),
            ),
          ],
        ),
      ),
    );
  }
}
