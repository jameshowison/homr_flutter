import 'package:homr_flutter/homr_flutter.dart';

/// Where this demo app bundles homr's models (fetched by
/// packages/homr_flutter/tool/fetch_models.py; gitignored). Shared by the
/// demo screens and every integration test that runs real inference.
final demoModels = OmrModels.inAssetDir('assets/omr_models');
