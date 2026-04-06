import 'ayudas_api_models.dart';

/// Filtro de busqueda (titulo, VIN, subcategoria, tags, #hashtag).
bool ayudasDocumentMatchesQuery(Map<String, dynamic> m, String qRaw) {
  final q = qRaw.trim().toLowerCase();
  if (q.isEmpty) return true;
  final title = ayudasTituloDocumento(m).toLowerCase();
  final vin = ayudasVin(m).toLowerCase();
  final sub = ayudasSubcategoriaProceso(m).toLowerCase();
  final cat = (m['_nombre_categoria'] ?? '').toString().toLowerCase();
  final tags = ayudasTags(m).map((e) => e.toLowerCase()).toList();
  final tagsFlat = tags.join(' ');
  if (title.contains(q) || vin.contains(q) || sub.contains(q)) return true;
  if (cat.isNotEmpty && cat.contains(q)) return true;
  if (tags.any((t) => t.contains(q))) return true;
  if (tagsFlat.contains(q)) return true;
  if (q.contains('#')) {
    for (final mch in RegExp(r'#(\w+)').allMatches(q)) {
      final tok = mch.group(1)?.toLowerCase() ?? '';
      if (tok.isEmpty) return true;
      if (tags.any((t) => t.contains(tok) || tok == t)) return true;
      if (title.contains(tok) || vin.contains(tok) || sub.contains(tok)) return true;
      if (cat.contains(tok)) return true;
    }
  }
  return false;
}

int ayudasMatchScoreForQuery(Map<String, dynamic> m, String qRaw) {
  final q = qRaw.trim().toLowerCase();
  if (q.isEmpty) return 0;
  final tags = ayudasTags(m).map((e) => e.toLowerCase()).toList();
  int score = 0;
  if (q.contains('#')) {
    for (final mch in RegExp(r'#(\w+)').allMatches(q)) {
      final tok = mch.group(1)?.toLowerCase() ?? '';
      if (tok.isEmpty) continue;
      for (final t in tags) {
        if (t == tok || t.contains(tok)) score += 4;
      }
    }
  } else {
    for (final t in tags) {
      if (t.contains(q)) score += 2;
    }
  }
  return score;
}

List<String> ayudasAllTagsFromDocs(Iterable<Map<String, dynamic>> docs) {
  final s = <String>{};
  for (final d in docs) {
    s.addAll(ayudasTags(d));
  }
  final list = s.toList();
  list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return list;
}

List<String> ayudasTagSuggestionsForQuery(String text, List<String> pool) {
  final match = RegExp(r'#(\w*)$').firstMatch(text);
  if (match == null) return [];
  final pref = match.group(1)!.toLowerCase();
  return pool
      .where((x) => pref.isEmpty || x.toLowerCase().startsWith(pref))
      .take(24)
      .toList();
}
