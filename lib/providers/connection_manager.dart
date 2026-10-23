import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:kurage/providers/jellyfin_api.dart';
import 'package:kurage/providers/session_store.dart';
import 'package:kurage/providers/login.dart';
import 'package:kurage/providers/update_pagenum.dart';
import 'package:kurage/variables.dart';

enum ConnectionStatus { validating, online, offline, authFailed }

class ConnectionManager extends ChangeNotifier with WidgetsBindingObserver {
  static const _timeout = Duration(seconds: 5);
  static const _pollInterval = Duration(seconds: 30);
  static const _offlinePollInterval = Duration(seconds: 5);

  ConnectionStatus _status = ConnectionStatus.validating;
  ConnectionStatus get status => _status;

  bool _checking = false;
  bool _recheckRequested = false;
  bool _disposed = false;
  bool _paused = false;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _pollTimer;

  void _setStatus(ConnectionStatus s) {
    if (_disposed) return;
    if (_status != s) {
      logger.d('ConnectionManager: status changed from $_status to $s');
      _status = s;
      if (s == ConnectionStatus.online) {
        // Retry persisted offline positions after startup and reconnection.
        unawaited(retryPendingProgress().catchError((Object error) {
          logger.w('Could not retry saved reading progress: $error');
        }));
      }
      notifyListeners();
      if (_pollTimer != null) {
        _stopPolling();
        _startPolling();
      }
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

    _startPolling();
    await validateStartup();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.paused) {
      logger.d('ConnectionManager: app paused, stopping connection polling');
      _paused = true;
      _stopPolling();
    } else if (state == AppLifecycleState.resumed) {
      logger.d('ConnectionManager: app resumed, revalidating');
      _paused = false;
      _startPolling();
      unawaited(validateStartup());
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> result) {
    logger.d('ConnectionManager: connectivity changed to $result');
    if (_paused) return; // will revalidate on resume

    unawaited(validateStartup());
  }

  void _startPolling() {
    if (_paused || _disposed || _pollTimer != null) return;
    final interval = _status == ConnectionStatus.offline
        ? _offlinePollInterval
        : _pollInterval;
    _pollTimer = Timer(interval, () {
      _pollTimer = null;
      if (_disposed || _paused) return;
      unawaited(validateStartup().whenComplete(_startPolling));
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void dispose() {
    logger.d('ConnectionManager: disposing');
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  /// Validate saved credentials (startup, resume, reconnect, manual retry)
  Future<void> validateStartup() async {
    if (_checking) {
      _recheckRequested = true;
      return;
    }
    _recheckRequested = false;
    _checking = true;

    try {
      final session = SessionStore.current;
      final server = session.server.replaceAll(RegExp(r'/+$'), '');
      final token = session.token;

      if (server.isEmpty || token.isEmpty) {
        logger.d('ConnectionManager: missing saved server/token');
        _setStatus(ConnectionStatus.authFailed);
        return;
      }

      if (!await _isReachable()) {
        logger.d('ConnectionManager: server unreachable');
        _setStatus(ConnectionStatus.offline);
        return;
      }

      var result = await _checkAuth(server);
      if (result == ConnectionStatus.authFailed) {
        logger.d('ConnectionManager: token rejected, attempting silent re-login');
        result = await _trySilentRelogin(server);
      }

      _setStatus(result);
    } catch (e) {
      logger.d('ConnectionManager: validateStartup error: $e');
      _setStatus(ConnectionStatus.offline);
    } finally {
      _checking = false;
      if (_recheckRequested && !_disposed && !_paused) {
        _recheckRequested = false;
        unawaited(validateStartup());
      }
    }
  }

  Future<bool> _isReachable() async {
    try {
      final server = SessionStore.current.server.replaceAll(RegExp(r'/+$'), '');
      if (server.isEmpty) return false;

      final response =
          await JellyfinApi(server).getPublicSystemInfo().timeout(_timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<ConnectionStatus> _checkAuth(String server) async {
    try {
      final session = SessionStore.current;
      final response = await JellyfinApi(server).getCurrentUser(
        headers: {'Authorization': session.authorization},
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

  // Reauthenticate with the credentials migrated into secure storage.
  Future<ConnectionStatus> _trySilentRelogin(String server) async {
    try {
      final session = SessionStore.current;
      if (session.username.isEmpty) {
        return ConnectionStatus.authFailed;
      }
      logger.d('ConnectionManager: silent re-login for ${session.username}');
      final result = await LoginProvider.silentLogin(
        server,
        session.username,
        session.password,
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
    await validateStartup();
  }
}
