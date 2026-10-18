import 'package:dio/dio.dart';

class JellyfinApi {
  JellyfinApi(String server)
      : _dio = Dio(BaseOptions(
          baseUrl: server.replaceFirst(RegExp(r'/+$'), ''),
          headers: {'Accept': 'application/json'},
          listFormat: ListFormat.multi,
        ));

  final Dio _dio;

  Future<Response<Map<String, dynamic>>> authenticateUserByName({
    required String username,
    required String password,
    required Map<String, String> headers,
  }) =>
      _dio.post<Map<String, dynamic>>(
        '/Users/AuthenticateByName',
        data: {'Username': username, 'Pw': password},
        options: Options(
          headers: headers,
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
