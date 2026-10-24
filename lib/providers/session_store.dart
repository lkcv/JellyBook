import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:isar/isar.dart';
import 'package:kurage/models/login.dart';

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
  static const _secureKeys = <String>[
    'server', 'accessToken', 'password', 'username', 'UserId', 'ServerId',
    'client', 'device', 'deviceId', 'version',
  ];
  static Session _current = const Session();

  static Session get current => _current;

  static Future<void> initialize(Isar isar) async {
    final login = await isar.logins.where().findFirst();
    if (login == null) {
      _current = const Session();
      return;
    }

    final sameServer = await _storage.read(key: 'server') == login.serverUrl;
    _current = Session(
      server: login.serverUrl,
      username: login.username,
      userId: login.userId,
      token: sameServer ? (await _storage.read(key: 'accessToken') ?? '') : '',
      password: sameServer ? (await _storage.read(key: 'password') ?? '') : '',
      client: login.client,
      device: login.device,
      deviceId: login.deviceId,
      version: login.version,
    );
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
  }

  static Future<void> clear() async {
    _current = const Session();
    for (final key in _secureKeys) {
      await _storage.delete(key: key);
    }
  }
}
