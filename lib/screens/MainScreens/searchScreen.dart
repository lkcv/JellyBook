// The purpose of this screen is to allow the user to search for a specific book/comic
import 'dart:async';
import 'dart:ffi';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:isar_flutter_libs/isar_flutter_libs.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/providers/supportedFormats.dart';
import 'package:jellybook/screens/readingScreen.dart';
import 'package:jellybook/screens/readingScreens/cbzReader.dart';
import 'package:jellybook/providers/readerPageCache.dart';
import 'package:jellybook/providers/connectionManager.dart';
import 'package:jellybook/widgets/coverOpeningRoute.dart';
import 'package:jellybook/widgets/volumeActions.dart';
import 'package:provider/provider.dart';
import 'package:string_similarity/string_similarity.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/themes/themeConstants.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/screens/collectionScreen.dart' show KuroStyleBookCard;

// Match the Library's two 17.5px concave header corners while leaving the
// middle transparent for content scrolling behind the header.
class _SearchHeaderCornersPainter extends CustomPainter {
  const _SearchHeaderCornersPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, ui.Size size) {
    final r = min(size.height, size.width / 2);
    if (r <= 0) return;
    final paint = Paint()..color = color;
    final cornerRadius = Radius.circular(r);

    final left = Path()
      ..moveTo(0, 0)
      ..lineTo(r, 0)
      ..arcToPoint(Offset(0, r), radius: cornerRadius, clockwise: false)
      ..close();
    final right = Path()
      ..moveTo(size.width - r, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, r)
      ..arcToPoint(Offset(size.width - r, 0),
          radius: cornerRadius, clockwise: false)
      ..close();

    canvas.drawPath(left, paint);
    canvas.drawPath(right, paint);
  }

  @override
  bool shouldRepaint(covariant _SearchHeaderCornersPainter oldDelegate) =>
      oldDelegate.color != color;
}

class SearchScreen extends StatefulWidget {
  /// Called when the user leaves Search (back arrow or system back).
  /// Used by the bottom-nav host to restore the previous tab.
  final VoidCallback? onBack;

  SearchScreen({super.key, this.onBack});

  @override
  _SearchScreenState createState() => _SearchScreenState();
}

// _SearchScreenState
class _SearchScreenState extends State<SearchScreen> with WidgetsBindingObserver {
  static const double _headerCornerRadius = 17.5;

  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  bool _keyboardWasVisible = false;
  // A tap outside, a scroll, or Enter should hide the IME without leaving Search.
  bool _keepSearchOnKeyboardClose = false;
  bool _leavingSearch = false;
  final _resultsScrollController = ScrollController();
  final isar = Isar.getInstance();
  List<Entry> _catalog = [];
  bool _catalogReady = false;
  int _catalogVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshCatalog();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;

    // Android Back can hide the IME without unfocusing the TextField.
    // Only unfocus once the keyboard is fully hidden, so we do not
    // interfere with its dismissal animation.
    final keyboardVisible = View.of(context).viewInsets.bottom > 0;
    if (keyboardVisible) {
      // Only reset when a *new* keyboard session starts, not on every inset
      // update during its closing animation.
      if (!_keyboardWasVisible) _keepSearchOnKeyboardClose = false;
      _keyboardWasVisible = true;
    } else if (_keyboardWasVisible) {
      _keyboardWasVisible = false;
      final stay = _keepSearchOnKeyboardClose;
      _keepSearchOnKeyboardClose = false;
      _searchFocusNode.unfocus();

      // Android normally consumes Back to hide its keyboard. For an abandoned
      // empty search, use that completed dismissal as the signal to go back.
      // A deliberately dismissed keyboard (tap, scroll, Enter) stays here.
      if (!stay &&
          _searchController.text.trim().isEmpty &&
          Theme.of(context).platform == TargetPlatform.android) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              _leavingSearch ||
              _keyboardWasVisible ||
              _searchFocusNode.hasFocus ||
              _searchController.text.trim().isNotEmpty ||
              !(ModalRoute.of(context)?.isCurrent ?? false)) {
            return;
          }
          final lifecycle = WidgetsBinding.instance.lifecycleState;
          if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
            return;
          }
          _handleBack();
        });
      }
    }
  }

  Future<void> _refreshCatalog() async {
    final version = ++_catalogVersion;
    final books = await isar!.entrys
        .filter()
        .typeEqualTo(EntryType.book)
        .or()
        .typeEqualTo(EntryType.comic)
        .findAll();
    if (!mounted || version != _catalogVersion) return;
    _catalog = books.where(isSupportedEntry).toList();
    _catalogReady = true;
    getSearchResults(_searchController.text);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchFocusNode.dispose();
    _searchController.dispose();
    _resultsScrollController.dispose();
    super.dispose();
  }

  // Search is a bottom-navigation tab. A reader pushed from here should pop
  // back to the same query and scroll position, not open the Collection.
  Future<void> _openResult(Entry entry, Rect sourceRect) async {
    if (!mounted || !isSupportedEntry(entry)) return;

    final connectionStatus = context.read<ConnectionManager>().status;
    if (connectionStatus == ConnectionStatus.offline && !entry.downloaded) {
      final cachedIndex =
          await ReaderPageCache.getCurrentPage(entry.id) ?? entry.pageNum;
      final cachedPage = await ReaderPageCache.getPage(entry.id, cachedIndex);
      if (!mounted) return;
      if (cachedPage == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Server is offline and this page is not cached'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }
    }

    final extension = entryFileExtension(entry.path);
    final isArchive = const ['cbz', 'zip'].contains(extension);
    final streamable = extension == 'cbz';
    if (isArchive && (entry.downloaded || streamable)) {
      final firstPageReady = ValueNotifier<bool>(false);
      final skipReturnFade = ValueNotifier<bool>(false);
      final route = CoverOpeningRoute<void>(
        sourceRect: sourceRect,
        coverPath: entry.imagePath,
        pageReady: firstPageReady,
        skipReturnFade: skipReturnFade,
        builder: (context) => CbzReader(
          title: entry.title,
          comicId: entry.id,
          openedDirectly: true,
          openingReady: firstPageReady,
          skipReturnFade: skipReturnFade,
        ),
      );
      await Navigator.of(context).push<void>(route);
      // push() completes when pop starts, not after the cover shrinks.
      // Avoid rebuilding the underlying search list during that animation.
      await route.completed;
    } else if (entry.downloaded) {
      final route = MaterialPageRoute<void>(
        builder: (context) => ReadingScreen(
          title: entry.title,
          comicId: entry.id,
        ),
      );
      await Navigator.of(context).push<void>(route);
      await route.completed;
    } else {
      await _openVolumeActions(entry);
      return;
    }

    if (mounted) await _refreshCatalog();
  }

  // Search uses the same volume actions as Collection, without losing its
  // query, grid position, or the direct Reader opening animation.
  Future<void> _openVolumeActions(Entry entry) => showVolumeActions(
        context,
        entry,
        onChanged: (_) {
          if (mounted) unawaited(_refreshCatalog());
        },
      );

  List<Entry> searchResults = [];
  // List<Map<String, dynamic>> searchResults = [];

  void _onQueryChanged(String query) {
    if (_resultsScrollController.hasClients) {
      _resultsScrollController.jumpTo(0);
    }
    getSearchResults(query);
  }

  void _dismissKeyboardAndStay() {
    if (_keyboardWasVisible || _searchFocusNode.hasFocus) {
      _keepSearchOnKeyboardClose = true;
      _searchFocusNode.unfocus();
    }
  }

  void _handleBack() {
    if (_leavingSearch) return;
    _leavingSearch = true;
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      Navigator.of(context).maybePop().then((popped) {
        if (mounted && !popped) _leavingSearch = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final headerBrightness = Theme.of(context).brightness;
    final headerBackground =
        FloatingSurfacePalette.topBarBackground(headerBrightness);
    final headerForeground =
        FloatingSurfacePalette.foreground(headerBrightness);
    // Intercept Android system/gesture back. iOS edge-swipe only works for
    // pushed routes; Search is a tab, so the leading control covers that case.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          // Some Android configurations deliver Back to PopScope even with
          // the IME open; preserve the normal first-Back behavior for text.
          if (_keyboardWasVisible &&
              _searchController.text.trim().isNotEmpty) {
            _dismissKeyboardAndStay();
          } else {
            _handleBack();
          }
        }
      },
      child: Scaffold(
      // Let results scroll behind the 90%-opaque header; the grid below
      // reserves the header height so its first row is fully visible.
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        // Settings-style translucent header with breathing room around the pill.
        preferredSize: ui.Size.fromHeight(MediaQuery.of(context).padding.top + 48),
        child: Container(
          color: headerBackground,
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
          child: SizedBox(
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // Paint below the header without intercepting search gestures.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: -_headerCornerRadius,
                  height: _headerCornerRadius,
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _SearchHeaderCornersPainter(
                        color: headerBackground,
                      ),
                    ),
                  ),
                ),
                // Equal left/right margins center the pill on the *screen*,
                // rather than in the space remaining after the back button.
                Positioned.fill(
                  left: 48,
                  right: 48,
                  child: Center(
                    child: Container(
                      height: 36,
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor.withOpacity(0.90),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: TextField(
                        autofocus: true,
                        focusNode: _searchFocusNode,
                        controller: _searchController,
                        textAlignVertical: TextAlignVertical.center,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          prefixIcon: const Icon(Icons.search),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 36,
                          ),
                          hintText: (AppLocalizations.of(context)?.search ??
                                  'Search') +
                              '...',
                          border: InputBorder.none,
                        ),
                        onChanged: _onQueryChanged,
                        // Enter/Done is a deliberate keyboard dismissal, not
                        // an attempt to exit an empty search.
                        onEditingComplete: _dismissKeyboardAndStay,
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: Icon(Icons.arrow_back, color: headerForeground),
                    tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                    onPressed: _handleBack,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 36,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),

      // Only a completed tap counts as an outside tap. A pointer-down
      // listener here would also intercept the start of Android's edge Back.
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _dismissKeyboardAndStay,
        child: searchResults.isEmpty
          ? _searchController.text.trim().isEmpty
              ? Center(
                  child: Text(
                      AppLocalizations.of(context)?.searchBook ??
                          'Please search for a book',
                      style: const TextStyle(
                        fontSize: 20,
                      )),
                )
              : !_catalogReady
                  ? const Center(child: CircularProgressIndicator())
                  : Center(
                      child: Text(
                          AppLocalizations.of(context)?.noResults ??
                              'No results found',
                          style: const TextStyle(fontSize: 20)),
                    )
          : NotificationListener<ScrollStartNotification>(
              onNotification: (notification) {
                if (notification.dragDetails != null) {
                  _dismissKeyboardAndStay();
                }
                return false;
              },
              child: GridView.builder(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              controller: _resultsScrollController,
              padding: EdgeInsets.fromLTRB(
                10,
                MediaQuery.of(context).padding.top + 48 + 8,
                10,
                8,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 12,
                childAspectRatio: 0.62,
              ),
              itemCount: searchResults.length,
              itemBuilder: (context, i) {
                final entry = searchResults[i];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: KuroStyleBookCard(
                        entry: entry,
                        onEntryTapped: (coverRect) =>
                            _openResult(entry, coverRect),
                        onEntryLongPressed: () => _openVolumeActions(entry),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                    ),
                  ],
                );
              },
              ),
            ),
      ),
    ),  // Scaffold
    );  // PopScope
  }

  void getSearchResults(String searchQuery) {
    final query = searchQuery.trim().toLowerCase();
    if (query.isEmpty || !_catalogReady) {
      setState(() => searchResults = []);
      return;
    }

    // Title matches come first, so typing a series name remains predictable.
    // Preserve the existing fuzzy search for queries with no direct matches.
    final direct = _catalog
        .where((entry) => entry.title.toLowerCase().contains(query))
        .toList();
    final matches = direct.isNotEmpty
        ? direct
        : diceCoefficientRankings(query, _catalog);
    matches.sort((a, b) => _naturalTitleCompare(a.title, b.title));
    setState(() => searchResults = matches);
  }

  // Compare runs of digits numerically: Volume 2 before Volume 10.
  static final RegExp _titleParts = RegExp(r'\d+|\D+');

  int _naturalTitleCompare(String a, String b) {
    final aParts = _titleParts.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
    final bParts = _titleParts.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
    final count = min(aParts.length, bParts.length);
    for (var i = 0; i < count; i++) {
      final left = aParts[i];
      final right = bParts[i];
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      final comparison = leftNumber != null && rightNumber != null
          ? leftNumber.compareTo(rightNumber)
          : left.compareTo(right);
      if (comparison != 0) return comparison;
    }
    return aParts.length.compareTo(bParts.length);
  }

  List<Entry> diceCoefficientRankings(String searchQuery, List<Entry> books) {
    // first we will use the entire search query, then we will compare the individual words in the search query to the individual words in the title
    searchQuery = searchQuery.toLowerCase();
    List<String> titles = [];
    List<Map<double, Entry>> rankings = [];
    books.forEach((element) {
      titles.add(element.title.toLowerCase());
    });

    titles.forEach((element) {
      // rank similarity of the entire search query to the title
      double similarity = searchQuery.similarityTo(element);
      List<String> searchWords = searchQuery.split(" ");
      List<String> titleWords = element.split(" ");

      // now we will compare the individual words in the search query to the individual words in the title
      double wordSimilarity = 0;
      searchWords.forEach((searchWord) {
        titleWords.forEach((titleWord) {
          wordSimilarity += searchWord.similarityTo(titleWord);
        });
      });
      wordSimilarity =
          wordSimilarity / (searchWords.length * titleWords.length);

      double finalSimilarity = (similarity + 2 * wordSimilarity) / 2;

      rankings.add({finalSimilarity: books[titles.indexOf(element)]});
    });
    // now we will sort the rankings
    rankings.sort((a, b) => b.keys.first.compareTo(a.keys.first));
    // now we will convert the rankings to a list of books
    List<Entry> results = [];
    rankings.forEach((element) {
      results.add(element.values.first);
    });
    double div = searchQuery.length / 10;
    // remove anything before the decimal
    div = div - div.floor();

    return results
        .where((element) =>
            rankings[results.indexOf(element)].keys.first >= 0.4 * (1 - div))
        .toList();
  }

  List<Entry> diceCoefficientRankings2(String searchQuery, List<Entry> books) {
    searchQuery = searchQuery.toLowerCase();
    List<String> titles = [];
    List<Map<double, Entry>> rankings = [];
    books.forEach((element) {
      titles.add(element.title.toLowerCase());
    });

    titles.forEach((element) {
      // rank similarity of the entire search query to the title
      double similarity = searchQuery.similarityTo(element);
      List<String> searchWords = searchQuery.split(" ");
      List<String> titleWords = element.split(" ");

      // now we will compare the individual words in the search query to the individual words in the title
      double wordSimilarity = 0;
      searchWords.forEach((searchWord) {
        titleWords.forEach((titleWord) {
          wordSimilarity += searchWord.similarityTo(titleWord);
        });
      });
      wordSimilarity =
          wordSimilarity / (searchWords.length * titleWords.length);

      double finalSimilarity = (similarity + 2 * wordSimilarity) / 2;

      rankings.add({finalSimilarity: books[titles.indexOf(element)]});
    });

    // Use quicksort to sort the rankings
    quicksort(rankings, 0, rankings.length - 1);

    // now we will convert the rankings to a list of books
    List<Entry> results = [];
    rankings.forEach((element) {
      results.add(element.values.first);
    });
    double div = searchQuery.length / 10;
    // remove anything before the decimal
    div = div - div.floor();

// return first 20 results (or less if there are less than 20 results)
    return results.toList().sublist(0, min(20, results.length));

    // return results
    //     .where((element) =>
    //         rankings[results.indexOf(element)].keys.first >= 0.4 * (1 - div))
    //     .toList();
  }

  void quicksort(List<Map<double, Entry>> rankings, int low, int high) {
    if (low < high) {
      int pivotIndex = partition(rankings, low, high);
      quicksort(rankings, low, pivotIndex - 1);
      quicksort(rankings, pivotIndex + 1, high);
    }
  }

  int partition(List<Map<double, Entry>> rankings, int low, int high) {
    double pivot = rankings[high].keys.first;
    int i = low - 1;
    for (int j = low; j < high; j++) {
      if (rankings[j].keys.first < pivot) {
        i++;
        Map<double, Entry> temp = rankings[i];
        rankings[i] = rankings[j];
        rankings[j] = temp;
      }
    }
    Map<double, Entry> temp = rankings[i + 1];
    rankings[i + 1] = rankings[high];
    rankings[high] = temp;
    return i + 1;
  }
}
