import 'package:flutter/material.dart';

import 'filmstream_icons.dart';

/// Fixed in the Windows AppBar, immediately before the Film Streaming brand.
/// Keeping the toggle outside the sidebar makes it reachable in both states.
class WindowsSidebarToggleButton extends StatelessWidget {
  final bool expanded;
  final VoidCallback onPressed;

  const WindowsSidebarToggleButton({
    super.key,
    required this.expanded,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('windows-nav-toggle'),
    tooltip: expanded ? 'Sembunyikan menu' : 'Tampilkan menu',
    onPressed: onPressed,
    icon: const Icon(FilmStreamIcons.desktopMenu, size: 25),
    color: const Color(0xffe5aa55),
    padding: const EdgeInsets.only(right: 8),
    constraints: const BoxConstraints(minWidth: 42, minHeight: 44),
  );
}

/// Desktop equivalent of Android's five-item navigation.
///
/// Expanded state is owned by the HomePage header so the button does not
/// disappear or move when the rail changes width. Even collapsed, all five
/// destinations remain clickable as icons with tooltips.
class WindowsNavigationRail extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final double availableWidth;
  final bool expanded;

  const WindowsNavigationRail({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.availableWidth,
    this.expanded = true,
  });

  @override
  Widget build(BuildContext context) {
    final isWide = availableWidth >= 950;
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
        const SizedBox(height: 18),
        for (var index = 0;
            index < FilmStreamIcons.navigationLabels.length;
            index++)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 7),
            child: Tooltip(
              message: FilmStreamIcons.navigationLabels[index],
              child: Material(
                borderRadius: BorderRadius.circular(12),
                color: selectedIndex == index
                    ? const Color(0xff493724)
                    : Colors.transparent,
                child: InkWell(
                  key: ValueKey('windows-nav-$index'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onSelected(index),
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
                            selected: selectedIndex == index,
                          ),
                          size: 26,
                          color: selectedIndex == index
                              ? const Color(0xffe5aa55)
                              : Colors.white70,
                        ),
                        if (showLabels) ...[
                          const SizedBox(width: 14),
                          Text(
                            FilmStreamIcons.navigationLabels[index],
                            style: TextStyle(
                              fontWeight: selectedIndex == index
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: selectedIndex == index
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
