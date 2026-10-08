import 'dart:io';
import 'package:flutter/material.dart';
import 'package:jellybook/widgets/WaveProgressBar.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/providers/downloadEntry.dart';

class DownloadScreen extends StatefulWidget {
  Entry entry;
  DownloadScreen({required this.entry});

  @override
  _DownloadScreenState createState() => _DownloadScreenState(entry: entry);
}

class _DownloadScreenState extends State<DownloadScreen> {
  Entry entry;
  _DownloadScreenState({required this.entry});

  double progress = 0.0;
  bool downloading = false;
  bool downloaded = false;

  @override
  void initState() {
    super.initState();
    _download();
  }

  Future<void> _download() async {
    setState(() => downloading = true);
    try {
      final result = await downloadEntry(
        entry,
        onProgress: (p) => setState(() => progress = p),
        forceDownload: false,
      );
      setState(() {
        entry = result;
        downloading = false;
        downloaded = true;
        progress = 100;
      });
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) Navigator.pop(context, entry);
      });
    } catch (e) {
      logger.e('Download error: $e');
      setState(() {
        downloading = false;
        downloaded = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)?.downloading ?? 'Downloading'),
        automaticallyImplyLeading: !downloading,
        actions: [
          if (!downloading)
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: _download,
            ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: WaveProgressBar(
              progress: progress / 100,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.blue, Colors.blueAccent, Colors.teal],
              ),
            ),
          ),
          Center(
            child: downloading
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${AppLocalizations.of(context)?.downloadingFile ?? "Downloading"}: ${progress.toStringAsFixed(0)}%',
                        style: const TextStyle(
                            fontSize: 30, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(
                          height: MediaQuery.of(context).size.height * 0.4),
                    ],
                  )
                : downloaded
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            AppLocalizations.of(context)?.fileDownloaded ??
                                'File Downloaded',
                            style: const TextStyle(fontSize: 20),
                          ),
                          const SizedBox(height: 20),
                          const Icon(Icons.check_circle,
                              size: 100, color: Colors.green),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            AppLocalizations.of(context)?.downloadFailed ??
                                'Download failed',
                            style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.red),
                          ),
                          const SizedBox(height: 20),
                          const Icon(Icons.error, size: 100, color: Colors.red),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}
