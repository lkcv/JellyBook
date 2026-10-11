// The purpose of this screen is to allow the user to search for a specific book/comic
import 'dart:ffi';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:isar_flutter_libs/isar_flutter_libs.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/screens/infoScreen.dart';
import 'package:jellybook/screens/readingScreen.dart';
import 'package:jellybook/screens/readingScreens/cbrCbzReader.dart';
import 'package:jellybook/providers/readerPageCache.dart';
import 'package:jellybook/providers/connectionManager.dart';
import 'package:jellybook/widgets/coverOpeningRoute.dart';
import 'package:provider/provider.dart';
import 'package:string_similarity/string_similarity.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/screens/collectionScreen.dart' show KuroStyleBookCard;

class SearchScreen extends StatefulWidget {
  /// Called when the user leaves Search (back arrow or system back).
  /// Used by the bottom-nav host to restore the previous tab.
  final VoidCallback? onBack;

  SearchScreen({super.key, this.onBack});

  @override
  _SearchScreenState createState() => _SearchScreenState();
}

// _SearchScreenState
class _SearchScreenState extends State<SearchScreen> {
  final _searchController = TextEditingController();
  final _resultsScrollController = ScrollController();
  final isar = Isar.getInstance();
  List<Entry> _catalog = [];
  bool _catalogReady = false;
  int _catalogVersion = 0;

  @override
  void initState() {
    super.initState();
    _refreshCatalog();
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
    _catalog = books;
    _catalogReady = true;
    getSearchResults(_searchController.text);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _resultsScrollController.dispose();
    super.dispose();
  }

  // Search is a bottom-navigation tab. A reader pushed from here should pop
  // back to the same query and scroll position, not open the Collection.
  Future<void> _openResult(Entry entry, Rect sourceRect) async {
    if (!mounted) return;

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

    final extension = entry.path.split('.').last.toLowerCase();
    final isArchive = const ['cbz', 'cbr', 'zip', 'rar'].contains(extension);
    final streamable = extension == 'cbz' || extension == 'cbr';
    if (isArchive && (entry.downloaded || streamable)) {
      final firstPageReady = ValueNotifier<bool>(false);
      final skipReturnFade = ValueNotifier<bool>(false);
      final route = CoverOpeningRoute<void>(
        sourceRect: sourceRect,
        coverPath: entry.imagePath,
        pageReady: firstPageReady,
        skipReturnFade: skipReturnFade,
        builder: (context) => CbrCbzReader(
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
      await _openInfo(entry);
      return;
    }

    if (mounted) await _refreshCatalog();
  }

  Future<void> _openInfo(Entry entry) async {
    final route = MaterialPageRoute<dynamic>(
      builder: (context) => InfoScreen(entry: entry),
    );
    await Navigator.of(context).push<dynamic>(route);
    await route.completed;
    if (mounted) await _refreshCatalog();
  }

  List<Entry> searchResults = [];
  // List<Map<String, dynamic>> searchResults = [];

  void _onQueryChanged(String query) {
    if (_resultsScrollController.hasClients) {
      _resultsScrollController.jumpTo(0);
    }
    getSearchResults(query);
  }

  void _handleBack() {
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Intercept Android system/gesture back. iOS edge-swipe only works for
    // pushed routes; Search is a tab, so the leading control covers that case.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          _handleBack();
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
          color: Colors.black.withOpacity(0.90),
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
          child: SizedBox(
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
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
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
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

      // body based on if searchResults is 0 or not
      body: searchResults.isEmpty
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
          : GridView.builder(
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
                        onEntryLongPressed: () => _openInfo(entry),
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
