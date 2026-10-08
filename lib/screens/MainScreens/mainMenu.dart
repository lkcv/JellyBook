// The purpose of this file is to create the main menu screen (this is part of the list of screens in the bottom navigation bar)
import 'package:flutter/material.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/providers/fetchCategories.dart';
import 'package:jellybook/screens/collectionScreen.dart';
import 'package:jellybook/screens/infoScreen.dart';
import 'package:jellybook/screens/loginScreen.dart';
import 'package:jellybook/screens/MainScreens/searchScreen.dart';
import 'package:jellybook/models/login.dart';
import 'package:isar/isar.dart';
import 'package:isar_flutter_libs/isar_flutter_libs.dart';
import 'package:jellybook/models/entry.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:fancy_shimmer_image/fancy_shimmer_image.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/widgets/roundedImageWithShadow.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:jellybook/providers/connectionManager.dart';

class MainMenu extends StatefulWidget {
  @override
  _MainMenuState createState() => _MainMenuState();
}

class _MainMenuState extends State<MainMenu> {
  static const _pageSize = 20;
  late final PagingController<int, Entry> _pagingController =
      PagingController<int, Entry>(
    getNextPageKey: (state) {
      if (state.pages == null) return 0;
      final lastPage = state.pages!.last;
      if (lastPage.length < _pageSize) return null;
      return state.keys!.last + lastPage.length;
    },
    fetchPage: _fetchPage,
  );

  Future<void> logout() async {
    final isar = Isar.getInstance();
    List<Login> logins = await isar!.logins.where().findAll();
    List<int> loginIds = logins.map((e) => e.isarId).toList();
    List<Entry> entries = await isar.entrys.where().findAll();
    List<int> entryIds = entries.map((e) => e.isarId).toList();
    List<Folder> folders = await isar.folders.where().findAll();
    List<int> folderIds = folders.map((e) => e.isarId).toList();
    await isar.writeTxn(() async {
      logger.i('deleted ${loginIds.length} logins');
      isar.logins.deleteAll(loginIds);
      logger.i('deleted ${entryIds.length} entries');
      isar.entrys.deleteAll(entryIds);
      logger.i('deleted ${folderIds.length} folders');
      isar.folders.deleteAll(folderIds);
    });
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => LoginScreen()),
    );
  }

  bool force = false;
  SharedPreferences? prefs;

  ConnectionManager? _connectionManager;
  bool _wasOffline = false;

  bool _errorModalShowing = false;
  List<Folder>? _lastFolders;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final manager = context.read<ConnectionManager>();
    if (_connectionManager != manager) {
      _connectionManager?.removeListener(_onConnectionChanged);
      _connectionManager = manager;
      _wasOffline = manager.status == ConnectionStatus.offline;
      manager.addListener(_onConnectionChanged);
    }
  }

  String _friendlyError(String error) {
    final e = error.toLowerCase();
    if (e.contains("socketexception") ||
        e.contains("connection") ||
        e.contains("timed out") ||
        e.contains("timeout") ||
        e.contains("host lookup")) {
      return AppLocalizations.of(context)?.serverNotFound ??
          "Could not reach the server. Please check your connection and try again.";
    }
    if (e.contains("401") || e.contains("unauthorized")) {
      return AppLocalizations.of(context)?.invalidCredentials ??
          "Your session has expired. Please log in again.";
    }
    return "Couldn't refresh the library. Please try again.";
  }

  void _onConnectionChanged() {
    final status = _connectionManager!.status;

    if (status == ConnectionStatus.offline) {
      _wasOffline = true;
    } else if (status == ConnectionStatus.online && _wasOffline) {
      // only refresh when we are coming back from being offline
      _wasOffline = false;
      if (mounted) {
        logger.d('MainMenu: connection restored, refreshing library');
        _pagingController.refresh();
        setState(() {
          force = true;
        });
      }
    }
  }

  Widget _buildGrid(List<Folder> folders) {
    return CustomScrollView(
      slivers: <Widget>[
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverToBoxAdapter(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Text(
                AppLocalizations.of(context)?.library ?? "Library",
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.63,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final folder = folders[index];
                return SeriesCard(
                  folder: folder,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => collectionScreen(
                          folderId: folder.id,
                          name: folder.name,
                          image: folder.image,
                          bookIds: folder.bookIds,
                        ),
                      ),
                    );
                  },
                );
              },
              childCount: folders.length,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  Future<List<Entry>> _fetchPage(int pageKey) async {
    logger.i('pageKey: $pageKey');
    try {
      final result = await fetchEntries(pageKey, _pageSize);
      logger.i("result.\$1: ${result.$1}");
      return result.$2;
    } catch (error, stackTrace) {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      bool useSentry = prefs.getBool('useSentry') ?? false;
      if (useSentry) {
        await Sentry.captureException(error, stackTrace: stackTrace);
      }
      rethrow;
    }
  }

  Future<void> getSharedPrefs() async {
    prefs = await SharedPreferences.getInstance();
  }

  @override
  void initState() {
    super.initState();
    getSharedPrefs().then((value) => setUseSentry());
  }

  @override
  void dispose() {
    _connectionManager?.removeListener(_onConnectionChanged);
    _pagingController.dispose();
    super.dispose();
  }

  bool useSentryNull() {
    return prefs?.getBool("useSentry") == null;
  }

  Future<void> setUseSentry() async {
    if (useSentryNull()) {
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text(
              AppLocalizations.of(context)?.useSentry ?? "Use Sentry",
            ),
            content: Text(AppLocalizations.of(context)?.sentryExplanation ??
                "Enable Sentry logging to quickly diagnose and fix issues! This provides us with real-time error tracking without compromising your privacy. Please help support JellyBook's development!"),
            actions: [
              TextButton(
                onPressed: () {
                  prefs?.setBool("useSentry", true);
                  Navigator.of(context).pop();
                },
                child: Text(
                  AppLocalizations.of(context)?.yes ?? "Yes",
                ),
              ),
              TextButton(
                onPressed: () {
                  prefs?.setBool("useSentry", false);
                  Navigator.of(context).pop();
                },
                child: Text(
                  AppLocalizations.of(context)?.no ?? "No",
                ),
              ),
            ],
          );
        },
      );
    }
  }

  void _showErrorModal(BuildContext context, String error) {
    if (!mounted || _errorModalShowing) return;
    _errorModalShowing = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(
            AppLocalizations.of(context)?.error ?? "Error",
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(_friendlyError(error)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: const Text("Dismiss"),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _pagingController.refresh();
                setState(() {
                  force = true;
                });
              },
              child: const Text("Retry"),
            ),
          ],
        );
      },
    ).then((_) => _errorModalShowing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.refresh_rounded),
          tooltip: AppLocalizations.of(context)?.refresh ?? 'Refresh',
          onPressed: () {
            _pagingController.refresh();
            setState(
              () {
                force = true;
              },
            );
          },
        ),
        title: Container(
          width: double.infinity,
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor,
            borderRadius: BorderRadius.circular(17.5),
          ),
          child: Center(
              child: TextButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SearchScreen(),
                ),
              );
            },
            child: Row(
              children: [
                Icon(
                  Icons.search,
                  color: Theme.of(context).secondaryHeaderColor,
                ),
                const SizedBox(width: 10),
                Text(
                  (AppLocalizations.of(context)?.search ?? 'Search') + '…',
                  style: TextStyle(
                    color: Theme.of(context).secondaryHeaderColor,
                    fontSize: 17,
                  ),
                ),
              ],
            ),
          )),
        ),
        actions: <Widget>[
          // Connection status icon
          Consumer<ConnectionManager>(
            builder: (context, connectionManager, _) {
              final status = connectionManager.status;

              if (status == ConnectionStatus.offline) {
                return IconButton(
                  icon: const Icon(Icons.cloud_off),
                  tooltip: 'Offline - tap to retry',
                  onPressed: () {
                    connectionManager.retry();
                  },
                );
              } else if (status == ConnectionStatus.validating) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                );
              }

              // Online: no icon
              return SizedBox.shrink();
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Logout',
            onPressed: () {
              logout();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _pagingController.refresh();
          setState(() {
            force = true;
          });
        },
        child: FutureBuilder<(List<Entry>, List<Folder>)>(
          future: getServerCategories(force: force),
          builder: (context, AsyncSnapshot snapshot) {
            // while loading/refreshing, keep showing the last grid if we have one
            if (snapshot.connectionState != ConnectionState.done) {
              final cached = _lastFolders;
              return cached != null
                  ? _buildGrid(cached)
                  : const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasData && snapshot.data != null) {
              final List<Folder> folders = snapshot.data.$2 ?? <Folder>[];
              _lastFolders = folders;
              return _buildGrid(folders);
            }

            if (snapshot.hasError) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _showErrorModal(context, snapshot.error.toString());
              });
              // fall back to the last grid, or whatever is cached in Isar
              final cached = _lastFolders ??
                  Isar.getInstance()?.folders.where().findAllSync();
              return (cached != null && cached.isNotEmpty)
                  ? _buildGrid(cached)
                  : const Center(child: Icon(Icons.cloud_off, size: 48));
            }

            return const Center(child: Text("No data found"));
          },
        ),
      ),
    );
  }
}

class SeriesCard extends StatefulWidget {
  final Folder folder;
  final VoidCallback onTap;

  const SeriesCard({super.key, required this.folder, required this.onTap});

  @override
  State<SeriesCard> createState() => _SeriesCardState();
}

class _SeriesCardState extends State<SeriesCard> {
  static const double _imageRadius = 12;
  static const double _cardRadius = _imageRadius + 4 + 1.5;

  // Average progress across all books in the series
  double _calcProgress() {
    final isar = Isar.getInstance();
    if (isar == null || widget.folder.bookIds.isEmpty) return 0.0;
    final entries = isar.entrys
        .where()
        .filter()
        .anyOf(widget.folder.bookIds, (q, String id) => q.idEqualTo(id))
        .findAllSync();
    if (entries.isEmpty) return 0.0;
    final total = entries.fold<double>(0.0, (sum, e) => sum + e.progress);
    return (total / entries.length).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final folder = widget.folder; // added
    final progress = _calcProgress(); // added

    return GestureDetector(
      onTap: widget.onTap, // was: onTap
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_cardRadius),
          border: Border.all(color: scheme.outlineVariant, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title lives in the card header, not on the image
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
              child: Row(
                children: [
                  Icon(Icons.chrome_reader_mode_outlined,
                      size: 22, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Clean cover with just a book-count pill
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_imageRadius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RoundedImageWithShadow(
                      imageUrl: folder.image,
                      radius: _imageRadius,
                      shadowColor: Colors.transparent,
                    ),
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.75),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Text(
                          '${folder.bookIds.length} Books',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black
                              .withOpacity(0.75), // matches the pill
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                value: progress,
                                strokeWidth: 2.5,
                                backgroundColor: Colors.white24,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    scheme.primary),
                              ),
                            ),
                            Text(
                              '${(progress * 100).round()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
