// This files purpose is to attempt to login to the server
// this is not the screen, it is just the request and response

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart' as package_info;
import 'package:isar/isar.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/models/login.dart';
import 'package:jellybook/providers/jellyfin_api.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:jellybook/variables.dart';

enum LoginResult { success, rejected, unreachable }

class LoginProvider {
  final String url;
  final String username;
  final String password;

  LoginProvider({
    required this.url,
    required this.username,
    required this.password,
  });

  // Saves everything a successful login needs (prefs, secure storage, isar)
  static Future<void> _saveSession({
    required String url,
    required String username,
    required String password,
    required String client,
    required String device,
    required String deviceId,
    required String version,
    required Map<String, dynamic>? data,
  }) async {
    const storage = FlutterSecureStorage();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final user = data?['User'] as Map<String, dynamic>?;
    final session = data?['SessionInfo'] as Map<String, dynamic>?;
    logger.d("saving data to cache");
    prefs.setString("server", url);
    prefs.setString("accessToken", data?['AccessToken'] as String? ?? "");
    prefs.setString("UserId", user?['Id'] as String? ?? "");
    prefs.setString("ServerId", data?['ServerId'] as String? ?? "");

    prefs.setString("client", client);
    prefs.setString("device", device);
    prefs.setString("deviceId", deviceId);
    prefs.setString("version", version);

    await storage.write(key: "server", value: url);
    await storage.write(key: "username", value: username);
    await storage.write(key: "password", value: password);
    await storage.write(key: "accessToken", value: data?['AccessToken'] as String? ?? "");
    await storage.write(key: "ServerId", value: data?['ServerId'] as String? ?? "");
    await storage.write(key: "UserId", value: session?['UserId'] as String? ?? "");
    await storage.write(key: "client", value: client);
    await storage.write(key: "device", value: device);
    await storage.write(key: "deviceId", value: deviceId);
    await storage.write(key: "version", value: version);

    final isar = Isar.getInstance();
    final entry = await isar!.logins.where().serverUrlEqualTo(url).findFirst();
    if (entry == null) {
      // a different server/user was saved before, remove it
      List<Login> others = await isar.logins.where().findAll();
      List<int> otherIds = others
          .where((l) => l.serverUrl != url)
          .map((l) => l.isarId)
          .toList();
      await isar.writeTxn(() async {
        isar.logins.deleteAll(otherIds);
      });
      await isar.writeTxn(() async {
        await isar.logins
            .put(Login(serverUrl: url, username: username, password: password));
      });
    }
  }

  // Authentication errors may be plain text, even when the request asks for
  // JSON. Only decode a successful response, and verify the fields we need.
  static Map<String, dynamic>? _authData(String? body) {
    if (body == null) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final user = decoded['User'];
      final token = decoded['AccessToken'];
      if (token is! String || token.isEmpty ||
          user is! Map<String, dynamic> ||
          user['Id'] is! String ||
          (user['Id'] as String).isEmpty) {
        return null;
      }
      return decoded;
    } on FormatException {
      return null;
    }
  }

  static String _httpLoginError(int? status, AppLocalizations? l) {
    switch (status) {
      case 400:
      case 401:
      case 403:
        return l?.invalidCredentials ?? 'Incorrect username or password.';
      case 404:
        return l?.serverNotFound ??
            'Could not find Jellyfin at this address. Check the server URL.';
      case 407:
        return l?.proxyAuthRequired ?? 'The server requires proxy authentication.';
      case 408:
      case 504:
        return l?.requestTimeout ?? 'The connection timed out. Please try again.';
      case 429:
        return 'Too many attempts. Please wait a moment and try again.';
      case 500:
        return l?.serverError ?? 'The server encountered an error. Please try again later.';
      case 502:
      case 503:
        return l?.badGateway ?? 'The server is temporarily unavailable. Please try again later.';
      default:
        return 'Could not sign in. Please check the server and try again.';
    }
  }

  static String _dioLoginError(DioException e, AppLocalizations? l) {
    if (e.response?.statusCode != null) {
      return _httpLoginError(e.response!.statusCode, l);
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return 'The connection timed out. Please try again.';
      case DioExceptionType.connectionError:
        return 'Could not connect to the server. Check its address and your connection.';
      case DioExceptionType.badCertificate:
        return 'Could not verify the server security certificate.';
      case DioExceptionType.cancel:
        return 'The login attempt was cancelled.';
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        return 'Could not sign in. Please check the server and try again.';
    }
  }

  // Login without a UI/BuildContext. Used by ConnectionManager to refresh an
  // expired token with the saved credentials.
  static Future<LoginResult> silentLogin(
    String url,
    String username,
    String password,
  ) async {
    try {
      String requestUrl = url.endsWith("/") ? url.substring(0, url.length - 1) : url;
      const client = "JellyBook";
      String device = "Unknown Device";
      String deviceId = "Unknown Device id";

      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        device = androidInfo.model;
        deviceId = "Android ${androidInfo.version.release}";
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        device = iosInfo.name;
        deviceId = iosInfo.identifierForVendor ?? "Unknown Device id";
      }
      final version = (await package_info.PackageInfo.fromPlatform()).version;

      final response = await JellyfinApi(requestUrl).authenticateUserByName(
        username: username,
        password: password,
        headers: getHeaders(requestUrl, client, device, deviceId, version),
      );

      if (response.statusCode == 200) {
        final data = _authData(response.data);
        if (data == null) return LoginResult.unreachable;
        await _saveSession(
          url: requestUrl,
          username: username,
          password: password,
          client: client,
          device: device,
          deviceId: deviceId,
          version: version,
          data: data,
        );
        return LoginResult.success;
      }
      if (response.statusCode == 400 ||
          response.statusCode == 401 || response.statusCode == 403) {
        return LoginResult.rejected;
      }
      return LoginResult.unreachable;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      logger.d("silentLogin failed: $code $e");
      if (code == 401 || code == 403) return LoginResult.rejected;
      return LoginResult.unreachable;
    } catch (e) {
      logger.d("silentLogin error: $e");
      return LoginResult.unreachable;
    }
  }

  // a curl request to the server would look like this:
  /*
     curl 'http://[REDACTED]/Users/authenticatebyname' -X POST -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:107.0) Gecko/20100101 Firefox/107.0' -H 'Accept: application/json' -H 'Accept-Language: en-US,en;q=0.5' -H 'Accept-Encoding: gzip, deflate' -H 'X-Emby-Authorization: MediaBrowser Client="Jellyfin Web", Device="Firefox", DeviceId="[REDACTED]", Version="10.8.5"' -H 'Content-Type: application/json' -H 'Origin: [REDACTED]' -H 'Connection: keep-alive' --data-raw '{"Username":"example","Pw":""}' > output
     */

  // Login from the UI. Return only safe, human-readable error messages.
  static Future<String> loginStatic(
    String url,
    String username,
    BuildContext context, [
    String password = "",
  ]) async {
    final l = AppLocalizations.of(context);
    final requestUrl = url.trim().replaceFirst(RegExp(r'/+$'), '');
    final address = Uri.tryParse(requestUrl);
    if (address == null ||
        (address.scheme != 'http' && address.scheme != 'https') ||
        !address.hasAuthority ||
        address.host.isEmpty) {
      return l?.invalidUrl ??
          'Enter a valid server address starting with http:// or https://.';
    }
    if (username.trim().isEmpty) return 'Enter your username.';

    const client = "JellyBook";
    try {
      String device = "Unknown Device";
      String deviceId = "Unknown Device id";
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        device = androidInfo.model;
        deviceId = "Android ${androidInfo.version.release}";
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        device = iosInfo.name;
        deviceId = iosInfo.identifierForVendor ?? "Unknown Device id";
      }

      final version = (await package_info.PackageInfo.fromPlatform()).version;
      final response = await JellyfinApi(requestUrl).authenticateUserByName(
        username: username.trim(),
        password: password,
        headers: getHeaders(requestUrl, client, device, deviceId, version),
      );
      if (response.statusCode != 200) {
        logger.w('Login rejected (HTTP ${response.statusCode})');
        return _httpLoginError(response.statusCode, l);
      }

      final data = _authData(response.data);
      if (data == null) {
        logger.w('Login returned an invalid success payload');
        return 'Unexpected response from the server. Check the server address.';
      }
      await _saveSession(
        url: requestUrl,
        username: username.trim(),
        password: password,
        client: client,
        device: device,
        deviceId: deviceId,
        version: version,
        data: data,
      );
      return "true";
    } on DioException catch (e) {
      logger.w('Login network failure (${e.type}, HTTP ${e.response?.statusCode})');
      return _dioLoginError(e, l);
    } catch (e) {
      logger.e('Unexpected login failure (${e.runtimeType})');
      return 'Could not sign in. Please try again.';
    }
  }
}

// getHeaders returns the headers depending on if the url is http or https

Map<String, String> getHeaders(
  String url,
  String client,
  String device,
  String deviceId,
  String version,
) {
  if (url.contains("https://")) {
    return {
      "Accept": "application/json",
      "Accept-Language": "en-US,en;q=0.5",
      "Accept-Encoding": "gzip, deflate",
      "Content-Type": "application/json",
      "Sec-Fetch-Dest": "empty",
      "Sec-Fetch-Mode": "cors",
      "Sec-Fetch-Site": "same-origin",
      "Origin": url,
      "Connection": "keep-alive",
      "TE": "Trailers",
      "Authorization":
          "MediaBrowser Client=\"$client\", Device=\"$device\", DeviceId=\"$deviceId\", Version=\"$version\"",
    };
  }

  return {
    "Accept": "application/json",
    "Accept-Language": "en-US,en;q=0.5",
    "Accept-Encoding": "gzip, deflate",
    "Authorization":
        "MediaBrowser Client=\"$client\", Device=\"$device\", DeviceId=\"$deviceId\", Version=\"$version\"",
    "Content-Type": "application/json",
    "Origin": url,
    "Connection": "keep-alive",
  };
}
