import 'package:flutter/material.dart';
import 'package:jellybook/providers/downloadManager.dart';

/// Queue state only; never creates a new cover image provider.
class DownloadQueueSheet extends StatelessWidget {
  const DownloadQueueSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = DownloadManager.instance;
    return SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: manager,
        builder: (context, _) {
          // Keep FIFO order within each state; never alphabetize the queue.
          final jobs = [
            ...manager.jobs.where((j) => j.state == DownloadJobState.downloading),
            ...manager.jobs.where((j) => j.state == DownloadJobState.queued),
            ...manager.jobs.where((j) => j.state == DownloadJobState.failed),
          ];
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Downloads', style: Theme.of(context).textTheme.titleLarge),
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
                        final queued = job.state == DownloadJobState.queued;
                        final failed = job.state == DownloadJobState.failed;
                        return Row(
                          children: [
                            Icon(failed ? Icons.error_outline :
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
                                  Text(active ? '${job.progress.round()}% · Downloading' :
                                      queued ? 'Queued' : 'Failed',
                                      style: Theme.of(context).textTheme.bodySmall),
                                  if (active) ...[
                                    const SizedBox(height: 5),
                                    LinearProgressIndicator(value: job.progress / 100),
                                  ],
                                  if (failed) Text('${job.error}', maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.bodySmall),
                                ],
                              ),
                            ),
                            if (queued)
                              IconButton(
                                tooltip: 'Remove queued download',
                                icon: const Icon(Icons.close),
                                onPressed: () => manager.cancelQueued(job.id),
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
                                onPressed: () => manager.dismissFailure(job.id),
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
