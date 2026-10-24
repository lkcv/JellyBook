import 'package:isar/isar.dart';

part 'pending_progress_record.g.dart';

@Collection(accessor: 'pendingProgressRecords')
class PendingProgressRecord {
  Id isarId = Isar.autoIncrement;

  String server;
  String userId;
  String itemId;
  int pageIndex;
  int position;

  PendingProgressRecord({
    required this.server,
    required this.userId,
    required this.itemId,
    required this.pageIndex,
    required this.position,
  });
}
