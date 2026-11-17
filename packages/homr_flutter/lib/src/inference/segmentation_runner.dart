import 'dart:typed_data';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import 'omr_models.dart';

class SegmentationRunner {
  /// [modelAsset] is the segnet's asset key in the app's bundle; see
  /// [OmrModels], as is [resolvePath].
  SegmentationRunner(this.modelAsset, {this.resolvePath});

  final String modelAsset;
  final AssetPathResolver? resolvePath;
  static const int _patchSize = 320;
  static const int _numClasses = 6;
  static const int _batchSize = 8;

  /// One session per model, for the life of the process: loading a model
  /// takes seconds, and every runner over the same asset can share it.
  static final _sessions = <String, Future<OrtSession>>{};

  Future<OrtSession> _getSession() => _sessions.putIfAbsent(
      modelAsset, () => openModelSession(modelAsset, resolvePath));

  Future<Uint8List> runSegmentation(Uint8List pngBytes) async {
    final decoded = img.decodeImage(pngBytes);
    if (decoded == null) throw Exception('Failed to decode PNG');

    // Convert to uint8 grayscale for patch extraction.
    // img.grayscale() corrupts uint1 PNGs (all pixels become 1 after the call).
    // uint1 already encodes 0=black / 1=white — direct convert to uint8
    // maps those to 0=black / 255=white without any inversion needed.
    final img.Image gray;
    if (decoded.format == img.Format.uint1) {
      gray = decoded.convert(format: img.Format.uint8, numChannels: 1);
    } else {
      final rawGray = img.grayscale(decoded);
      gray = rawGray.format == img.Format.uint8
          ? rawGray
          : rawGray.convert(format: img.Format.uint8, numChannels: 1);
    }

    final int W = gray.width;
    final int H = gray.height;

    final session = await _getSession();

    // Accumulate results
    final reconstructed = List<double>.filled(H * W, 0.0);
    final weight = List<double>.filled(H * W, 0.0);

    // Collect patches in batches
    final List<Float32List> pendingPatchData = [];
    final List<(int, int)> pendingPatchOrigins = [];

    Future<void> flushBatch() async {
      if (pendingPatchData.isEmpty) return;

      final batchLen = pendingPatchData.length;
      final flatSize = batchLen * _patchSize * _patchSize * 3;
      final batchData = Float32List(flatSize);
      for (int b = 0; b < batchLen; b++) {
        final src = pendingPatchData[b];
        batchData.setRange(b * _patchSize * _patchSize * 3,
            (b + 1) * _patchSize * _patchSize * 3, src);
      }

      OrtValue? inputFp32;
      OrtValue? inputFp16;

      try {
        inputFp32 = await OrtValue.fromList(
            batchData, [batchLen, 3, _patchSize, _patchSize]);
        inputFp16 = await inputFp32.to(OrtDataType.float16);
        inputFp32.dispose();
        inputFp32 = null;

        final outputs = await session.run({'input': inputFp16});
        inputFp16.dispose();
        inputFp16 = null;

        // The FP16 model outputs FP16 logits; asFlattenedList() misreads FP16
        // bytes as float32, yielding all-zero values. Convert to float32 first.
        final rawOutput = outputs.values.first;

        final outputFp32 = await rawOutput.to(OrtDataType.float32);
        rawOutput.dispose();
        final flatOutput = await outputFp32.asFlattenedList();
        outputFp32.dispose();

        // flatOutput: [batchLen, 6, 320, 320]
        for (int b = 0; b < batchLen; b++) {
          final (px, py) = pendingPatchOrigins[b];
          final y0 = py < 0 ? 0 : py;
          final y1 = (py + _patchSize) < H ? (py + _patchSize) : H;
          final x0 = px < 0 ? 0 : px;
          final x1 = (px + _patchSize) < W ? (px + _patchSize) : W;
          final ph = y1 - y0;
          final pw = x1 - x0;

          for (int row = 0; row < ph; row++) {
            for (int col = 0; col < pw; col++) {
              // Find argmax over classes for this pixel
              int bestClass = 0;
              double bestVal = double.negativeInfinity;
              for (int c = 0; c < _numClasses; c++) {
                final idx = b * _numClasses * _patchSize * _patchSize +
                    c * _patchSize * _patchSize +
                    row * _patchSize +
                    col;
                final val = (flatOutput[idx] as num).toDouble();
                if (val > bestVal) {
                  bestVal = val;
                  bestClass = c;
                }
              }
              final outIdx = (y0 + row) * W + (x0 + col);
              reconstructed[outIdx] += bestClass.toDouble();
              weight[outIdx] += 1.0;
            }
          }
        }
      } finally {
        inputFp32?.dispose();
        inputFp16?.dispose();
      }

      pendingPatchData.clear();
      pendingPatchOrigins.clear();
    }

    // Patch loop — port from Python exactly:
    // for y_loop in range(0, max(h, 320), 320): y = min(y_loop, h-320)
    // for x_loop in range(0, max(w, 320), 320): x = min(x_loop, w-320)
    final yMax = H > _patchSize ? H : _patchSize;
    final xMax = W > _patchSize ? W : _patchSize;

    for (int yLoop = 0; yLoop < yMax; yLoop += _patchSize) {
      final int py = yLoop < (H - _patchSize) ? yLoop : (H - _patchSize);

      for (int xLoop = 0; xLoop < xMax; xLoop += _patchSize) {
        final int px = xLoop < (W - _patchSize) ? xLoop : (W - _patchSize);

        // Extract patch: CHW layout, grayscale replicated to 3 channels
        final patchData = Float32List(_patchSize * _patchSize * 3);
        for (int c = 0; c < 3; c++) {
          for (int row = 0; row < _patchSize; row++) {
            for (int col = 0; col < _patchSize; col++) {
              final imgY = py + row;
              final imgX = px + col;
              double pixelVal;
              if (imgY >= 0 && imgY < H && imgX >= 0 && imgX < W) {
                final pixel = gray.getPixel(imgX, imgY);
                pixelVal = pixel.r.toDouble();
              } else {
                pixelVal = 255.0;
              }
              patchData[c * _patchSize * _patchSize + row * _patchSize + col] =
                  pixelVal;
            }
          }
        }

        pendingPatchData.add(patchData);
        pendingPatchOrigins.add((px, py));

        if (pendingPatchData.length >= _batchSize) {
          await flushBatch();
        }
      }
    }

    await flushBatch();

    // Reconstruct the per-pixel class map with homr's exact semantics
    // (inference_segnet.py merge_patches + `merged == c`): each patch contributes
    // its argmax class index; overlapping patches average those indices; a pixel
    // belongs to class c only when that average equals c exactly. Where patches
    // disagree the average is non-integer and the pixel belongs to NO class —
    // homr drops it from every mask. We mirror that with a 255 sentinel rather
    // than the previous `.round()`, which silently mislabelled ambiguous overlap
    // pixels (e.g. staff(4)+background(0) → round(2) = notehead).
    return Uint8List.fromList(
      List<int>.generate(H * W, (i) {
        final wt = weight[i];
        if (wt == 0.0) return 0;
        final sum = reconstructed[i];
        final c = (sum / wt).round();
        // Exact integer agreement ⇔ sum == c*weight (sums of integer class ids).
        if (c >= 0 && c <= 5 && (sum - c * wt).abs() < 1e-6) return c;
        return 255; // ambiguous overlap → no class
      }),
    );
  }
}
