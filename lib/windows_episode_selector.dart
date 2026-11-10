import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'filmstream_icons.dart';

/// Compact Windows-only selector. The numbers are sourced from the existing
/// WebView2 LK21 page scan; this widget never invents seasons or episode URLs.
class WindowsEpisodeSelector extends StatelessWidget {
  final List<int> seasons;
  final int? selectedSeason;
  final List<int> episodes;
  final Set<String> openedEpisodes;
  final bool loadingSeasons;
  final bool loadingEpisodes;
  final bool changingSeason;
  final String? error;
  final ValueChanged<int> onSeasonSelected;
  final ValueChanged<int> onEpisodeSelected;

  const WindowsEpisodeSelector({
    super.key,
    required this.seasons,
    required this.selectedSeason,
    required this.episodes,
    required this.openedEpisodes,
    required this.onSeasonSelected,
    required this.onEpisodeSelected,
    this.loadingSeasons = false,
    this.loadingEpisodes = false,
    this.changingSeason = false,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xffe5aa55);
    final active = selectedSeason != null &&
            seasons.contains(selectedSeason)
        ? selectedSeason
        : (seasons.isEmpty ? null : seasons.first);
    final sortedEpisodes = episodes.where((n) => n > 0).toSet().toList()..sort();
    final showEpisodes = active != null && !changingSeason;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Expanded(
            child: Text('Season & Episode',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          if (seasons.isNotEmpty)
            Text('${seasons.length} season',
                style: const TextStyle(fontSize: 12, color: Colors.white60)),
        ]),
        const SizedBox(height: 11),
        if (loadingSeasons && seasons.isEmpty) ...[
          const LinearProgressIndicator(minHeight: 3),
          const SizedBox(height: 8),
          const Text('Memuat season dari sumber...',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
        ],
        if (error != null && error!.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Text(error!, style: const TextStyle(color: Colors.orangeAccent)),
          ),
        if (seasons.isEmpty && !loadingSeasons)
          const Text('Season belum ditemukan dari halaman sumber.',
              style: TextStyle(color: Colors.white70)),
        if (active != null) ...[
          Container(
            key: const ValueKey('windows-season-control'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xff20242d),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xff4c4235)),
            ),
            child: Row(children: [
              const Icon(FilmStreamIcons.series, color: gold, size: 21),
              const SizedBox(width: 11),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    key: const ValueKey('windows-season-dropdown'),
                    value: active,
                    isExpanded: true,
                    dropdownColor: const Color(0xff232832),
                    borderRadius: BorderRadius.circular(12),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded,
                        color: gold),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700,
                        fontSize: 14),
                    onChanged: changingSeason ? null : (n) {
                      if (n != null && n != active) onSeasonSelected(n);
                    },
                    items: [
                      for (final n in seasons)
                        DropdownMenuItem<int>(
                          value: n, child: Text('Season $n'),
                        ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 17),
          Row(children: [
            Expanded(child: Text('Episode · Season $active',
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 16))),
            if (showEpisodes && sortedEpisodes.isNotEmpty)
              Text('${sortedEpisodes.length} episode',
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 12)),
          ]),
          const SizedBox(height: 8),
          if (changingSeason || loadingEpisodes) ...[
            const LinearProgressIndicator(minHeight: 3),
            const SizedBox(height: 10),
            Text(
              changingSeason
                  ? 'Mengganti ke Season $active...'
                  : 'Memuat episode dari sumber...',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ] else if (sortedEpisodes.isEmpty) ...[
            const Text('Episode belum tersedia dari sumber.',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
          ] else
            LayoutBuilder(builder: (context, constraints) {
              final width = constraints.maxWidth;
              final columns = width >= 570 ? 3 : width >= 320 ? 2 : 1;
              const itemHeight = 64.0;
              const spacing = 8.0;
              final rows = (sortedEpisodes.length / columns).ceil();
              final height = math.min(
                304.0, rows * itemHeight + math.max(0, rows - 1) * spacing,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: height,
                    child: GridView.builder(
                      key: ValueKey('windows-episode-grid-$active'),
                      primary: false,
                      physics: const ClampingScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: itemHeight,
                        mainAxisSpacing: spacing,
                        crossAxisSpacing: spacing,
                      ),
                      itemCount: sortedEpisodes.length,
                      itemBuilder: (context, index) {
                        final number = sortedEpisodes[index];
                        final opened = openedEpisodes.contains('$active:$number');
                        return Material(
                          color: opened
                              ? const Color(0xff28372e)
                              : const Color(0xff20242d),
                          borderRadius: BorderRadius.circular(11),
                          child: InkWell(
                            key: ValueKey('windows-episode-$active-$number'),
                            onTap: () => onEpisodeSelected(number),
                            borderRadius: BorderRadius.circular(11),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 11),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(11),
                                border: Border.all(
                                  color: opened
                                      ? const Color(0xff5b7f63)
                                      : const Color(0xff424751),
                                ),
                              ),
                              child: Row(children: [
                                Icon(
                                  opened
                                      ? FilmStreamIcons.completed
                                      : FilmStreamIcons.play,
                                  color: opened
                                      ? const Color(0xff99d5a8) : gold,
                                  size: 23,
                                ),
                                const SizedBox(width: 9),
                                Expanded(child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Episode $number',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 2),
                                    Text(opened ? 'Pernah dibuka' : 'Putar episode',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 10.5,
                                            color: Colors.white60)),
                                  ],
                                )),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (height >= 304 && rows > 1)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('Gulir untuk melihat episode lainnya',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 11)),
                    ),
                ],
              );
            }),
        ],
      ],
    );
  }
}
