import 'dart:convert';
import 'dart:io';

/// Pure content parsing (`parse.universal`), 2-table reconciliation (`transform.pipeline`),
/// and disk artifact export (`export.artifact`) for `UNIV-2`.
class UniversalContentParser {
  const UniversalContentParser._();

  static List<Map<String, Object?>> parseUniversalContent(
    String rawContent, {
    String format = 'auto',
    String sourceName = 'inline',
  }) {
    final trimmed = rawContent.trim();
    if (trimmed.isEmpty) return const <Map<String, Object?>>[];

    final resolvedFormat = format == 'auto'
        ? (trimmed.startsWith('{') || trimmed.startsWith('[')
              ? 'json'
              : (trimmed.startsWith('<') && trimmed.contains('>')
                    ? 'xml'
                    : (trimmed.contains('\n') &&
                              (trimmed.split('\n').first.contains(',') ||
                                  trimmed.split('\n').first.contains('\t'))
                          ? 'csv'
                          : 'text')))
        : format.toLowerCase();

    if (resolvedFormat == 'json') {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map(
                (m) => m.map(
                  (key, value) => MapEntry(key.toString(), value as Object?),
                ),
              )
              .toList(growable: false);
        }
        if (decoded is Map) {
          for (final listKey in const <String>['rows', 'items', 'data']) {
            final nested = decoded[listKey];
            if (nested is List) {
              return nested
                  .whereType<Map>()
                  .map(
                    (m) => m.map(
                      (key, value) =>
                          MapEntry(key.toString(), value as Object?),
                    ),
                  )
                  .toList(growable: false);
            }
          }
          return <Map<String, Object?>>[
            decoded.map(
              (key, value) => MapEntry(key.toString(), value as Object?),
            ),
          ];
        }
      } on FormatException {
        // Fall through to text parser if malformed JSON
      }
    }

    if (resolvedFormat == 'csv' || resolvedFormat == 'tsv') {
      final lines = trimmed
          .split(RegExp(r'\r?\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.length >= 2) {
        final delimiter = lines.first.contains('\t') ? '\t' : ',';
        final headers = _splitCsvLine(lines.first, delimiter);
        final out = <Map<String, Object?>>[];
        for (var i = 1; i < lines.length; i++) {
          final cells = _splitCsvLine(lines[i], delimiter);
          final row = <String, Object?>{};
          for (var c = 0; c < headers.length; c++) {
            final key = headers[c].isEmpty ? 'col_$c' : headers[c];
            final rawVal = c < cells.length ? cells[c] : '';
            final asInt = int.tryParse(rawVal);
            row[key] = asInt ?? rawVal;
          }
          out.add(row);
        }
        return out;
      }
    }

    if (resolvedFormat == 'xml') {
      final blockMatches = RegExp(
        r'<(Row|Item|Record|Candidate|Product|Invoice|HDon|HD)\b[^>]*>([\s\S]*?)</\1>',
        caseSensitive: false,
      ).allMatches(trimmed);
      final leafTagRe = RegExp(r'<([a-zA-Z0-9_:-]+)>([^<>]+)</\1>');
      if (blockMatches.isNotEmpty) {
        final out = <Map<String, Object?>>[];
        for (final block in blockMatches) {
          final inner = block.group(2) ?? '';
          final row = <String, Object?>{};
          for (final tag in leafTagRe.allMatches(inner)) {
            final k = tag.group(1)!;
            final v = tag.group(2)!.trim();
            row[k] = int.tryParse(v) ?? v;
          }
          if (row.isNotEmpty) out.add(row);
        }
        if (out.isNotEmpty) return out;
      }
      final singleRow = <String, Object?>{'source': sourceName};
      for (final tag in leafTagRe.allMatches(trimmed)) {
        final k = tag.group(1)!;
        final v = tag.group(2)!.trim();
        singleRow[k] = int.tryParse(v) ?? v;
      }
      if (singleRow.length > 1) {
        return <Map<String, Object?>>[singleRow];
      }
    }

    final chunks = trimmed.contains('\n---\n')
        ? trimmed.split('\n---\n')
        : <String>[trimmed];
    final emailRe = RegExp(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}');
    final phoneRe = RegExp(r'(?:\+84|0)[0-9\s.\-]{8,12}');
    final urlRe = RegExp(
      r'https?://[^\s"'
      "'"
      r'<>]+',
    );
    final expRe = RegExp(
      r'(\d+(?:[.,]\d+)?)\s*(?:năm|nam|years?|yrs?)',
      caseSensitive: false,
    );
    final amountRe = RegExp(
      r'(\d{1,3}(?:[.,]\d{3})+)\s*(?:đ|vnd|usd|\$)?',
      caseSensitive: false,
    );
    const knownSkillKeywords = <String>[
      'Python',
      'Flutter',
      'Dart',
      'React',
      'TypeScript',
      'Marketing',
      'SEO',
      'Sales',
      'Excel',
      'SQL',
      'AI',
      'Design',
      'Figma',
      'Photoshop',
      'NodeJS',
      'Java',
    ];

    final out = <Map<String, Object?>>[];
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i].trim();
      if (chunk.isEmpty) continue;
      final firstLine = chunk
          .split(RegExp(r'\r?\n'))
          .first
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .trim();
      final email = emailRe.firstMatch(chunk)?.group(0) ?? '';
      final phone = phoneRe.firstMatch(chunk)?.group(0)?.trim() ?? '';
      final url = urlRe.firstMatch(chunk)?.group(0) ?? '';
      final yearsExp = expRe.firstMatch(chunk)?.group(1) ?? '';
      final amount = amountRe.firstMatch(chunk)?.group(1) ?? '';
      final matchedSkills = knownSkillKeywords
          .where((kw) => chunk.toLowerCase().contains(kw.toLowerCase()))
          .toList(growable: false);

      out.add(<String, Object?>{
        'source': chunks.length == 1 ? sourceName : '$sourceName#${i + 1}',
        'title': firstLine.length > 80 ? firstLine.substring(0, 80) : firstLine,
        if (email.isNotEmpty) 'email': email,
        if (phone.isNotEmpty) 'phone': phone,
        if (url.isNotEmpty) 'url': url,
        if (yearsExp.isNotEmpty) 'yearsExp': yearsExp,
        if (amount.isNotEmpty) 'amount': amount,
        if (matchedSkills.isNotEmpty) 'skills': matchedSkills.join(', '),
        'score': 60 + (matchedSkills.length * 10).clamp(0, 38),
      });
    }
    return out;
  }

  static List<String> _splitCsvLine(String line, String delimiter) {
    final result = <String>[];
    final sb = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (!inQuotes && ch == delimiter) {
        result.add(sb.toString().trim());
        sb.clear();
      } else {
        sb.write(ch);
      }
    }
    result.add(sb.toString().trim());
    return result;
  }

  static List<Map<String, Object?>> reconcileUniversalTables(
    List<Map<String, Object?>> primaryRows,
    List<Map<String, Object?>> secondaryRows,
  ) {
    String extractKey(Map<String, Object?> row) {
      for (final k in const <String>[
        'id',
        'orderId',
        'ma_don',
        'code',
        'invoiceNo',
      ]) {
        if (row[k] != null) return row[k].toString().trim();
      }
      return row.values.isEmpty ? '' : row.values.first.toString().trim();
    }

    int extractAmount(Map<String, Object?> row) {
      for (final k in const <String>[
        'amount',
        'total',
        'totalVnd',
        'so_tien',
        'price',
      ]) {
        final v = row[k];
        if (v is int) return v;
        if (v is num) return v.round();
        if (v is String) {
          final digits = v.replaceAll(RegExp(r'[^0-9\-]'), '');
          final parsed = int.tryParse(digits);
          if (parsed != null) return parsed;
        }
      }
      return 0;
    }

    final secondaryMap = <String, Map<String, Object?>>{};
    for (final row in secondaryRows) {
      final k = extractKey(row);
      if (k.isNotEmpty) {
        secondaryMap[k] = row;
      }
    }

    final results = <Map<String, Object?>>[];
    for (final left in primaryRows) {
      final key = extractKey(left);
      final leftAmt = extractAmount(left);
      final right = secondaryMap[key];
      if (right == null) {
        results.add(<String, Object?>{
          'id': key,
          'leftAmount': leftAmt,
          'rightAmount': 0,
          'delta': -leftAmt,
          'status': 'thieu_du_lieu',
        });
      } else {
        final rightAmt = extractAmount(right);
        final delta = rightAmt - leftAmt;
        results.add(<String, Object?>{
          'id': key,
          'leftAmount': leftAmt,
          'rightAmount': rightAmt,
          'delta': delta,
          'status': delta == 0 ? 'khop_100' : 'lech_gia_tri',
        });
      }
    }
    return results;
  }

  static String exportUniversalArtifactToDisk({
    required String filePath,
    required String format,
    required String titleVi,
    required List<Map<String, Object?>> rows,
  }) {
    final fmt = format.trim().toLowerCase();
    final cols = <String>{};
    for (final r in rows) {
      cols.addAll(r.keys);
    }
    final orderedCols = cols.isEmpty
        ? const <String>['status']
        : cols.toList(growable: false);

    late final String content;
    if (fmt == 'json') {
      content = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'title': titleVi,
        'count': rows.length,
        'rows': rows,
      });
    } else if (fmt == 'md') {
      final sb = StringBuffer()
        ..writeln('# $titleVi')
        ..writeln()
        ..writeln('| ${orderedCols.join(' | ')} |')
        ..writeln('| ${orderedCols.map((_) => '---').join(' | ')} |');
      for (final r in rows) {
        final cells = orderedCols
            .map((c) => (r[c] ?? '').toString().replaceAll('|', '/'))
            .join(' | ');
        sb.writeln('| $cells |');
      }
      content = sb.toString();
    } else if (fmt == 'html') {
      final sb = StringBuffer()
        ..writeln('<!DOCTYPE html><html lang="vi"><head><meta charset="utf-8">')
        ..writeln('<title>$titleVi</title></head><body>')
        ..writeln('<h1>$titleVi</h1><table border="1" cellpadding="6">')
        ..writeln(
          '<thead><tr>${orderedCols.map((c) => '<th>$c</th>').join()}</tr></thead><tbody>',
        );
      for (final r in rows) {
        sb.writeln(
          '<tr>${orderedCols.map((c) => '<td>${r[c] ?? ''}</td>').join()}</tr>',
        );
      }
      sb.writeln('</tbody></table></body></html>');
      content = sb.toString();
    } else {
      String escapeCsv(Object? val) {
        final s = (val ?? '').toString();
        if (s.contains(',') || s.contains('"') || s.contains('\n')) {
          return '"${s.replaceAll('"', '""')}"';
        }
        return s;
      }

      final sb = StringBuffer('\uFEFF')
        ..writeln(orderedCols.map(escapeCsv).join(','));
      for (final r in rows) {
        sb.writeln(orderedCols.map((c) => escapeCsv(r[c])).join(','));
      }
      content = sb.toString();
    }

    final file = File(filePath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content, encoding: utf8);
    return file.path;
  }
}
