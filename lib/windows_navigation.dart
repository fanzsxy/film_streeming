import 'package:flutter/material.dart';

import 'filmstream_icons.dart';

/// Desktop equivalent of Android's five-item bottom NavigationBar.
///
/// This widget has no Windows-only runtime dependencies, so its behavior can
/// be tested on Linux CI. It is only mounted by DesktopShell on Windows.
class WindowsNavigationRail extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final double availableWidth;

  const WindowsNavigationRail({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.availableWidth,
  });

  @override
  State<WindowsNavigationRail> createState() => _WindowsNavigationRailState();
}

class _WindowsNavigationRailState extends State<WindowsNavigationRail> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) {
    final isWide = widget.availableWidth >= 950;
    final showLabels = expanded && isWide;
    final width = expanded ? (isWide ? 232.0 : 76.0) : 60.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      width: width,
      decoration: const BoxDecoration(
        color: Color(0xff171b22),
        border: Border(right: BorderSide(color: Color(0xff30343d))),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 14),
          child: IconButton(
            key: const ValueKey('windows-nav-toggle'),
            tooltip: expanded ? 'Perkecil menu' : 'Perluas menu',
            icon: const Icon(FilmStreamIcons.desktopMenu, size: 25),
            color: const Color(0xffe5aa55),
            onPressed: () => setState(() => expanded = !expanded),
          ),
        ),
        if (showLabels)
          const Padding(
            padding: EdgeInsets.only(bottom: 26, top: 10),
            child: Text(
              'FILM STREAMING',
              style: TextStyle(
                color: Color(0xffe5aa55),
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        // Keep all five destinations usable even when the rail is collapsed.
        // The old Windows layout removed the entire menu on collapse.
        for (var index = 0;
            index < FilmStreamIcons.navigationLabels.length;
            index++)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 7),
            child: Tooltip(
              message: FilmStreamIcons.navigationLabels[index],
              child: Material(
                borderRadius: BorderRadius.circular(12),
                color: widget.selectedIndex == index
                    ? const Color(0xff493724)
                    : Colors.transparent,
                child: InkWell(
                  key: ValueKey('windows-nav-$index'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => widget.onSelected(index),
                  child: SizedBox(
                    height: 50,
                    width: double.infinity,
                    child: Row(
                      mainAxisAlignment: showLabels
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.center,
                      children: [
                        if (showLabels) const SizedBox(width: 13),
                        Icon(
                          FilmStreamIcons.navigationIcon(
                            index,
                            selected: widget.selectedIndex == index,
                          ),
                          size: 26,
                          color: widget.selectedIndex == index
                              ? const Color(0xffe5aa55)
                              : Colors.white70,
                        ),
                        if (showLabels) ...[
                          const SizedBox(width: 14),
                          Text(
                            FilmStreamIcons.navigationLabels[index],
                            style: TextStyle(
                              fontWeight: widget.selectedIndex == index
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: widget.selectedIndex == index
                                  ? const Color(0xffe5aa55)
                                  : Colors.white70,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        const Spacer(),
        if (showLabels)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Windows Desktop',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
      ]),
    );
  }
}
