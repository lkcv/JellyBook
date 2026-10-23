import 'package:isar/isar.dart';

part 'download_queue_record.g.dart';

@Collection(accessor: 'downloadQueueRecords')
class DownloadQueueRecord {
  Id isarId = Isar.autoIncrement;

  String entryId;
  int position;
  String state;

  DownloadQueueRecord({
    required this.entryId,
    required this.position,
    required this.state,
  });
}
