// This files purpose is to attempt to login to the server
// this is not the screen, it is just the request and response

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart' as package_info;
import 'package:isar/isar.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/models/login.dart';
import 'package:tentacle/tentacle.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:jellybook/variables.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

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
    required AuthenticationResult? data,
  }) async {
    const storage = FlutterSecureStorage();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    logger.d("saving data to cache");
    prefs.setString("server", url);
    prefs.setString("accessToken", data?.accessToken ?? "");
    prefs.setString("UserId", data?.user?.id ?? "");
    prefs.setString("ServerId", data?.serverId ?? "");

    prefs.setString("client", client);
    prefs.setString("device", device);
    prefs.setString("deviceId", deviceId);
    prefs.setString("version", version);

    await storage.write(key: "server", value: url);
    await storage.write(key: "username", value: username);
    await storage.write(key: "password", value: password);
    await storage.write(key: "accessToken", value: data?.accessToken ?? "");
    await storage.write(key: "ServerId", value: data?.serverId ?? "");
    await storage.write(key: "UserId", value: data?.sessionInfo?.userId ?? "");
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

  // Login without a UI/BuildContext. Used by ConnectionManager to refresh an
  // expired token with the saved credentials.
  static Future<LoginResult> silentLogin(
    String url,
    String username,
    String password,
  ) async {
    try {
      String _url = url.endsWith("/") ? url.substring(0, url.length - 1) : url;
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

      final api = Tentacle(basePathOverride: _url).getAuthenticationApi();
      final response = await api.authenticateUserByName(
        authenticateUserByName: AuthenticateUserByName((b) => b
          ..username = username
          ..pw = password),
        headers: getHeaders(_url, client, device, deviceId, version),
      );

      if (response.statusCode == 200) {
        await _saveSession(
          url: _url,
          username: username,
          password: password,
          client: client,
          device: device,
          deviceId: deviceId,
          version: version,
          data: response.data,
        );
        return LoginResult.success;
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
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

  // make a static version of the above class
  static Future<String> loginStatic(
    String url,
    String username,
    BuildContext context, [
    String password = "",
  ]) async {
    logger.d("LoginStatic called");
    const storage = FlutterSecureStorage();
    // String _url = "$url/Users/authenticatebyname";
    String _url = url;
    final BuildContext _context = context;
    const _client = "JellyBook";
    String _device;
    String _deviceId;
    late String _version;

    logger.d("getDeviceInfo called");
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    _device = "Unknown Device";
    _deviceId = "Unknown Device id";
    if (Platform.isAndroid) {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      _device = androidInfo.model;
      _deviceId = "Android ${androidInfo.version.release}";
    } else if (Platform.isIOS) {
      IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
      _device = iosInfo.name;
      _device = iosInfo.identifierForVendor ?? "Unknown Device id";
    }

    package_info.PackageInfo packageInfo =
        await package_info.PackageInfo.fromPlatform();

    _version = packageInfo.version;

    logger.d("Attempting to login to $url");

    // check if the last character is a /
    if (_url.endsWith("/")) {
      _url = _url.substring(0, _url.length - 1);
    }
    // check if url is valid using regex (allow other languages and emojis)
    final RegExp urlTest = RegExp(r"^(http|https)://+.+");
    if (!urlTest.hasMatch(_url)) {
      logger.e("URL is not valid");
      // tell why it is not valid
      if (!_url.startsWith("http")) {
        return AppLocalizations.of(_context)?.noHttp ??
            "URL does not start with http:// or https://";
      }
      if (!_url.contains(".")) {
        return AppLocalizations.of(_context)?.noDot ??
            "URL does not contain a .";
      }
      if (!_url.contains("/")) {
        return AppLocalizations.of(_context)?.noSlash ??
            "URL does not contain a /";
      }
      return AppLocalizations.of(_context)?.invalidUrl ??
          "URL is not valid. Please check the URL and try again.";
    }

    final api = Tentacle(basePathOverride: _url);
    final apiInstance = api.getAuthenticationApi();
    Response<AuthenticationResult> response;

    try {
      var authenticateUserByNameRequest = AuthenticateUserByName((b) => b
        ..username = username
        ..pw = password);
      final headers = getHeaders(_url, _client, _device, _deviceId, _version);
      response = await apiInstance.authenticateUserByName(
        authenticateUserByName: authenticateUserByNameRequest,
        headers: headers,
      );
      logger.d("Status Code: ${response.statusCode}");
    } catch (e, s) {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      bool useSentry = prefs.getBool('useSentry') ?? false;
      if (useSentry) await Sentry.captureException(e, stackTrace: s);
      logger.e("Error:\n$e");
      return e.toString();
    }

    logger.d("Response: ${response.statusCode}");
    // logger.d("Response: ${response.data}");

    if (response.statusCode == 200) {
      await _saveSession(
        url: _url,
        username: username,
        password: password,
        client: _client,
        device: _device,
        deviceId: _deviceId,
        version: _version,
        data: response.data,
      );
      return "true";
    } else {
      if (response.statusCode == 401) {
        logger.e("401");
        return AppLocalizations.of(_context)?.invalidCredentials ??
            "Incorrect username or password";
      } else if (response.statusCode == 404) {
        logger.e("404");
        return AppLocalizations.of(_context)?.serverNotFound ??
            "Server not found\nPlease check the URL";
      } else if (response.statusCode == 407) {
        logger.e("407");
        return AppLocalizations.of(_context)?.proxyAuthRequired ??
            "Proxy authentication required\nPlease check the server logs";
      } else if (response.statusCode == 408) {
        logger.e("408");
        return AppLocalizations.of(_context)?.requestTimeout ??
            "Request timeout\nPlease check the server logs";
      } else if (response.statusCode == 418) {
        logger.e("418");
        return AppLocalizations.of(_context)?.dontBrewCoffee ??
            "Do not brew coffee with me. I am a teapot";
      } else if (response.statusCode == 500) {
        logger.e("500");
        return AppLocalizations.of(_context)?.serverError ??
            "Server error\nPlease check the server logs";
      } else if (response.statusCode == 502) {
        logger.e("502");
        return AppLocalizations.of(_context)?.badGateway ??
            "Bad gateway\nPlease check the server logs";
      } else {
        logger.e("Unknown error");
        return (AppLocalizations.of(_context)?.error ?? "Error:") +
            " ${response.statusCode}";
      }
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
