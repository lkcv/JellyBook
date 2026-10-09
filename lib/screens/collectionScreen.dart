// The purpose of this file is to create a list of entries from a selected folder
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:isar/isar.dart';
import 'package:isar_flutter_libs/isar_flutter_libs.dart';
import 'package:jellybook/models/entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_star/flutter_star.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/screens/infoScreen.dart';
import 'package:jellybook/providers/fixRichText.dart';
import 'package:fancy_shimmer_image/fancy_shimmer_image.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/widgets/roundedImageWithShadow.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:jellybook/screens/readingScreen.dart';
import 'package:provider/provider.dart';
import 'package:jellybook/providers/connectionManager.dart';

class collectionScreen extends StatefulWidget {
  final String folderId;
  final String name;
  final String image;
  final List<String> bookIds;

  collectionScreen({
    required this.folderId,
    required this.name,
    required this.image,
    required this.bookIds,
  });

  @override
  _collectionScreenState createState() => _collectionScreenState(
      folderId: folderId, name: name, image: image, bookIds: bookIds);
}

class _collectionScreenState extends State<collectionScreen> {
  final String folderId;
  final String name;
  final String image;
  final List<String> bookIds;

  _collectionScreenState({
    required this.folderId,
    required this.name,
    required this.image,
    required this.bookIds,
  });

  final isar = Isar.getInstance();

  Future<List<Entry>> getEntries() async {
    List<Entry> entryList = await isar!.entrys
        .where()
        .filter()
        .anyOf(bookIds, (q, String id) => q.idEqualTo(id))
        .findAll();
    entryList.forEach((element) {
      if (element.type == EntryType.folder) {
        logger.f(element.title);
      }
    });
    return entryList;
  }

  Future<List<Entry>> get entries async {
    return await getEntries();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: AutoSizeText(
          name,
          maxLines: 2,
          minFontSize: 10,
          maxFontSize: 20,
          stepGranularity: 0.5,
          overflow: TextOverflow.ellipsis,
        ),
        elevation: 0,
      ),
      body: FutureBuilder(
        future: entries,
        builder: (BuildContext context, AsyncSnapshot snapshot) {
          if (snapshot.hasData &&
              snapshot.data.length > 0 &&
              snapshot.connectionState == ConnectionState.done) {
            return Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 0.69,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: snapshot.data.length,
                itemBuilder: (BuildContext context, int index) {
                  Entry entry = snapshot.data[index];
                  return KuroStyleBookCard(
                    entry: entry,
                    onEntryTapped: () async {
                      if (entry.type == EntryType.folder) {
                        var folder = isar!.folders
                            .where()
                            .filter()
                            .idEqualTo(entry.id)
                            .findFirstSync();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => collectionScreen(
                              folderId: folder!.id,
                              name: folder.name,
                              image: folder.image,
                              bookIds: folder.bookIds,
                            ),
                          ),
                        );
                        return;
                      }

                      // Check connection status
                      if (!mounted) return;
                      final connectionStatus = Provider.of<ConnectionManager>(
                              context,
                              listen: false)
                          .status;
                      if (connectionStatus == ConnectionStatus.offline) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Server is offline'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                        return;
                      }

                      // For downloaded items, open the reader directly
                      if (entry.downloaded) {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ReadingScreen(
                              title: entry.title,
                              comicId: entry.id,
                            ),
                          ),
                        );
                        setState(() {});
                        return;
                      }

                      // For CBZ/CBR, stream it
                      bool isCbz = entry.path.toLowerCase().endsWith('.cbz') ||
                          entry.path.toLowerCase().endsWith('.cbr');
                      if (isCbz) {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ReadingScreen(
                              title: entry.title,
                              comicId: entry.id,
                            ),
                          ),
                        );
                        setState(() {});
                        return;
                      }

                      // For other formats, show the info screen
                      var result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => InfoScreen(entry: entry),
                        ),
                      );
                      if (result != null) {
                        entry.isFavorited = result.isFavorited;
                        entry.downloaded = result.downloaded;
                        await isar?.writeTxn(() async {
                          await isar?.entrys.put(entry);
                        });
                        setState(() {});
                      }
                    },
                    onEntryLongPressed: () async {
                      var result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => InfoScreen(entry: entry),
                        ),
                      );
                      if (result != null) {
                        setState(() {});
                      }
                    },
                  );
                },
              ),
            );
          } else if (snapshot.hasData &&
              snapshot.data.length == 0 &&
              snapshot.connectionState == ConnectionState.done) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    AppLocalizations.of(context)?.noResultsFound ??
                        'No results found in this folder',
                    style: const TextStyle(
                      fontSize: 25,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Icon(Icons.sentiment_dissatisfied, size: 100),
                ],
              ),
            );
          } else if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    AppLocalizations.of(context)?.unknownError ??
                        "An unknown error has occured.",
                    style: const TextStyle(
                      fontSize: 25,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Icon(Icons.sentiment_dissatisfied, size: 100),
                ],
              ),
            );
          } else {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }
        },
      ),
    );
  }
}

// Kuro Reader-inspired book card widget
class KuroStyleBookCard extends StatefulWidget {
  final Entry entry;
  final VoidCallback onEntryTapped;
  final VoidCallback? onEntryLongPressed; // new

  const KuroStyleBookCard({
    required this.entry,
    required this.onEntryTapped,
    this.onEntryLongPressed, // new
  });

  @override
  KuroStyleBookCardState createState() => KuroStyleBookCardState();
}

class KuroStyleBookCardState extends State<KuroStyleBookCard> {
  // One radius for both the card and the cover image
  static const double _imageRadius = 10; // was 14
  static const double _cardRadius = _imageRadius + 4 + 1.5;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // entry.progress is stored as a percentage (0-100), not a 0-1 fraction
    final double progressPercent = widget.entry.progress;
    final bool isUnread = widget.entry.pageNum == 0 && progressPercent <= 0;
    final bool isFinished = progressPercent >= 100;
    final double progress = (progressPercent / 100).clamp(0.0, 1.0);

    // Check if offline
    final connectionStatus =
        Provider.of<ConnectionManager>(context).status;
    final isOffline = connectionStatus == ConnectionStatus.offline;
    final isUndownloaded = !widget.entry.downloaded;

    return Opacity(
      opacity: isOffline && isUndownloaded ? 0.5 : 1.0,
      child: GestureDetector(
        onTap: widget.onEntryTapped,
        onLongPress: widget.onEntryLongPressed,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_cardRadius),
            border: Border.all(color: scheme.outlineVariant, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_imageRadius),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RoundedImageWithShadow(
                        imageUrl: widget.entry.imagePath,
                        radius: _imageRadius,
                        shadowColor: Colors.transparent,
                      ),
                      Positioned(
                        top: 2,
                        left: 2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isUnread
                                ? const Color(0xFFE91E63)
                                : isFinished
                                    ? const Color(0xFF4CAF50)
                                    : const Color(0xFFFF9800),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            isUnread
                                ? 'UNREAD'
                                : isFinished
                                    ? 'FINISHED'
                                    : 'READING',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                      if (widget.entry.isFavorited == true)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            padding: const EdgeInsets.all(4),
                            child: const Icon(
                              Icons.favorite,
                              color: Colors.red,
                              size: 16,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: SizedBox(
                    height: 3,
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: scheme.outlineVariant,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(scheme.primary),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
