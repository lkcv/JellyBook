import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kurage/screens/login_screen.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kurage/models/entry.dart';
import 'package:kurage/models/folder.dart';
import 'package:kurage/models/login.dart';
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

Future<void> migrateToNewVersion() async {
  // check if a file exists for com.example.jellybook
  // if it does, move it to the new location
  // if it doesn't, do nothing

  // get the old path
  Directory oldPath = await _localPath.then((value) {
    return Directory(value.replaceFirst(
        "com.KaraWilson.JellyBook", "com.example.jellybook"));
  });
  // if the old path exists, move everything to the new path
  if (await oldPath.exists()) {
    moveFilesRecursive(oldPath);
    // delete the old path
    oldPath.deleteSync(recursive: true);
  }
}

void moveFilesRecursive(Directory dir) {
  dir.listSync().forEach((element) {
    if (element is File) {
      // move the file
      element.copySync(element.path
          .replaceFirst("com.example.jellybook", "com.KaraWilson.JellyBook"));
      element.deleteSync();
    } else if (element is Directory) {
      moveFilesRecursive(element);
    }
  });
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

  // migrate to new app id
  if (Platform.isAndroid) {
    await migrateToNewVersion();
  }

  SharedPreferences prefs = await SharedPreferences.getInstance();

  // dio allow self signed certificates
  HttpOverrides.global = MyHttpOverrides();

  // path for isar database
  Directory dir = await getApplicationDocumentsDirectory();

  final isar = await Isar.open([EntrySchema, FolderSchema, LoginSchema],
      directory: dir.path);

  // set the localPath variable
  localPath = await _localPath;
  // check if localPath file exists
  if (!await File("$localPath/jellybook.log").exists()) {
    // create the file
    await File("$localPath/jellybook.log").create();
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
      prefs: prefs,
    ));
  } else {
    runApp(MyApp(prefs: prefs));
  }
}

class MyApp extends StatelessWidget {
  final String? url;
  final String? username;
  final String? password;
  final SharedPreferences prefs;

  const MyApp({
    super.key,
    this.url,
    this.username,
    this.password,
    required this.prefs,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<LocaleChangeNotifier>(
            create: (context) => LocaleChangeNotifier(context, prefs)),
        ChangeNotifierProvider<ThemeChangeNotifier>(create: (context) {
          final notifier = ThemeChangeNotifier(context, prefs);
          // The settings screen persists the selected theme, but a new provider
          // otherwise starts with its default theme on every app launch.
          // The provider persists the effective light/dark theme to 'theme'.
          // Save the user's chosen mode separately so automatic system changes
          // never turn the System choice into an explicit Light or Dark choice.
          // Existing installs migrate their original 'theme' selection here.
          final selectedTheme = prefs.getString('themeSelection') ??
              prefs.getString('theme') ?? 'system';
          if (!prefs.containsKey('themeSelection')) {
            prefs.setString('themeSelection', selectedTheme);
          }
          notifier.setTheme = selectedTheme == 'system'
              ? _systemThemeForPlatform()
              : selectedTheme;
          return notifier;
        }),
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
          prefs: prefs,
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

// Resolve the saved 'system' selection against the OS appearance rather than
// treating it as a fifth fixed color scheme. This works on Android and iOS.
String _systemThemeForPlatform() =>
    WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark
        ? 'dark'
        : 'light';

// The Settings screen updates the selected mode separately from the effective
// theme. Observe provider changes and platform brightness without ever changing
// the stored user selection during automatic OS appearance updates.
class _SystemThemeFollower extends StatefulWidget {
  const _SystemThemeFollower({required this.prefs, required this.child});

  final SharedPreferences prefs;
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
    if (!mounted || widget.prefs.getString('themeSelection') != 'system' ||
        _updateScheduled) {
      return;
    }

    // The provider can notify listeners during a Settings rebuild. Apply any
    // correction after that frame instead of notifying during build.
    _updateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (!mounted || widget.prefs.getString('themeSelection') != 'system') return;
      final notifier = _themeNotifier;
      if (notifier == null) return;
      final systemBrightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      if (notifier.getTheme.brightness != systemBrightness) {
        // This setter updates the effective 'theme' key only. It must never
        // overwrite 'themeSelection', which records the user's System choice.
        notifier.setTheme = _systemThemeForPlatform();
      }
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
