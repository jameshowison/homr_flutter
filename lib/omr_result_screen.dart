import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'capture/crop_screen.dart';
import 'omr_orchestrator.dart';

class OmrResultScreen extends StatefulWidget {
  const OmrResultScreen({super.key, required this.cropResult});

  final CropResult cropResult;

  @override
  State<OmrResultScreen> createState() => _OmrResultScreenState();
}

class _OmrResultScreenState extends State<OmrResultScreen> {
  OmrStage? _stage;
  String? _musicXml;
  String? _error;
  bool _running = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _runOmr();
  }

  Future<void> _runOmr() async {
    try {
      final xml = await OmrOrchestrator().recognise(
        widget.cropResult.songBytes,
        onProgress: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
      );
      if (mounted) setState(() { _musicXml = xml; _running = false; });
    } on OmrException catch (e) {
      if (mounted) setState(() { _error = e.message; _running = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _running = false; });
    }
  }

  Future<void> _copyToClipboard() async {
    if (_musicXml == null) return;
    await Clipboard.setData(ClipboardData(text: _musicXml!));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('MusicXML copied to clipboard')));
    }
  }

  Future<void> _saveToFiles() async {
    final xml = _musicXml;
    if (xml == null) return;
    setState(() => _saving = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final name = 'score_${DateTime.now().millisecondsSinceEpoch}.musicxml';
      final file = File('${dir.path}/$name');
      await file.writeAsString(xml);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to Documents/$name')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recognition Result'),
        actions: _musicXml != null
            ? [
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy MusicXML',
                  onPressed: _copyToClipboard,
                ),
                IconButton(
                  icon: _saving
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_alt),
                  tooltip: 'Save to Files',
                  onPressed: _saving ? null : _saveToFiles,
                ),
              ]
            : null,
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_running) return _buildProgress(context);
    if (_error != null) return _buildError(context);
    return _buildResult(context);
  }

  Widget _buildProgress(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              _stageLabel(_stage),
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            _StageSteps(current: _stage),
          ],
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48,
                color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'Recognition failed',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResult(BuildContext context) {
    return Column(
      children: [
        _ResultSummary(xml: _musicXml!),
        const Divider(height: 1),
        Expanded(
          child: Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _musicXml!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Scan Again'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy XML'),
                  onPressed: _copyToClipboard,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _stageLabel(OmrStage? stage) => switch (stage) {
        OmrStage.segmenting => 'Segmenting image…',
        OmrStage.detecting => 'Detecting staves…',
        OmrStage.recognising => 'Recognising symbols…',
        OmrStage.assembling => 'Assembling MusicXML…',
        null => 'Starting…',
      };
}

// ── Supporting widgets ────────────────────────────────────────────────────────

class _StageSteps extends StatelessWidget {
  const _StageSteps({required this.current});

  final OmrStage? current;

  static const _stages = [
    (OmrStage.segmenting, 'Segment'),
    (OmrStage.detecting, 'Detect'),
    (OmrStage.recognising, 'Recognise'),
    (OmrStage.assembling, 'Assemble'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentIndex = _stages.indexWhere((s) => s.$1 == current);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (int i = 0; i < _stages.length; i++) ...[
            _StageChip(
              label: _stages[i].$2,
              done: i < currentIndex,
              active: i == currentIndex,
              theme: theme,
            ),
            if (i < _stages.length - 1)
              Container(
                width: 20,
                height: 1,
                color: i < currentIndex
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
              ),
          ],
        ],
      ),
    );
  }
}

class _StageChip extends StatelessWidget {
  const _StageChip({
    required this.label,
    required this.done,
    required this.active,
    required this.theme,
  });

  final String label;
  final bool done;
  final bool active;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final color = done || active
        ? theme.colorScheme.primary
        : theme.colorScheme.outlineVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done || active ? color : null,
            border: done || active ? null : Border.all(color: color),
          ),
          child: done
              ? Icon(Icons.check, size: 16, color: theme.colorScheme.onPrimary)
              : active
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: Padding(
                        padding: EdgeInsets.all(6),
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      ),
                    )
                  : null,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: color,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}

class _ResultSummary extends StatelessWidget {
  const _ResultSummary({required this.xml});

  final String xml;

  @override
  Widget build(BuildContext context) {
    // Count measures and notes for a quick summary.
    final measures = RegExp(r'<measure\b').allMatches(xml).length;
    final notes = RegExp(r'<note\b').allMatches(xml).length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          _Stat(label: 'Measures', value: '$measures'),
          const SizedBox(width: 24),
          _Stat(label: 'Notes', value: '$notes'),
          const Spacer(),
          Icon(Icons.check_circle,
              color: Theme.of(context).colorScheme.primary, size: 20),
          const SizedBox(width: 6),
          Text('MusicXML ready',
              style: TextStyle(color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
