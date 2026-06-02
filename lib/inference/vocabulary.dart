class Vocabulary {
  static const int padToken = 0;
  static const int bosToken = 1;
  static const int eosToken = 2;
  static const int nonoteToken = 0;

  static final Map<int, String> rhythm = _buildRhythm();
  static final Map<int, String> pitch = _buildPitch();
  static final Map<int, String> lift = _buildLift();
  static final Map<int, String> articulation = _buildArticulation();
  static final Map<int, String> position = _buildPosition();

  static Map<int, String> _buildRhythm() {
    final List<String> tokens = [];

    tokens.addAll(['PAD', 'BOS', 'EOS', 'chord']);
    tokens.addAll(['barline', 'doublebarline', 'bolddoublebarline']);
    tokens.addAll(['repeatStart', 'repeatEnd', 'repeatEndStart']);
    tokens.addAll(['voltaStart', 'voltaStop', 'voltaDiscontinue']);

    for (int c = 3; c <= 5; c++) {
      tokens.add('clef_F$c');
    }
    for (int c = 1; c <= 5; c++) {
      tokens.add('clef_C$c');
    }
    for (int c = 1; c <= 2; c++) {
      tokens.add('clef_G$c');
    }

    for (int c = -7; c <= 7; c++) {
      tokens.add('keySignature_$c');
    }

    for (int c in [1, 2, 3, 4, 6, 8, 12, 16, 32, 48]) {
      tokens.add('timeSignature/$c');
    }

    for (int c = 2; c <= 10; c++) {
      tokens.add('rest_${c}m');
    }

    const kernBaseDurations = [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 32, 64, 128];
    const dots = ['', '.', '..'];
    const grace = ['', 'G'];

    for (final d in kernBaseDurations) {
      for (final g in grace) {
        for (final dot in dots) {
          tokens.add('note_$d$g$dot');
        }
      }
    }

    const irregularDurations = [7, 11, 13, 18, 20, 21, 22, 24, 26, 28, 30, 34, 36, 40, 48, 56, 96];
    for (final d in irregularDurations) {
      tokens.add('note_$d');
    }

    for (final d in kernBaseDurations) {
      for (final g in grace) {
        for (final dot in dots) {
          tokens.add('rest_$d$g$dot');
        }
      }
    }

    for (final d in irregularDurations) {
      tokens.add('rest_$d');
    }

    tokens.add('tieSlur');

    final Map<int, String> vocab = {};
    for (int i = 0; i < tokens.length; i++) {
      vocab[i] = tokens[i];
    }
    return vocab;
  }

  static Map<int, String> _buildLift() {
    final tokens = ['.', '_', '#', '##', 'N', 'b', 'bb'];
    final Map<int, String> vocab = {};
    for (int i = 0; i < tokens.length; i++) {
      vocab[i] = tokens[i];
    }
    return vocab;
  }

  static Map<int, String> _buildPosition() {
    final tokens = ['.', 'upper', 'lower'];
    final Map<int, String> vocab = {};
    for (int i = 0; i < tokens.length; i++) {
      vocab[i] = tokens[i];
    }
    return vocab;
  }

  static Map<int, String> _buildPitch() {
    final List<String> tokens = ['.', '_'];

    const noteNames = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
    // product(range(10), noteNames) then reversed
    final List<String> pairs = [];
    for (int octave = 0; octave < 10; octave++) {
      for (final n in noteNames) {
        pairs.add('$n$octave');
      }
    }
    for (int i = pairs.length - 1; i >= 0; i--) {
      tokens.add(pairs[i]);
    }

    final Map<int, String> vocab = {};
    for (int i = 0; i < tokens.length; i++) {
      vocab[i] = tokens[i];
    }
    return vocab;
  }

  static Map<int, String> _buildArticulation() {
    final List<String> tokens = ['.', '_'];

    tokens.addAll([
      'accent',
      'accent_arpeggiate',
      'accent_arpeggiate_fermata',
      'accent_arpeggiate_slurStart',
      'accent_arpeggiate_slurStart_staccato',
      'accent_arpeggiate_slurStart_tenuto',
      'accent_arpeggiate_slurStop',
      'accent_arpeggiate_slurStop_staccato',
      'accent_arpeggiate_slurStop_tenuto',
      'accent_arpeggiate_staccato',
      'accent_arpeggiate_tenuto',
      'accent_breathMark',
      'accent_breathMark_fermata',
      'accent_breathMark_slurStart',
      'accent_breathMark_slurStop',
      'accent_fermata',
      'accent_fermata_slurStart',
      'accent_fermata_slurStop',
      'accent_fermata_staccato',
      'accent_slurStart',
      'accent_slurStart_slurStop',
      'accent_slurStart_slurStop_tenuto',
      'accent_slurStart_slurStop_trill',
      'accent_slurStart_staccato',
      'accent_slurStart_tenuto',
      'accent_slurStart_tremolo',
      'accent_slurStart_trill',
      'accent_slurStop',
      'accent_slurStop_staccato',
      'accent_slurStop_tenuto',
      'accent_slurStop_tremolo',
      'accent_slurStop_trill',
      'accent_staccatissimo',
      'accent_staccato',
      'accent_staccato_tenuto',
      'accent_tenuto',
      'accent_tremolo',
      'accent_trill',
      'arpeggiate',
      'arpeggiate_breathMark_fermata',
      'arpeggiate_fermata',
      'arpeggiate_fermata_slurStart',
      'arpeggiate_fermata_slurStop',
      'arpeggiate_fermata_staccato',
      'arpeggiate_slurStart',
      'arpeggiate_slurStart_slurStop',
      'arpeggiate_slurStart_staccatissimo',
      'arpeggiate_slurStart_staccato',
      'arpeggiate_slurStart_staccato_tenuto',
      'arpeggiate_slurStart_tenuto',
      'arpeggiate_slurStart_tremolo',
      'arpeggiate_slurStop',
      'arpeggiate_slurStop_staccatissimo',
      'arpeggiate_slurStop_staccato',
      'arpeggiate_slurStop_tenuto',
      'arpeggiate_staccatissimo',
      'arpeggiate_staccato',
      'arpeggiate_staccato_tenuto',
      'arpeggiate_tenuto',
      'arpeggiate_tremolo',
      'breathMark',
      'breathMark_fermata',
      'breathMark_fermata_slurStop',
      'breathMark_fermata_tenuto',
      'breathMark_slurStart',
      'breathMark_slurStop',
      'breathMark_slurStop_staccato',
      'breathMark_slurStop_trill',
      'breathMark_staccato',
      'breathMark_tenuto',
      'fermata',
      'fermata_slurStart',
      'fermata_slurStart_slurStop',
      'fermata_slurStart_slurStop_trill',
      'fermata_slurStart_trill',
      'fermata_slurStop',
      'fermata_slurStop_staccato',
      'fermata_slurStop_tenuto',
      'fermata_slurStop_tremolo',
      'fermata_slurStop_trill',
      'fermata_slurStop_turn',
      'fermata_staccato',
      'fermata_staccato_tenuto',
      'fermata_tenuto',
      'fermata_tremolo',
      'fermata_trill',
      'slurStart',
      'slurStart_slurStop',
      'slurStart_slurStop_staccato',
      'slurStart_slurStop_staccato_tenuto',
      'slurStart_slurStop_tenuto',
      'slurStart_slurStop_tremolo',
      'slurStart_slurStop_trill',
      'slurStart_slurStop_turn',
      'slurStart_staccatissimo',
      'slurStart_staccato',
      'slurStart_staccato_tenuto',
      'slurStart_tenuto',
      'slurStart_tremolo',
      'slurStart_trill',
      'slurStart_turn',
      'slurStop',
      'slurStop_staccatissimo',
      'slurStop_staccato',
      'slurStop_staccato_tenuto',
      'slurStop_tenuto',
      'slurStop_tremolo',
      'slurStop_trill',
      'slurStop_turn',
      'spiccato',
      'staccatissimo',
      'staccato',
      'staccato_tenuto',
      'staccato_tremolo',
      'staccato_trill',
      'staccato_turn',
      'tenuto',
      'tremolo',
      'trill',
      'turn',
    ]);

    final Map<int, String> vocab = {};
    for (int i = 0; i < tokens.length; i++) {
      vocab[i] = tokens[i];
    }
    return vocab;
  }
}
