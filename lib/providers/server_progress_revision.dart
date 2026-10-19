import 'package:flutter/foundation.dart';

// Signals that a completed Jellyfin refresh has imported progress into Isar.
// Collection screens use this to update their badges without rebuilding covers.
final ValueNotifier<int> serverProgressRevision = ValueNotifier<int>(0);
