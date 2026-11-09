/// Pure, platform-independent display and history decisions shared by the
/// Android detail page and the Windows WebView2 player.
class FilmStreamDetailMetadata {
  FilmStreamDetailMetadata._();

  /// Prefer a source-page description when genuinely available, otherwise use
  /// the already verified catalog/TMDB metadata. Never invent a synopsis.
  static String synopsis({required String source, required String catalog}) {
    final direct = source.trim();
    return direct.isNotEmpty ? direct : catalog.trim();
  }

  /// Catalog genre names have priority because many LK21 catalog entries have
  /// no TMDB ID. TMDB is fallback, then page-specific source metadata.
  static List<String> genres({
    required List<String> catalog,
    required List<String> tmdb,
    required List<String> source,
  }) {
    for (final labels in [catalog, tmdb, source]) {
      final cleaned = labels
          .map((label) => label.trim())
          .where((label) => label.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (cleaned.isNotEmpty) return cleaned;
    }
    return const [];
  }

  /// Source-only titles use stable negative local IDs, not positive TMDB IDs.
  /// They are still legitimate history entries on Windows.
  static bool canRecordOpened(int id, Uri url) =>
      id != 0 &&
      url.scheme == 'https' &&
      url.host.isNotEmpty &&
      url.userInfo.isEmpty &&
      !url.hasPort;
}
