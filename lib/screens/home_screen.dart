// The purpose of this file is to have a screen where the users
// can see all their comics and manage them

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:jellybook/models/login.dart';
import 'package:isar/isar.dart';
import 'package:google_nav_bar/google_nav_bar.dart';
import 'package:provider/provider.dart';

// Screens imports
import 'package:jellybook/screens/MainScreens/library_screen.dart';
import 'package:jellybook/screens/MainScreens/settings_screen.dart';
import 'package:jellybook/screens/MainScreens/search_screen.dart';
import 'package:jellybook/screens/login_screen.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/providers/connection_manager.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
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
      MaterialPageRoute(builder: (context) => const LoginScreen()),
    );
  }

  int _selectedIndex = 0;
  // Last non-search tab so Search can return to wherever the user was
  int _previousIndex = 0;

  static const int _searchIndex = 1;
  static const Duration _tabAnimationDuration = Duration(milliseconds: 200);

  void _goBackFromSearch() {
    setState(() {
      _selectedIndex = _previousIndex;
    });
  }

  void _onTabChange(int index) {
    setState(() {
      // Remember where we were when entering Search
      if (index == _searchIndex && _selectedIndex != _searchIndex) {
        _previousIndex = _selectedIndex;
      }
      _selectedIndex = index;
    });
  }

  // Give each tab an equal third of the bar and allow immediate selection.
  // GNav animates the visual change using its existing 200ms duration.
  void _onWideTabTap(int index) {
    if (index == _selectedIndex) return;
    HapticFeedback.selectionClick();
    _onTabChange(index);
  }

  // Keep the Library mounted to retain its image listeners and scroll state.
  // Other tabs are still disposed when they are no longer selected.
  Widget _otherTab() {
    switch (_selectedIndex) {
      case 1:
        return SearchScreen(onBack: _goBackFromSearch);
      case 2:
        return const SettingsScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch the ConnectionManager from the provider
    final connectionManager = Provider.of<ConnectionManager>(context);

    // If auth failed, redirect to login
    if (connectionManager.status == ConnectionStatus.authFailed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const LoginScreen()),
          );
        }
      });
    }

    // Keep Android's current bar height unchanged. On iPhone, extend the same
    // colored bar below its tappable content to clear the home indicator.
    final iosBottomInset = Theme.of(context).platform == TargetPlatform.iOS
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      extendBody: true,
      body: IndexedStack(
        index: _selectedIndex == 0 ? 0 : 1,
        children: [
          LibraryScreen(isActive: _selectedIndex == 0),
          _otherTab(),
        ],
      ),
      bottomNavigationBar: Container(
        // Reserve space beneath the bar for the keyboard so GNav stays
        // visible and tappable directly above it.
        margin: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        height: 70 + iosBottomInset,
        padding: EdgeInsets.only(bottom: iosBottomInset),
        decoration: BoxDecoration(
          color: Theme.of(context).primaryColor,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
        ),
        // Retain the original GNav as the visual/animation layer.
        // A full-width hit layer assigns every point to one of 3 tabs.
        child: Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(
              child: IgnorePointer(
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
                        const Color(0xFFAA5CC3).withValues(alpha: 0.75),
                        const Color(0xFF00A4DC).withValues(alpha: 0.75),
                      ],
                    ),
                    tabActiveBorder:
                        Theme.of(context).brightness == Brightness.dark
                            ? Border.all(
                                color: Colors.transparent, width: 0)
                            : Border.all(color: Colors.white, width: 1),
                    haptic: true,
                    iconSize: 24,
                    gap: 7,
                    padding: EdgeInsets.symmetric(
                        horizontal: 16, vertical: 7),
                    duration: _tabAnimationDuration,
                    tabBackgroundColor: Theme.of(context).primaryColor,
                    color: Colors.white,
                    tabs: [
                      GButton(
                        icon: Icons.local_library_outlined,
                        text: AppLocalizations.of(context)?.library ??
                            'Library',
                      ),
                      GButton(
                        icon: Icons.search,
                        text: AppLocalizations.of(context)?.search ??
                            'Search',
                      ),
                      GButton(
                        icon: Icons.settings,
                        text: AppLocalizations.of(context)?.settings ??
                            'Settings',
                      ),
                    ],
                    selectedIndex: _selectedIndex,
                    onTabChange: _onTabChange,
                  ),
                ),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < 3; index++)
                  Expanded(
                    child: Semantics(
                      label: [
                        AppLocalizations.of(context)?.library ?? 'Library',
                        AppLocalizations.of(context)?.search ?? 'Search',
                        AppLocalizations.of(context)?.settings ?? 'Settings',
                      ][index],
                      button: true,
                      selected: _selectedIndex == index,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _onWideTabTap(index),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
