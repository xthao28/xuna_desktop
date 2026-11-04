import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Binary & text document extractor (`.pdf`, `.docx`, `.xlsx`, `.odt`, `.rtf`, `.txt`, `.md`, `.csv`, `.json`, `.xml`).
class UniversalFileExtractor {
  const UniversalFileExtractor._();

  static String extractTextFromFileSync(
    File file, {
    int maxBytes = 4 * 1024 * 1024,
  }) {
    if (!file.existsSync()) return '';
    final name = file.path.split(RegExp(r'[/\\]')).last;
    final dotIdx = name.lastIndexOf('.');
    final ext = dotIdx >= 0 ? name.substring(dotIdx + 1).toLowerCase() : '';
    try {
      final stat = file.statSync();
      if (stat.size <= 0 || stat.size > maxBytes) return '';
      if (const <String>{
        'txt',
        'md',
        'csv',
        'tsv',
        'json',
        'xml',
        'html',
        'htm',
        'log',
        'yaml',
        'yml',
        'ini',
        'env',
      }.contains(ext)) {
        final bytes = file.readAsBytesSync();
        return utf8.decode(bytes, allowMalformed: true).trim();
      }
      if (ext == 'rtf') {
        if (Platform.isMacOS &&
            !Platform.environment.containsKey('FLUTTER_TEST')) {
          final res = Process.runSync('/usr/bin/textutil', <String>[
            '-convert',
            'txt',
            '-stdout',
            file.path,
          ]);
          if (res.exitCode == 0 && '${res.stdout}'.trim().isNotEmpty) {
            return '${res.stdout}'.trim();
          }
        }
        final raw = latin1.decode(file.readAsBytesSync(), allowInvalid: true);
        return raw
            .replaceAll(RegExp(r'\\par\b|\\line\b'), '\n')
            .replaceAll(RegExp(r'\\[a-zA-Z]+\-?\d*\s?'), '')
            .replaceAll(RegExp(r'[{}]'), '')
            .trim();
      }
      if (ext == 'docx' || ext == 'odt') {
        final bytes = file.readAsBytesSync();
        final targetXml = ext == 'docx' ? 'word/document.xml' : 'content.xml';
        final entries = _extractZipEntriesUtf8(bytes, <String>{targetXml});
        final xml = entries[targetXml] ?? '';
        if (xml.isNotEmpty) {
          return _decodeXmlEntities(
            xml
                .replaceAll(RegExp(r'</(w:p|text:p|w:tr)>'), '\n')
                .replaceAll(RegExp(r'<(w:tab|text:tab)[^>]*/?>'), '\t')
                .replaceAll(RegExp(r'<[^>]+>'), ''),
          ).trim();
        }
        if (Platform.isMacOS &&
            !Platform.environment.containsKey('FLUTTER_TEST')) {
          final res = Process.runSync('/usr/bin/textutil', <String>[
            '-convert',
            'txt',
            '-stdout',
            file.path,
          ]);
          if (res.exitCode == 0) return '${res.stdout}'.trim();
        }
        return '';
      }
      if (ext == 'xlsx') {
        final bytes = file.readAsBytesSync();
        final entries = _extractZipEntriesUtf8(bytes, const <String>{
          'xl/sharedStrings.xml',
          'xl/worksheets/sheet1.xml',
        });
        final sharedXml = entries['xl/sharedStrings.xml'] ?? '';
        final sheetXml = entries['xl/worksheets/sheet1.xml'] ?? '';
        if (sheetXml.isEmpty) return '';
        final sharedStrings = <String>[];
        for (final m in RegExp(r'<si\b[^>]*>([\s\S]*?)</si>')
            .allMatches(sharedXml)) {
          final inner = m.group(1) ?? '';
          final text = RegExp(r'<t\b[^>]*>([\s\S]*?)</t>')
              .allMatches(inner)
              .map((t) => _decodeXmlEntities(t.group(1) ?? ''))
              .join();
          sharedStrings.add(text.trim());
        }
        final rowsOut = <String>[];
        for (final rowMatch in RegExp(r'<row\b[^>]*>([\s\S]*?)</row>')
            .allMatches(sheetXml)) {
          final rowXml = rowMatch.group(1) ?? '';
          final cells = <String>[];
          for (final cellMatch
              in RegExp(r'<c\b([^>]*)>([\s\S]*?)</c>').allMatches(rowXml)) {
            final attrs = cellMatch.group(1) ?? '';
            final cellBody = cellMatch.group(2) ?? '';
            final isShared = RegExp(r'\bt="s"').hasMatch(attrs);
            final isInline = RegExp(r'\bt="inlineStr"').hasMatch(attrs);
            if (isInline) {
              final inlineVal = RegExp(r'<t\b[^>]*>([\s\S]*?)</t>')
                      .firstMatch(cellBody)
                      ?.group(1) ??
                  '';
              cells.add(_decodeXmlEntities(inlineVal).trim());
            } else {
              final vRaw = RegExp(r'<v>([\s\S]*?)</v>')
                      .firstMatch(cellBody)
                      ?.group(1)
                      ?.trim() ??
                  '';
              if (isShared) {
                final idx = int.tryParse(vRaw);
                if (idx != null && idx >= 0 && idx < sharedStrings.length) {
                  cells.add(sharedStrings[idx]);
                } else {
                  cells.add(vRaw);
                }
              } else {
                cells.add(vRaw);
              }
            }
          }
          if (cells.any((c) => c.isNotEmpty)) {
            rowsOut.add(cells.join(','));
          }
        }
        return rowsOut.join('\n').trim();
      }
      if (ext == 'pdf') {
        final bytes = file.readAsBytesSync();
        final extracted = _extractPdfTextStreams(bytes);
        if (extracted.isNotEmpty) return extracted;
        if (Platform.isMacOS &&
            !Platform.environment.containsKey('FLUTTER_TEST')) {
          final res = Process.runSync('/usr/bin/mdls', <String>[
            '-raw',
            '-name',
            'kMDItemTextContent',
            file.path,
          ]);
          final out = '${res.stdout}'.trim();
          if (res.exitCode == 0 && out.isNotEmpty && out != '(null)') {
            return out;
          }
        }
        return '';
      }
    } catch (_) {}
    return '';
  }

  static Map<String, String> _extractZipEntriesUtf8(
    Uint8List bytes,
    Set<String> wantedNames,
  ) {
    final out = <String, String>{};
    final bd = ByteData.sublistView(bytes);
    var eocdOffset = -1;
    final minEocdPos = (bytes.length - 65557).clamp(0, bytes.length);
    for (var i = bytes.length - 22; i >= minEocdPos; i--) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4b &&
          bytes[i + 2] == 0x05 &&
          bytes[i + 3] == 0x06) {
        eocdOffset = i;
        break;
      }
    }
    if (eocdOffset >= 0 && eocdOffset + 20 <= bytes.length) {
      final totalEntries = bd.getUint16(eocdOffset + 10, Endian.little);
      final cdOffset = bd.getUint32(eocdOffset + 16, Endian.little);
      var ptr = cdOffset;
      for (var e = 0; e < totalEntries && ptr + 46 <= bytes.length; e++) {
        if (bd.getUint32(ptr, Endian.little) != 0x02014b50) break;
        final method = bd.getUint16(ptr + 10, Endian.little);
        final compSize = bd.getUint32(ptr + 20, Endian.little);
        final nameLen = bd.getUint16(ptr + 28, Endian.little);
        final extraLen = bd.getUint16(ptr + 30, Endian.little);
        final commentLen = bd.getUint16(ptr + 32, Endian.little);
        final localHeaderOffset = bd.getUint32(ptr + 42, Endian.little);
        if (ptr + 46 + nameLen > bytes.length) break;
        final entryName = utf8.decode(
          bytes.sublist(ptr + 46, ptr + 46 + nameLen),
          allowMalformed: true,
        );
        ptr += 46 + nameLen + extraLen + commentLen;
        if (!wantedNames.contains(entryName)) continue;
        if (localHeaderOffset + 30 > bytes.length) continue;
        final localNameLen = bd.getUint16(localHeaderOffset + 26, Endian.little);
        final localExtraLen = bd.getUint16(
          localHeaderOffset + 28,
          Endian.little,
        );
        final dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen;
        if (dataStart + compSize > bytes.length) continue;
        final compSlice = bytes.sublist(dataStart, dataStart + compSize);
        try {
          final rawBytes = method == 0
              ? compSlice
              : (method == 8
                    ? ZLibCodec(raw: true).decode(compSlice)
                    : const <int>[]);
          if (rawBytes.isNotEmpty) {
            out[entryName] = utf8.decode(rawBytes, allowMalformed: true);
          }
        } catch (_) {}
      }
    }
    return out;
  }

  static String _extractPdfTextStreams(Uint8List bytes) {
    final rawLatin = latin1.decode(bytes, allowInvalid: true);
    final streamRe = RegExp(r'stream\r?\n([\s\S]*?)\r?\nendstream');
    final chunks = <String>[];
    for (final m in streamRe.allMatches(rawLatin)) {
      final streamStart =
          m.start + (rawLatin.startsWith('stream\r\n', m.start) ? 8 : 7);
      final streamEnd = m.end -
          (rawLatin.substring(m.start, m.end).endsWith('\r\nendstream')
              ? 11
              : 10);
      if (streamEnd <= streamStart || streamEnd > bytes.length) continue;
      final slice = bytes.sublist(streamStart, streamEnd);
      var decodedStream = '';
      try {
        decodedStream = latin1.decode(zlib.decode(slice), allowInvalid: true);
      } catch (_) {
        try {
          decodedStream = latin1.decode(
            ZLibCodec(raw: true).decode(slice),
            allowInvalid: true,
          );
        } catch (_) {
          decodedStream = m.group(1) ?? '';
        }
      }
      if (!decodedStream.contains('Tj') && !decodedStream.contains('TJ')) {
        continue;
      }
      for (final tj in RegExp(r'\(([^()\\]*(?:\\.[^()\\]*)*)\)\s*Tj')
          .allMatches(decodedStream)) {
        chunks.add(_unescapePdfLiteral(tj.group(1) ?? ''));
      }
      for (final tjArr
          in RegExp(r'\[([\s\S]*?)\]\s*TJ').allMatches(decodedStream)) {
        final arrBody = tjArr.group(1) ?? '';
        final lineBuf = StringBuffer();
        for (final lit in RegExp(r'\(([^()\\]*(?:\\.[^()\\]*)*)\)')
            .allMatches(arrBody)) {
          lineBuf.write(_unescapePdfLiteral(lit.group(1) ?? ''));
        }
        if (lineBuf.isNotEmpty) chunks.add(lineBuf.toString());
      }
    }
    return chunks
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join('\n')
        .trim();
  }

  static String _unescapePdfLiteral(String s) {
    return s
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\r')
        .replaceAll(r'\t', '\t')
        .replaceAll(r'\(', '(')
        .replaceAll(r'\)', ')')
        .replaceAll(r'\\', '\\');
  }

  static String _decodeXmlEntities(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }
}
