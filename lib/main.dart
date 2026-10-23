import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kurage/screens/login_screen.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kurage/models/app_settings.dart';
import 'package:kurage/models/entry.dart';
import 'package:kurage/models/folder.dart';
import 'package:kurage/models/login.dart';
import 'package:kurage/providers/app_settings_store.dart';
import 'package:kurage/screens/home_screen.dart';
import 'package:kurage/providers/connection_manager.dart';
import 'package:kurage/providers/download_queue.dart';
import 'dart:io';

import 'package:kurage/l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:kurage/providers/language_provider.dart';
import 'package:kurage/providers/theme_provider.dart';
import 'widgets/floating_snackbar.dart';
import 'package:kurage/variables.dart';

Future<String> get _localPath async {
  // get the directory that normally is located at /storage/emulated/0/Documents/
  Directory directory;
  if (Platform.isAndroid) {
    directory = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
  } else {
    directory = await getApplicationDocumentsDirectory();
  }
  return directory.path;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // top bar always visible, bottom bar only visible when swiped up
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky, overlays: [
    SystemUiOverlay.top,
  ]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
  ));

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SharedPreferences prefs = await SharedPreferences.getInstance();

  // dio allow self signed certificates
  HttpOverrides.global = MyHttpOverrides();

  // path for isar database
  Directory dir = await getApplicationDocumentsDirectory();

  final isar = await Isar.open(
      [AppSettingsSchema, EntrySchema, FolderSchema, LoginSchema],
      directory: dir.path);
  await AppSettingsStore.initialize(isar, prefs);

  // set the localPath variable
  localPath = await _localPath;
  // check if localPath file exists
  if (!await File("$localPath/kurage.log").exists()) {
    // create the file
    await File("$localPath/kurage.log").create();
  }
  debugPrint("localPath: $localPath");

  // set the logStoragePath variable
  logStoragePath = "$localPath/Documents/";

  var logins = await isar.logins.where().findAll();
  if (logins.isNotEmpty) {
    prefs.setString("username", logins[0].username);
    runApp(MyApp(
      url: logins[0].serverUrl,
      username: logins[0].username,
      password: logins[0].password,
    ));
  } else {
    runApp(const MyApp());
  }
}

class MyApp extends StatelessWidget {
  final String? url;
  final String? username;
  final String? password;

  const MyApp({
    super.key,
    this.url,
    this.username,
    this.password,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<LocaleChangeNotifier>(
            create: (context) => LocaleChangeNotifier(AppSettingsStore.current)),
        ChangeNotifierProvider<ThemeChangeNotifier>(
            create: (context) => ThemeChangeNotifier(AppSettingsStore.current)),
        ChangeNotifierProvider<ConnectionManager>(
          create: (context) {
            final manager = ConnectionManager();
            // Resume queued transfers only after this provider verifies Jellyfin.
            DownloadQueue.instance.bindConnectionManager(manager);
            // Start monitoring after creation
            WidgetsBinding.instance.addPostFrameCallback((_) {
              manager.startMonitoring();
            });
            return manager;
          },
        ),
      ],
      builder: (context, _) {
        return _SystemThemeFollower(
          child: Consumer2<LocaleChangeNotifier, ThemeChangeNotifier>(
            builder: (context, localeChangeNotifier, themeChangeNotifier, _) {
          Locale locale = localeChangeNotifier.locale;
          ThemeData themeData = themeChangeNotifier.getTheme;
          return MaterialApp(
            title: 'Kurage',
            debugShowCheckedModeBanner: false,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: locale,
            // Use one consistent floating snackbar style for Light, Dark,
            // AMOLED and the OS-resolved System theme.
            theme: themeData.copyWith(
              snackBarTheme: floatingSnackBarTheme(themeData),
            ),
            home: url != null && username != null && password != null
                ? const HomeScreen()
                : const LoginScreen(),
          );
            },
          ),
        );
      },
    );
  }
}

// Keep the effective System theme in memory; only the user's selection is saved.
class _SystemThemeFollower extends StatefulWidget {
  const _SystemThemeFollower({required this.child});

  final Widget child;

  @override
  State<_SystemThemeFollower> createState() => _SystemThemeFollowerState();
}

class _SystemThemeFollowerState extends State<_SystemThemeFollower>
    with WidgetsBindingObserver {
  ThemeChangeNotifier? _themeNotifier;
  bool _updateScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = Provider.of<ThemeChangeNotifier>(context, listen: false);
    if (!identical(notifier, _themeNotifier)) {
      _themeNotifier?.removeListener(_syncSystemTheme);
      _themeNotifier = notifier;
      notifier.addListener(_syncSystemTheme);
    }
    _syncSystemTheme();
  }

  @override
  void didChangePlatformBrightness() {
    _syncSystemTheme();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncSystemTheme();
  }

  void _syncSystemTheme() {
    if (!mounted || _themeNotifier?.selectedTheme != 'system' ||
        _updateScheduled) {
      return;
    }

    // The provider can notify listeners during a Settings rebuild.
    _updateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (!mounted) return;
      _themeNotifier?.syncSystemTheme();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _themeNotifier?.removeListener(_syncSystemTheme);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpClient client = super.createHttpClient(context);
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
    return client;
  }
}
