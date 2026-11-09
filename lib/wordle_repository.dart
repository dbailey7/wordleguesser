import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class WordResult {
  final String word;
  final int? rank;
  const WordResult(this.word, this.rank);
}

class WordleRepository {
  static const _dbAssetPath = 'assets/wordlist.db';
  static const _dbFileName = 'wordlist.db';
  static const _fingerprintFileName = 'wordlist.db.fingerprint';

  Database? _db;

  Future<Database> _openDb() async {
    final existing = _db;
    if (existing != null) return existing;

    final docsDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docsDir.path, _dbFileName);
    final fingerprintFile = File(p.join(docsDir.path, _fingerprintFileName));

    // The bundled word list is copied into app storage on first use. An app
    // update keeps that storage, so without a check the app would keep reading
    // the old copy and never see newly added words. Compare a fingerprint of
    // the bundled database with the one recorded at the last copy, and
    // re-copy whenever the bundled list has changed.
    final bytes = await rootBundle.load(_dbAssetPath);
    final data =
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    final fingerprint = _fingerprint(data);
    final storedFingerprint = await fingerprintFile.exists()
        ? (await fingerprintFile.readAsString()).trim()
        : null;

    if (!await File(dbPath).exists() || storedFingerprint != fingerprint) {
      await File(dbPath).writeAsBytes(data, flush: true);
      await fingerprintFile.writeAsString(fingerprint, flush: true);
    }

    final db = await openDatabase(dbPath, readOnly: true);
    _db = db;
    return db;
  }

  /// Cheap content fingerprint (byte length + 32-bit FNV-1a hash) used to
  /// tell whether the bundled database differs from the stored copy.
  static String _fingerprint(Uint8List data) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < data.length; i++) {
      hash ^= data[i];
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '${data.length}:${hash.toRadixString(16)}';
  }

  Future<List<WordResult>> getGuesses({
    required int wordLength,
    required Map<int, String> greenLetters,
    required Map<int, Set<String>> yellowLetters,
    required Set<String> blackLetters,
  }) async {
    final db = await _openDb();

    final conditions = <String>[];
    final args = <Object?>[];

    conditions.add('LENGTH(headword) = ?');
    args.add(wordLength);

    for (final entry in greenLetters.entries) {
      conditions.add('LOWER(SUBSTR(headword, ?, 1)) = ?');
      args.add(entry.key);
      args.add(entry.value.toLowerCase());
    }

    // Each letter marked yellow at a position must appear in the word but
    // NOT at that position — a position can have more than one such letter
    // (different guesses can each rule out a different letter for the same
    // spot).
    for (final entry in yellowLetters.entries) {
      for (final letter in entry.value) {
        conditions.add('LOWER(SUBSTR(headword, ?, 1)) != ?');
        args.add(entry.key);
        args.add(letter.toLowerCase());
        conditions.add('LOWER(headword) LIKE ?');
        args.add('%${letter.toLowerCase()}%');
      }
    }

    for (final letter in blackLetters) {
      conditions.add('LOWER(headword) NOT LIKE ?');
      args.add('%${letter.toLowerCase()}%');
    }

    conditions.add("headword NOT LIKE '%.%'");
    conditions.add("headword NOT LIKE '%-%'");

    final where = conditions.join(' AND ');
    final query = '''
      SELECT headword, rank FROM wordlist
      WHERE $where
      ORDER BY CASE WHEN rank IS NULL THEN 1 ELSE 0 END, rank
    ''';

    final rows = await db.rawQuery(query, args);
    return rows
        .map((row) => WordResult(row['headword'] as String, row['rank'] as int?))
        .toList();
  }
}
