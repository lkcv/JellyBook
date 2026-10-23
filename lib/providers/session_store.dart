import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:isar/isar.dart';
import 'package:kurage/models/login.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Session {
  const Session({
    this.server = '',
    this.username = '',
    this.userId = '',
    this.token = '',
    this.password = '',
    this.client = 'Kurage',
    this.device = '',
    this.deviceId = '',
    this.version = '',
  });

  final String server;
  final String username;
  final String userId;
  final String token;
  final String password;
  final String client;
  final String device;
  final String deviceId;
  final String version;

  String get authorization =>
      'MediaBrowser Client="$client", Device="$device", '
      'DeviceId="$deviceId", Version="$version", Token="$token"';
}

class SessionStore {
  static const _storage = FlutterSecureStorage();
  static const _legacyKeys = <String>[
    'server', 'accessToken', 'UserId', 'ServerId', 'username',
    'client', 'device', 'deviceId', 'version',
  ];
  static Session _current = const Session();

  static Session get current => _current;

  static Future<void> initialize(Isar isar, SharedPreferences prefs) async {
    final login = await isar.logins.where().findFirst();
    if (login == null) {
      await _clearLegacyPreferences(prefs);
      return;
    }

    final secureServer = await _storage.read(key: 'server');
    final sameServer = secureServer == login.serverUrl;
    final username = sameServer
        ? (await _storage.read(key: 'username') ?? login.username)
        : login.username;
    final password = sameServer
        ? (await _storage.read(key: 'password') ?? login.password)
        : login.password;
    final token = sameServer
        ? (await _storage.read(key: 'accessToken') ??
            prefs.getString('accessToken') ?? '')
        : (prefs.getString('accessToken') ?? '');
    final session = Session(
      server: login.serverUrl,
      username: username,
      userId: login.userId.isNotEmpty
          ? login.userId
          : (prefs.getString('UserId') ??
              await _storage.read(key: 'UserId') ?? ''),
      token: token,
      password: password,
      client: login.client.isNotEmpty
          ? login.client : (prefs.getString('client') ?? 'Kurage'),
      device: login.device.isNotEmpty
          ? login.device : (prefs.getString('device') ?? ''),
      deviceId: login.deviceId.isNotEmpty
          ? login.deviceId : (prefs.getString('deviceId') ?? ''),
      version: login.version.isNotEmpty
          ? login.version : (prefs.getString('version') ?? ''),
    );

    await _storage.write(key: 'server', value: session.server);
    await _storage.write(key: 'username', value: session.username);
    if (token.isNotEmpty) {
      await _storage.write(key: 'accessToken', value: token);
    }
    if (password.isNotEmpty) {
      await _storage.write(key: 'password', value: password);
    }
    login
      ..username = session.username
      ..userId = session.userId
      ..client = session.client
      ..device = session.device
      ..deviceId = session.deviceId
      ..version = session.version
      ..password = '';
    await isar.writeTxn(() async => isar.logins.put(login));
    _current = session;
    await _clearLegacyPreferences(prefs);
  }

  static Future<void> save({
    required String server,
    required String username,
    required String userId,
    required String token,
    required String password,
    required String client,
    required String device,
    required String deviceId,
    required String version,
  }) async {
    await _storage.write(key: 'server', value: server);
    await _storage.write(key: 'username', value: username);
    await _storage.write(key: 'accessToken', value: token);
    await _storage.write(key: 'password', value: password);

    final isar = Isar.getInstance()!;
    await isar.writeTxn(() async {
      await isar.logins.clear();
      await isar.logins.put(Login(
        serverUrl: server,
        username: username,
        userId: userId,
        client: client,
        device: device,
        deviceId: deviceId,
        version: version,
      ));
    });
    _current = Session(
      server: server,
      username: username,
      userId: userId,
      token: token,
      password: password,
      client: client,
      device: device,
      deviceId: deviceId,
      version: version,
    );
    await _clearLegacyPreferences(await SharedPreferences.getInstance());
  }

  static Future<void> clear() async {
    _current = const Session();
    for (final key in <String>[
      ..._legacyKeys,
      'password',
    ]) {
      await _storage.delete(key: key);
    }
    await _clearLegacyPreferences(await SharedPreferences.getInstance());
  }

  static Future<void> _clearLegacyPreferences(SharedPreferences prefs) async {
    for (final key in _legacyKeys) {
      await prefs.remove(key);
    }
  }
}
