import 'package:dio/dio.dart';

class JellyfinApi {
  JellyfinApi(String server)
      : _dio = Dio(BaseOptions(
          baseUrl: server.replaceFirst(RegExp(r'/+$'), ''),
          headers: {'Accept': 'application/json'},
          listFormat: ListFormat.multi,
        ));

  final Dio _dio;

  Future<Response<Object?>> getPublicSystemInfo() =>
      _dio.get<Object?>(
        '/System/Info/Public',
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null,
        ),
      );

  Future<Response<Object?>> getCurrentUser({
    required Map<String, String> headers,
  }) =>
      _dio.get<Object?>(
        '/Users/Me',
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null,
        ),
      );

  Future<Response<String>> authenticateUserByName({
    required String username,
    required String password,
    required Map<String, String> headers,
  }) =>
      _dio.post<String>(
        '/Users/AuthenticateByName',
        data: {'Username': username, 'Pw': password},
        options: Options(
          headers: headers,
          // Non-200 responses can have plain-text bodies, not JSON maps.
          // Preserve the status and decode JSON only after successful login.
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null,
        ),
      );

  Future<Response<Map<String, dynamic>>> getUserViews({
    required String userId,
    required bool includeHidden,
    required Map<String, String> headers,
  }) =>
      _dio.get<Map<String, dynamic>>(
        '/UserViews',
        queryParameters: {'userId': userId, 'includeHidden': includeHidden},
        options: Options(headers: headers),
      );

  Future<Response<Map<String, dynamic>>> getItems({
    required String userId,
    required String parentId,
    required Map<String, String> headers,
  }) =>
      _dio.get<Map<String, dynamic>>(
        '/Items',
        queryParameters: {
          'userId': userId,
          'startIndex': 0,
          'fields': [
            'SortName',
            'Path',
            'ChildCount',
            'MediaSourceCount',
            'Tags',
            'Overview',
            'ParentId',
          ],
          'imageTypeLimit': 1,
          'parentId': parentId,
          'recursive': true,
          'sortBy': ['IsFolder', 'SortName'],
          'sortOrder': ['Ascending'],
        },
        options: Options(headers: headers),
      );

  // Scan status requires admin permissions on some Jellyfin servers.
  // Unknown is not the same as idle; callers must also use a grace period.
  Future<bool?> isLibraryScanRunning({
    required Map<String, String> headers,
  }) async {
    try {
      final response = await _dio.get<List<dynamic>>(
        '/ScheduledTasks',
        options: Options(headers: headers),
      );
      for (final raw in response.data ?? const <dynamic>[]) {
        if (raw is! Map) continue;
        if (raw['Key']?.toString().toLowerCase() == 'refreshlibrary') {
          return raw['State']?.toString().toLowerCase() == 'running';
        }
      }
    } on DioException {
      // Non-admin accounts commonly cannot inspect scheduled tasks.
    }
    return null;
  }

  Future<Response<List<int>>> getItemDownloadRange({
    required String itemId,
    required int start,
    required int end,
    required Map<String, String> headers,
    CancelToken? cancelToken,
  }) =>
      _dio.get<List<int>>(
        '/Items/${Uri.encodeComponent(itemId)}/Download',
        cancelToken: cancelToken,
        options: Options(
          headers: {
            ...headers,
            'Accept': '*/*',
            'Range': 'bytes=$start-$end',
          },
          responseType: ResponseType.bytes,
          validateStatus: (status) => status != null,
        ),
      );

  Future<Response<void>> reportPlaybackProgress({
    required String itemId,
    required int positionTicks,
    required Map<String, String> headers,
  }) =>
      _dio.post<void>(
        '/Sessions/Playing/Progress',
        data: {'ItemId': itemId, 'PositionTicks': positionTicks},
        options: Options(headers: headers),
      );

  Future<Response<List<int>>> getUserImage({
    required String userId,
    required Map<String, String> headers,
  }) =>
      _dio.get<List<int>>(
        '/UserImage',
        queryParameters: {'userId': userId},
        options: Options(headers: headers, responseType: ResponseType.bytes),
      );
}
