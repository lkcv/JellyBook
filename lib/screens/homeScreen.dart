// The purpose of this file is to have a screen where the users
// can see all their comics and manage them

import 'package:flutter/material.dart';
import 'package:jellybook/models/login.dart';
import 'package:isar/isar.dart';
import 'package:isar_flutter_libs/isar_flutter_libs.dart';
import 'package:google_nav_bar/google_nav_bar.dart';
import 'package:provider/provider.dart';

// Screens imports
import 'package:jellybook/screens/MainScreens/mainMenu.dart';
import 'package:jellybook/screens/MainScreens/settingsScreen.dart';
import 'package:jellybook/screens/MainScreens/downloadsScreen.dart';
import 'package:jellybook/screens/MainScreens/continueReadingScreen.dart';
import 'package:jellybook/screens/loginScreen.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/providers/connectionManager.dart';

// Cupertino imports
import 'package:flutter/cupertino.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late ConnectionManager _connectionManager;

  @override
  void initState() {
    super.initState();
    _connectionManager = ConnectionManager();
    _validateCredentialsAndListen();
  }

  void _validateCredentialsAndListen() {
    _connectionManager.addListener(_onConnectionStatusChanged);
    _connectionManager.validateStartup();
  }

  void _onConnectionStatusChanged() {
    if (_connectionManager.status == ConnectionStatus.authFailed) {
      // 401: redirect to login
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => LoginScreen()),
      );
    }
  }

  @override
  void dispose() {
    _connectionManager.removeListener(_onConnectionStatusChanged);
    _connectionManager.dispose();
    super.dispose();
  }

  Future<void> logout() async {
    final isar = Isar.getInstance();
    var logins = await isar!.logins.where().findAll();
    var loginIds = logins.map((e) => e.isarId).toList();
    await isar.writeTxn(() async {
      isar.logins.deleteAll(loginIds);
      logger.d('deleted ${loginIds.length} logins');
    });
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => LoginScreen()),
    );
  }

  int _selectedIndex = 0;
  final List<Widget> screens = [
    MainMenu(),
    DownloadsScreen(),
    ContinueReadingScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      extendBody: true,
      body: screens[_selectedIndex],
      bottomNavigationBar: Theme.of(context).platform == TargetPlatform.iOS
          ? CupertinoTabBar(
              backgroundColor: Theme.of(context).brightness == Brightness.dark
                  ? Theme.of(context).primaryColor
                  : CupertinoTheme.of(context).barBackgroundColor,
              items: [
                BottomNavigationBarItem(
                  icon: Icon(Icons.home),
                  label: AppLocalizations.of(context)?.home ?? 'Home',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.download),
                  label: AppLocalizations.of(context)?.downloads ?? 'Downloads',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.book),
                  label: AppLocalizations.of(context)?.reading ?? 'Reading',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.settings),
                  label: AppLocalizations.of(context)?.settings ?? 'Settings',
                ),
              ],
              currentIndex: _selectedIndex,
              onTap: (index) {
                setState(() {
                  _selectedIndex = index;
                });
              },
            )
          : Container(
              height: 70,
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(
                    left: 15.0, right: 15.0, top: 8, bottom: 15),
                child: GNav(
                  rippleColor: Theme.of(context).colorScheme.secondary,
                  hoverColor: Theme.of(context).colorScheme.secondary,
                  activeColor: Colors.white,
                  tabBorderRadius: 15,
                  tabBackgroundGradient: LinearGradient(
                    colors: [
                      const Color(0xFFAA5CC3).withOpacity(0.75),
                      const Color(0xFF00A4DC).withOpacity(0.75),
                    ],
                  ),
                  tabActiveBorder:
                      Theme.of(context).brightness == Brightness.dark
                          ? Border.all(color: Colors.transparent, width: 0)
                          : Border.all(color: Colors.white, width: 1),
                  haptic: true,
                  iconSize: 24,
                  gap: 7,
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 7),
                  duration: Duration(milliseconds: 600),
                  tabBackgroundColor: Theme.of(context).primaryColor,
                  color: Colors.white,
                  tabs: [
                    GButton(
                      icon: Icons.home,
                      text: AppLocalizations.of(context)?.home ?? 'Home',
                    ),
                    GButton(
                      icon: Icons.download,
                      text: AppLocalizations.of(context)?.downloads ??
                          'Downloads',
                    ),
                    GButton(
                      icon: Icons.book,
                      text: AppLocalizations.of(context)?.reading ?? 'Reading',
                    ),
                    GButton(
                      icon: Icons.settings,
                      text:
                          AppLocalizations.of(context)?.settings ?? 'Settings',
                    ),
                  ],
                  selectedIndex: _selectedIndex,
                  onTabChange: (index) {
                    setState(() {
                      _selectedIndex = index;
                    });
                  },
                ),
              ),
            ),
    );
  }
}
