// lib/providers/connectionManager.dart

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:isar/isar.dart';
import 'package:jellybook/models/login.dart';
import 'package:jellybook/providers/login.dart';
import 'package:jellybook/variables.dart';

enum ConnectionStatus { validating, online, offline, authFailed }

class ConnectionManager extends ChangeNotifier with WidgetsBindingObserver {
  static const _timeout = Duration(seconds: 5);
  static const _retryInterval = Duration(seconds: 30);

  ConnectionStatus _status = ConnectionStatus.validating;
  ConnectionStatus get status => _status;

  bool _checking = false;
  bool _disposed = false;
  bool _paused = false;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _retryTimer;

  void _setStatus(ConnectionStatus s) {
    if (_disposed) return;
    if (_status != s) {
      logger.d('ConnectionManager: status changed from $_status to $s');
      _status = s;
      notifyListeners();
    }
  }

  /// Start listening to connectivity + app lifecycle, then validate
  Future<void> startMonitoring() async {
    if (_disposed) return;
    logger.d('ConnectionManager: startMonitoring called');

    WidgetsBinding.instance.addObserver(this);
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen(_onConnectivityChanged);

    await validateStartup();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.paused) {
      logger.d('ConnectionManager: app paused, stopping retry timer');
      _paused = true;
      _stopRetryTimer();
    } else if (state == AppLifecycleState.resumed && _paused) {
      logger.d('ConnectionManager: app resumed, revalidating');
      _paused = false;
      validateStartup(); // restarts the timer itself if still offline
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> result) {
    logger.d('ConnectionManager: connectivity changed to $result');
    if (_paused) return; // will revalidate on resume

    if (result.contains(ConnectivityResult.none)) {
      _setStatus(ConnectionStatus.offline);
      _startRetryTimer();
    } else {
      _stopRetryTimer();
      validateStartup();
    }
  }

  void _startRetryTimer() {
    if (_paused || _disposed || _retryTimer != null) return;

    logger.d('ConnectionManager: starting 30s retry timer');
    _retryTimer = Timer.periodic(_retryInterval, (_) async {
      if (_disposed || _paused) return;
      logger.d('ConnectionManager: timer tick, checking if server is reachable');

      if (await _isReachable()) {
        logger.d('ConnectionManager: server reachable, running full validation');
        _stopRetryTimer();
        await validateStartup();
      } else {
        logger.d('ConnectionManager: server still unreachable');
      }
    });
  }

  void _stopRetryTimer() {
    if (_retryTimer != null) {
      logger.d('ConnectionManager: stopping retry timer');
      _retryTimer!.cancel();
      _retryTimer = null;
    }
  }

  @override
  void dispose() {
    logger.d('ConnectionManager: disposing');
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopRetryTimer();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  /// Validate saved credentials (startup, resume, reconnect, manual retry)
  Future<void> validateStartup() async {
    if (_checking) {
      logger.d('ConnectionManager: already checking, skipping');
      return;
    }
    _checking = true;
    _setStatus(ConnectionStatus.validating);

    try {
      final prefs = await SharedPreferences.getInstance();
      final server =
          (prefs.getString('server') ?? '').replaceAll(RegExp(r'/+$'), '');
      final token = prefs.getString('accessToken') ?? '';

      if (server.isEmpty || token.isEmpty) {
        logger.d('ConnectionManager: missing saved server/token');
        _setStatus(ConnectionStatus.authFailed);
        return;
      }

      if (!await _isReachable()) {
        logger.d('ConnectionManager: server unreachable');
        _setStatus(ConnectionStatus.offline);
        _startRetryTimer();
        return;
      }

      var result = await _checkAuth(server, token);
      if (result == ConnectionStatus.authFailed) {
        logger.d('ConnectionManager: token rejected, attempting silent re-login');
        result = await _trySilentRelogin(server);
      }

      _setStatus(result);
      if (result == ConnectionStatus.offline) _startRetryTimer();
    } catch (e) {
      logger.d('ConnectionManager: validateStartup error: $e');
      _setStatus(ConnectionStatus.offline);
      _startRetryTimer();
    } finally {
      _checking = false;
    }
  }

  Future<bool> _isReachable() async {
    try {
      final server = (await SharedPreferences.getInstance())
              .getString('server')
              ?.replaceAll(RegExp(r'/+$'), '') ??
          '';
      if (server.isEmpty) return false;

      final response = await http
          .get(Uri.parse('$server/System/Info/Public'))
          .timeout(_timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<ConnectionStatus> _checkAuth(String server, String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final client = prefs.getString('client') ?? 'JellyBook';
      final device = prefs.getString('device') ?? 'Unknown Device';
      final deviceId = prefs.getString('deviceId') ?? 'Unknown Device id';
      final version = prefs.getString('version') ?? '';

      final response = await http.get(
        Uri.parse('$server/Users/Me'),
        headers: {
          'Authorization':
              'MediaBrowser Client="$client", Device="$device", DeviceId="$deviceId", Version="$version", Token="$token"',
        },
      ).timeout(_timeout);

      logger.d('ConnectionManager: /Users/Me -> ${response.statusCode}');
      if (response.statusCode == 401) return ConnectionStatus.authFailed;
      if (response.statusCode == 200) return ConnectionStatus.online;
      return ConnectionStatus.offline;
    } catch (e) {
      logger.d('ConnectionManager: auth check failed: $e');
      return ConnectionStatus.offline;
    }
  }

  // Re-login with the saved Isar credentials. LoginProvider.silentLogin saves
  // the new token, so the rest of the app picks it up.
  Future<ConnectionStatus> _trySilentRelogin(String server) async {
    try {
      final isar = Isar.getInstance();
      final login =
          await isar?.logins.where().serverUrlEqualTo(server).findFirst();

      if (login == null) {
        logger.d('ConnectionManager: no saved login for this server');
        return ConnectionStatus.authFailed;
      }

      logger.d('ConnectionManager: silent re-login for ${login.username}');
      final result = await LoginProvider.silentLogin(
        server,
        login.username,
        login.password,
      );

      switch (result) {
        case LoginResult.success:
          logger.d('ConnectionManager: re-login succeeded, token refreshed');
          return ConnectionStatus.online;
        case LoginResult.rejected:
          logger.d('ConnectionManager: re-login rejected (bad credentials)');
          return ConnectionStatus.authFailed;
        case LoginResult.unreachable:
          return ConnectionStatus.offline;
      }
    } catch (e) {
      logger.d('ConnectionManager: silent re-login error: $e');
      return ConnectionStatus.offline;
    }
  }

  /// Manual retry (triggered by user action)
  Future<void> retry() async {
    logger.d('ConnectionManager: manual retry triggered');
    _stopRetryTimer();
    await validateStartup();
  }
}
