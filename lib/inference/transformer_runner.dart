import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import 'encoded_symbol.dart';
import 'vocabulary.dart';

class TransformerRunner {
  static const String _encoderAsset =
      'assets/models/encoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9_fp16.onnx';
  static const String _decoderAsset =
      'assets/models/decoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9_fp16.onnx';

  static const int _encoderH = 256;
  static const int _encoderW = 1280;
  static const double _normMean = 0.7931;
  static const double _normStd = 0.1738;

  static const int _decoderDepth = 8;
  static const int _decoderHeads = 8;
  static const int _headDim = 64;
  static const int _numCacheTensors = _decoderDepth * 4; // 32
  static const int _maxSteps = 608;

  static OrtSession? _encoderSession;
  static OrtSession? _decoderSession;

  static Future<OrtSession> _getEncoderSession() async {
    _encoderSession ??=
        await OnnxRuntime().createSessionFromAsset(_encoderAsset);
    return _encoderSession!;
  }

  static Future<OrtSession> _getDecoderSession() async {
    _decoderSession ??=
        await OnnxRuntime().createSessionFromAsset(_decoderAsset);
    return _decoderSession!;
  }

  /// Letterbox image to fit within [_encoderH] x [_encoderW] preserving
  /// aspect ratio, padding with white (255).
  static img.Image _letterbox(img.Image src) {
    final double scaleH = _encoderH / src.height;
    final double scaleW = _encoderW / src.width;
    final double scale = scaleH < scaleW ? scaleH : scaleW;

    final int newH = (src.height * scale).round();
    final int newW = (src.width * scale).round();

    final resized = img.copyResize(src, width: newW, height: newH);

    final canvas = img.Image(
      width: _encoderW,
      height: _encoderH,
      numChannels: 1,
    );
    img.fill(canvas, color: img.ColorUint8.rgb(255, 255, 255));

    final int offsetY = (_encoderH - newH) ~/ 2;
    final int offsetX = (_encoderW - newW) ~/ 2;

    img.compositeImage(canvas, resized, dstX: offsetX, dstY: offsetY);
    return canvas;
  }

  /// Preprocess staff image to encoder input: [1, 1, 256, 1280] float32.
  static Float32List _preprocessImage(img.Image gray) {
    final letterboxed = _letterbox(gray);
    final data = Float32List(_encoderH * _encoderW);
    for (int y = 0; y < _encoderH; y++) {
      for (int x = 0; x < _encoderW; x++) {
        final pixel = letterboxed.getPixel(x, y);
        final normalized =
            (pixel.r.toDouble() / 255.0 - _normMean) / _normStd;
        data[y * _encoderW + x] = normalized;
      }
    }
    return data;
  }

  static int _argmax(List<dynamic> flat, int offset, int length) {
    int best = 0;
    double bestVal = (flat[offset] as num).toDouble();
    for (int i = 1; i < length; i++) {
      final v = (flat[offset + i] as num).toDouble();
      if (v > bestVal) {
        bestVal = v;
        best = i;
      }
    }
    return best;
  }

  /// Formats the top-[k] softmax probabilities for a logit slice as
  /// `"label=0.42 label=0.39 ..."`, for debugging head predictions.
  static String _topKSoftmax(
    List<dynamic> flat,
    int offset,
    int length,
    Map<int, String> vocab,
    int k,
  ) {
    double maxVal = double.negativeInfinity;
    for (int i = 0; i < length; i++) {
      final v = (flat[offset + i] as num).toDouble();
      if (v > maxVal) maxVal = v;
    }
    double sum = 0;
    final probs = List<double>.filled(length, 0);
    for (int i = 0; i < length; i++) {
      final p = exp((flat[offset + i] as num).toDouble() - maxVal);
      probs[i] = p;
      sum += p;
    }
    final indices = List<int>.generate(length, (i) => i)
      ..sort((a, b) => probs[b].compareTo(probs[a]));
    return indices
        .take(k)
        .map((i) => '${vocab[i] ?? i}=${(probs[i] / sum).toStringAsFixed(2)}')
        .join(' ');
  }

  /// If [liftDebug] is non-null, appends one entry per emitted symbol with
  /// the top-3 lift-head softmax probabilities (e.g. "N=0.31 #=0.52 b=0.04"),
  /// for debugging accidental mispredictions.
  ///
  /// If [rhythmDebug] is non-null, appends one entry per emitted symbol with
  /// the top-3 rhythm-head softmax probabilities, for debugging barline /
  /// repeat-marker mispredictions.
  Future<List<EncodedSymbol>> runTransformer(
    Uint8List staffPng, {
    List<String>? liftDebug,
    List<String>? rhythmDebug,
  }) async {
    final decoded = img.decodeImage(staffPng);
    if (decoded == null) throw Exception('Failed to decode staff PNG');

    final gray = img.grayscale(decoded);

    final encoderSession = await _getEncoderSession();
    final decoderSession = await _getDecoderSession();

    // All OrtValues that must be disposed at the end
    OrtValue? encoderInputFp32;
    OrtValue? encoderInputFp16;
    OrtValue? encoderOutput;
    OrtValue? contextReduced;
    final List<OrtValue?> cacheValues =
        List<OrtValue?>.filled(_numCacheTensors, null);

    final List<EncodedSymbol> results = [];

    try {
      // --- Encoder ---
      final inputData = _preprocessImage(gray);
      encoderInputFp32 =
          await OrtValue.fromList(inputData, [1, 1, _encoderH, _encoderW]);
      encoderInputFp16 = await encoderInputFp32.to(OrtDataType.float16);
      encoderInputFp32.dispose();
      encoderInputFp32 = null;

      final encoderOutputs =
          await encoderSession.run({'input': encoderInputFp16});
      encoderInputFp16.dispose();
      encoderInputFp16 = null;

      encoderOutput = encoderOutputs.values.first;

      // Extract full encoder output as flat list for context reduction.
      // encoderOutput stays FP16 (used as decoder context); read a FP32 copy.
      // encoderOutput shape: [1, seq_len, 512]
      final encoderOutputFp32 = await encoderOutput.to(OrtDataType.float32);
      final encoderFlat = await encoderOutputFp32.asFlattenedList();
      encoderOutputFp32.dispose();

      // Build contextReduced: first token [1, 1, 512] float32 → fp16
      final contextReducedData = Float32List(512);
      for (int i = 0; i < 512; i++) {
        contextReducedData[i] = (encoderFlat[i] as num).toDouble();
      }
      OrtValue? contextReducedFp32;
      try {
        contextReducedFp32 =
            await OrtValue.fromList(contextReducedData, [1, 1, 512]);
        contextReduced = await contextReducedFp32.to(OrtDataType.float16);
      } finally {
        contextReducedFp32?.dispose();
      }

      // --- Initialize cache tensors ---
      // 32 tensors, each shape [1, 8, 0, 64] float16
      for (int i = 0; i < _numCacheTensors; i++) {
        OrtValue? fp32Cache;
        try {
          fp32Cache = await OrtValue.fromList(
              Float32List(0), [1, _decoderHeads, 0, _headDim]);
          cacheValues[i] = await fp32Cache.to(OrtDataType.float16);
        } finally {
          fp32Cache?.dispose();
        }
      }

      // Initial tokens
      int lastRhythm = Vocabulary.bosToken;
      int lastPitch = Vocabulary.nonoteToken;
      int lastLift = Vocabulary.nonoteToken;
      int lastArticulation = Vocabulary.nonoteToken;

      // Vocabulary sizes — determined at step 0 from the actual logit tensor
      // lengths and reused for all subsequent steps. Using length/(step+1) would
      // be wrong when the decoder output is constant [1,1,C] (KV-cache model):
      // at step 1 it yields C/2 and points argmax at the middle of the array.
      int? rhythmVocabSize;
      int? pitchVocabSize;
      int? liftVocabSize;
      int? positionVocabSize;
      int? articulationVocabSize;

      // --- Decoder loop ---
      for (int step = 0; step < _maxSteps; step++) {
        final rhythmInput =
            await OrtValue.fromList(Int64List.fromList([lastRhythm]), [1, 1]);
        final pitchInput =
            await OrtValue.fromList(Int64List.fromList([lastPitch]), [1, 1]);
        final liftInput =
            await OrtValue.fromList(Int64List.fromList([lastLift]), [1, 1]);
        final articulationInput = await OrtValue.fromList(
            Int64List.fromList([lastArticulation]), [1, 1]);
        final cacheLenInput =
            await OrtValue.fromList(Int64List.fromList([step]), [1]);

        // Context: full encoder output on step 0, reduced on subsequent steps
        final OrtValue contextInput = step == 0 ? encoderOutput : contextReduced;

        final Map<String, OrtValue> decoderInputs = {
          'rhythms': rhythmInput,
          'pitchs': pitchInput,
          'lifts': liftInput,
          'articulations': articulationInput,
          'context': contextInput,
          'cache_len': cacheLenInput,
        };
        for (int i = 0; i < _numCacheTensors; i++) {
          decoderInputs['cache_in$i'] = cacheValues[i]!;
        }

        Map<String, OrtValue>? decoderOutputs;
        try {
          decoderOutputs = await decoderSession.run(decoderInputs);
        } finally {
          rhythmInput.dispose();
          pitchInput.dispose();
          liftInput.dispose();
          articulationInput.dispose();
          cacheLenInput.dispose();
          // Do not dispose contextInput — it is encoderOutput or contextReduced (managed separately)
        }

        // Swap in new cache tensors, dispose old ones
        final List<OrtValue?> oldCache = List<OrtValue?>.from(cacheValues);

        for (int i = 0; i < _numCacheTensors; i++) {
          cacheValues[i] = decoderOutputs['cache_out$i']!;
        }

        // Dispose old cache values
        for (final v in oldCache) {
          v?.dispose();
        }

        // Extract logits and compute argmax for each head.
        // Logits shape: [1, seq_len_so_far, num_classes] — take last position.
        // Convert FP16 logits to FP32 before reading (asFlattenedList misreads FP16).
        Future<List<dynamic>> readFp16Logits(OrtValue raw) async {
          final fp32 = await raw.to(OrtDataType.float32);
          raw.dispose();
          final flat = await fp32.asFlattenedList();
          fp32.dispose();
          return flat;
        }

        final rhythmFlat =
            await readFp16Logits(decoderOutputs['out_rhythms']!);
        final pitchFlat = await readFp16Logits(decoderOutputs['out_pitchs']!);
        final liftFlat = await readFp16Logits(decoderOutputs['out_lifts']!);
        final positionFlat =
            await readFp16Logits(decoderOutputs['out_positions']!);
        final articulationFlat =
            await readFp16Logits(decoderOutputs['out_articulations']!);

        decoderOutputs['attention']?.dispose();

        // Vocab sizes: computed once at step 0, reused thereafter.
        // offset = length - vocabSize selects the LAST sequence position,
        // which is correct whether the model output is [1,1,C] (constant)
        // or [1,step+1,C] (accumulating).
        rhythmVocabSize ??= rhythmFlat.length;
        pitchVocabSize ??= pitchFlat.length;
        liftVocabSize ??= liftFlat.length;
        positionVocabSize ??= positionFlat.length;
        articulationVocabSize ??= articulationFlat.length;

        final int rhythmIdx = _argmax(
            rhythmFlat, rhythmFlat.length - rhythmVocabSize, rhythmVocabSize);
        final int pitchIdx =
            _argmax(pitchFlat, pitchFlat.length - pitchVocabSize, pitchVocabSize);
        final int liftIdx =
            _argmax(liftFlat, liftFlat.length - liftVocabSize, liftVocabSize);
        final int positionIdx = _argmax(
            positionFlat, positionFlat.length - positionVocabSize, positionVocabSize);
        final int articulationIdx = _argmax(articulationFlat,
            articulationFlat.length - articulationVocabSize, articulationVocabSize);

        if (rhythmIdx == Vocabulary.eosToken) break;

        if (liftDebug != null) {
          liftDebug.add(_topKSoftmax(liftFlat,
              liftFlat.length - liftVocabSize!, liftVocabSize, Vocabulary.lift, 3));
        }

        if (rhythmDebug != null) {
          rhythmDebug.add(_topKSoftmax(rhythmFlat,
              rhythmFlat.length - rhythmVocabSize!, rhythmVocabSize, Vocabulary.rhythm, 3));
        }

        results.add(EncodedSymbol(
          rhythm: Vocabulary.rhythm[rhythmIdx] ?? rhythmIdx.toString(),
          pitch: Vocabulary.pitch[pitchIdx] ?? pitchIdx.toString(),
          lift: Vocabulary.lift[liftIdx] ?? liftIdx.toString(),
          articulation:
              Vocabulary.articulation[articulationIdx] ?? articulationIdx.toString(),
          position:
              Vocabulary.position[positionIdx] ?? positionIdx.toString(),
        ));

        lastRhythm = rhythmIdx;
        lastPitch = pitchIdx;
        lastLift = liftIdx;
        lastArticulation = articulationIdx;
      }
    } finally {
      encoderInputFp32?.dispose();
      encoderInputFp16?.dispose();
      encoderOutput?.dispose();
      contextReduced?.dispose();
      for (final v in cacheValues) {
        v?.dispose();
      }
    }

    return results;
  }
}
