import 'package:isar/isar.dart';

part 'login.g.dart';

@Collection()
class Login {
  Id isarId = Isar.autoIncrement;

  @Index()
  String serverUrl;
  String username;
  String password = "";
  String userId = '';
  String client = 'Kurage';
  String device = '';
  String deviceId = '';
  String version = '';

  Login({
    required this.serverUrl,
    required this.username,
    this.password = "",
    this.userId = '',
    this.client = 'Kurage',
    this.device = '',
    this.deviceId = '',
    this.version = '',
  });
}
