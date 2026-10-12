import 'dart:io';

import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/providers/deleteComic.dart';
import 'package:jellybook/providers/supportedFormats.dart';

/// Storage management, not a second reading/browsing interface.
class DownloadedVolumesScreen extends StatefulWidget {
  const DownloadedVolumesScreen({super.key});

  @override
  State<DownloadedVolumesScreen> createState() => _DownloadedVolumesScreenState();
}

class _DownloadedVolumesScreenState extends State<DownloadedVolumesScreen> {
  late Future<List<({Entry entry, String series, int? bytes})>> _volumes;
  String? _deletingId;

  @override
  void initState() {
    super.initState();
    _volumes = _load();
  }

  Future<int?> _directorySize(String path) async {
    if (path.isEmpty) return null;
    final dir = Directory(path);
    if (!await dir.exists()) return null;
    var bytes = 0;
    await for (final child in dir.list(recursive: true, followLinks: false)) {
      if (child is File) bytes += await child.length();
    }
    return bytes;
  }

  Future<List<({Entry entry, String series, int? bytes})>> _load() async {
    final isar = Isar.getInstance();
    if (isar == null) return [];
    final entries = (await isar.entrys.where().filter()
            .downloadedEqualTo(true).findAll())
        .where(isSupportedEntry).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final folders = await isar.folders.where().findAll();
    final seriesNames = <String, String>{
      for (final folder in folders) folder.id: folder.name,
    };
    return Future.wait([
      for (final entry in entries)
        (() async => (
          entry: entry,
          series: seriesNames[entry.parentId] ?? '',
          bytes: await _directorySize(entry.folderPath),
        ))(),
    ]);
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return 'Local files not found';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _delete(Entry entry) async {
    if (_deletingId != null) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Remove downloaded volume?'),
            content: Text('Remove the local copy of "${entry.title}"? '
                'Reading progress and cached pages will be kept.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ?? false;
    if (!confirmed || !mounted) return;
    setState(() => _deletingId = entry.id);
    try {
      await removeDownloadedVolume(entry.id);
      if (mounted) setState(() => _volumes = _load());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not remove download: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloaded volumes')),
      body: FutureBuilder<List<({Entry entry, String series, int? bytes})>>(
        future: _volumes,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Could not list downloads: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final volumes = snapshot.data!;
          if (volumes.isEmpty) {
            return const Center(child: Text('No downloaded volumes'));
          }
          return ListView.separated(
            itemCount: volumes.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
            itemBuilder: (context, index) {
              final volume = volumes[index];
              return ListTile(
                title: Text(volume.entry.title, maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  if (volume.series.isNotEmpty) volume.series,
                  _formatSize(volume.bytes),
                ].join(' • ')),
                trailing: _deletingId == volume.entry.id
                    ? const SizedBox(width: 24, height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(
                        tooltip: 'Remove download',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _deletingId == null
                            ? () => _delete(volume.entry)
                            : null,
                      ),
              );
            },
          );
        },
      ),
    );
  }
}
