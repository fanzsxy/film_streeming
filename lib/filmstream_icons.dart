import 'package:flutter/widgets.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// One consistent Phosphor icon family for FilmStream's primary navigation,
/// genre discovery and top-bar actions. Keep icons independent of genre labels:
/// the catalog uses TMDB genre IDs in Indonesian and English.
class FilmStreamIcons {
  FilmStreamIcons._();

  // Navigation: regular when idle, solid when selected.
  static const home = PhosphorIconsRegular.house;
  static const homeSelected = PhosphorIconsFill.house;
  static const film = PhosphorIconsRegular.filmSlate;
  static const filmSelected = PhosphorIconsFill.filmSlate;
  static const series = PhosphorIconsRegular.monitorPlay;
  static const seriesSelected = PhosphorIconsFill.monitorPlay;
  static const filter = PhosphorIconsRegular.slidersHorizontal;
  static const filterSelected = PhosphorIconsFill.slidersHorizontal;
  static const favorites = PhosphorIconsRegular.heart;
  static const favoritesSelected = PhosphorIconsFill.heart;

  // One navigation definition for Android's bottom bar and Windows'
  // desktop sidebar. The order matches the HomePage tab switch.
  static const navigationLabels = <String>[
    'Beranda', 'Film', 'Series', 'Filter', 'Favorit',
  ];

  static IconData navigationIcon(int index, {bool selected = false}) {
    switch (index) {
      case 0: return selected ? homeSelected : home;
      case 1: return selected ? filmSelected : film;
      case 2: return selected ? seriesSelected : series;
      case 3: return selected ? filterSelected : filter;
      case 4: return selected ? favoritesSelected : favorites;
      default: throw RangeError.index(index, navigationLabels, 'index');
    }
  }

  static const desktopMenu = PhosphorIconsRegular.list;
  static const search = PhosphorIconsRegular.magnifyingGlass;
  static const clear = PhosphorIconsRegular.x;
  static const reload = PhosphorIconsRegular.arrowClockwise;
  static const play = PhosphorIconsRegular.playCircle;
  static const completed = PhosphorIconsFill.checkCircle;
  static const sourcePage = PhosphorIconsRegular.fileText;

  // Header.
  static const brand = PhosphorIconsFill.filmStrip;
  static const history = PhosphorIconsRegular.clockCounterClockwise;
  static const info = PhosphorIconsRegular.info;

  // Genre icons stay bold, golden and recognizable at small phone sizes.
  static IconData genre(int id) {
    switch (id) {
      case 28: return PhosphorIconsFill.lightning; // Action
      case 12: return PhosphorIconsFill.compass; // Adventure
      case 10759: return PhosphorIconsFill.mapTrifold; // Action & Adventure
      case 16: return PhosphorIconsFill.filmStrip; // Animation
      case 35: return PhosphorIconsFill.smiley; // Comedy
      case 80: return PhosphorIconsFill.detective; // Crime
      case 99: return PhosphorIconsFill.videoCamera; // Documentary
      case 18: return PhosphorIconsFill.maskHappy; // Drama
      case 10751: return PhosphorIconsFill.usersThree; // Family
      case 14: return PhosphorIconsFill.magicWand; // Fantasy
      case 10765: return PhosphorIconsFill.alien; // Sci-Fi & Fantasy
      case 36: return PhosphorIconsFill.scroll; // History
      case 10768: return PhosphorIconsFill.shieldChevron; // War & Politics
      case 27: return PhosphorIconsFill.ghost; // Horror
      case 10402: return PhosphorIconsFill.musicNotes; // Music
      case 9648: return PhosphorIconsFill.magnifyingGlass; // Mystery
      case 10749: return PhosphorIconsFill.heart; // Romance
      case 878: return PhosphorIconsFill.rocketLaunch; // Science fiction
      case 53: return PhosphorIconsFill.eye; // Thriller
      case 10752: return PhosphorIconsFill.shieldChevron; // War
      case 37: return PhosphorIconsFill.mountains; // Western
      case 10762: return PhosphorIconsFill.baby; // Kids
      case 10763: return PhosphorIconsFill.chatCircle; // News
      case 10764: return PhosphorIconsFill.star; // Reality
      default: return PhosphorIconsFill.tag;
    }
  }
}
