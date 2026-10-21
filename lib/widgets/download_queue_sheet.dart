import 'package:flutter/material.dart';
import 'package:kurage/providers/download_queue.dart';

/// Queue state only; never creates a new cover image provider.
class DownloadQueueSheet extends StatelessWidget {
  const DownloadQueueSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = DownloadQueue.instance;
    return SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: manager,
        builder: (context, _) {
          // Keep FIFO order within each state; never alphabetize the queue.
          final jobs = [
            ...manager.jobs.where((j) => j.state == DownloadJobState.downloading ||
                j.state == DownloadJobState.canceling),
            ...manager.jobs.where((j) =>
                j.state == DownloadJobState.waitingForNetwork ||
                j.state == DownloadJobState.waitingForServer),
            ...manager.jobs.where((j) => j.state == DownloadJobState.queued),
            ...manager.jobs.where((j) => j.state == DownloadJobState.failed),
          ];
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Download Queue', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('${manager.pendingCount} pending · ${manager.failedCount} failed',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 16),
                if (jobs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('No active downloads')),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: jobs.length,
                      separatorBuilder: (_, __) => const Divider(height: 18),
                      itemBuilder: (context, index) {
                        final job = jobs[index];
                        final active = job.state == DownloadJobState.downloading;
                        final canceling = job.state == DownloadJobState.canceling;
                        final queued = job.state == DownloadJobState.queued;
                        final failed = job.state == DownloadJobState.failed;
                        final waitingNetwork = job.state == DownloadJobState.waitingForNetwork;
                        final waitingServer = job.state == DownloadJobState.waitingForServer;
                        final waiting = waitingNetwork || waitingServer;
                        return Row(
                          children: [
                            Icon(failed ? Icons.error_outline :
                                waitingNetwork ? Icons.wifi_off :
                                waitingServer ? Icons.sync :
                                active ? Icons.downloading_rounded : Icons.schedule,
                                color: failed ? Theme.of(context).colorScheme.error : null),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(job.title, maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 4),
                                  Text(canceling ? 'Canceling…' :
                                      active ? '${job.progress.round()}% · Downloading' :
                                      waitingNetwork ? '${job.progress.round()}% · Waiting for network' :
                                      waitingServer ? '${job.progress.round()}% · Reconnecting to Jellyfin' :
                                      queued ? (job.progress > 0
                                          ? '${job.progress.round()}% · Queued' : 'Queued') : 'Failed',
                                      style: Theme.of(context).textTheme.bodySmall),
                                  if (waiting)
                                    Text('Will resume automatically',
                                        style: Theme.of(context).textTheme.bodySmall),
                                  if (active || canceling || waiting || (queued && job.progress > 0)) ...[
                                    const SizedBox(height: 5),
                                    LinearProgressIndicator(value: job.progress / 100),
                                  ],
                                  if (failed) Text('${job.error}', maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.bodySmall),
                                ],
                              ),
                            ),
                            if (active || queued || waiting || canceling)
                              IconButton(
                                tooltip: canceling ? 'Canceling download' : 'Cancel download',
                                icon: const Icon(Icons.close),
                                onPressed: canceling ? null : () => manager.cancel(job.id),
                              ),
                            if (failed) ...[
                              IconButton(
                                tooltip: 'Retry download',
                                icon: const Icon(Icons.refresh),
                                onPressed: () => manager.retry(job.id),
                              ),
                              IconButton(
                                tooltip: 'Dismiss failure',
                                icon: const Icon(Icons.close),
                                onPressed: () => manager.cancel(job.id),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
