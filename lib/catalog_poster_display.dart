/// Controls how catalog artwork is presented while an already-known TMDB ID
/// is being resolved. No scraping or title/year matching is performed here.
class CatalogPosterDisplay {
  CatalogPosterDisplay._();

  static bool isTmdbArtwork(String poster) {
    final value = poster.trim();
    return value.startsWith('/') ||
        value.startsWith('https://image.tmdb.org/t/p/');
  }

  /// Home "Lihat Lainnya" gets TMDB artwork with its ranked response.
  /// For Film/Series/Filter entries with a verified TMDB ID but no TMDB poster
  /// path yet, keep the same dark placeholder until the detail request ends.
  /// For source-only titles, display LK21 artwork immediately.
  static bool waitsForVerifiedTmdb({
    required String poster,
    required int? tmdbId,
  }) => tmdbId != null && tmdbId > 0 && !isTmdbArtwork(poster);
}
