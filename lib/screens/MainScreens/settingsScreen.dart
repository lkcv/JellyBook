// The purpose of this file is to allow the user to change the settings of the app

import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/models/login.dart';
import 'package:jellybook/screens/loginScreen.dart';
import 'package:jellybook/providers/themeProvider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart' as p_info;
import 'package:provider/provider.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/providers/languageProvider.dart';
import 'package:jellybook/widgets/SettingsItem.dart';
import 'package:jellybook/widgets/jellybookImageCache.dart';
import 'package:jellybook/widgets/readerCacheSettings.dart';
import 'package:jellybook/variables.dart';

import 'package:tentacle/tentacle.dart';

// Match the Library's two 17.5px concave header corners without moving
// the Settings list or changing its scrolling behavior.
class _SettingsHeaderCornersPainter extends CustomPainter {
  const _SettingsHeaderCornersPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.height, size.width / 2);
    if (r <= 0) return;
    final paint = Paint()..color = color;
    final cornerRadius = Radius.circular(r);

    final left = Path()
      ..moveTo(0, 0)
      ..lineTo(r, 0)
      ..arcToPoint(Offset(0, r), radius: cornerRadius, clockwise: false)
      ..close();
    final right = Path()
      ..moveTo(size.width - r, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, r)
      ..arcToPoint(Offset(size.width - r, 0),
          radius: cornerRadius, clockwise: false)
      ..close();

    canvas.drawPath(left, paint);
    canvas.drawPath(right, paint);
  }

  @override
  bool shouldRepaint(covariant _SettingsHeaderCornersPainter oldDelegate) =>
      oldDelegate.color != color;
}

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const double _headerCornerRadius = 17.5;

  String userName = '';
  String serverUrl = '';
  SharedPreferences? prefs;

  // Cached profile card data so the list does not jump on every visit
  ImageProvider? _profilePic;
  bool _profileReady = false;

  @override
  void initState() {
    getPackageInfo();
    super.initState();
    // Settings.init();
    setSharedPrefs().then((_) {
      if (mounted) setState(() {});
    });
    _loadProfileCard();
  }

  Future<void> _loadProfileCard() async {
    ImageProvider? picture;
    try {
      picture = await getProfilePic();
    } catch (error) {
      logger.e('Could not load settings profile: $error');
    }
    if (!mounted) return;
    setState(() {
      _profilePic = picture;
      _profileReady = true;
    });
  }

  themeListener() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> setSharedPrefs() async {
    prefs = await SharedPreferences.getInstance();
  }

  // Clears the saved login and all cached library data, then returns to the
  // login screen. (Moved here from the main menu's app bar.)
  Future<void> logout() async {
    final isar = Isar.getInstance();
    if (isar == null) return;
    final loginIds =
        (await isar.logins.where().findAll()).map((e) => e.isarId).toList();
    final entryIds =
        (await isar.entrys.where().findAll()).map((e) => e.isarId).toList();
    final folderIds =
        (await isar.folders.where().findAll()).map((e) => e.isarId).toList();
    await isar.writeTxn(() async {
      logger.i('deleted ${loginIds.length} logins');
      await isar.logins.deleteAll(loginIds);
      logger.i('deleted ${entryIds.length} entries');
      await isar.entrys.deleteAll(entryIds);
      logger.i('deleted ${folderIds.length} folders');
      await isar.folders.deleteAll(folderIds);
    });
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => LoginScreen()),
    );
  }

  String version = '';

  Future<void> getPackageInfo() async {
    p_info.PackageInfo packageInfo = await p_info.PackageInfo.fromPlatform();
    version = packageInfo.version;
  }

  @override
  Widget build(BuildContext context) {
    // ThemeManager themeManager = Provider.of<ThemeManager>(context);
    return Scaffold(
      // Match the Library screen's compact, centered black header.
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(MediaQuery.of(context).padding.top + 36),
        child: Container(
          color: Colors.black.withOpacity(0.90),
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
          child: SizedBox(
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // Paint below the header without intercepting settings taps.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: -_headerCornerRadius,
                  height: _headerCornerRadius,
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _SettingsHeaderCornersPainter(
                        color: Colors.black.withOpacity(0.90),
                      ),
                    ),
                  ),
                ),
                Align(
                  // Same notch-aware title alignment as the Library header.
                  alignment: MediaQuery.of(context).padding.top > 30
                      ? const Alignment(0, -0.7)
                      : Alignment.center,
                  child: Text(
                    AppLocalizations.of(context)?.settings ?? 'Settings',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Container(
        padding: const EdgeInsets.all(10),
        child: ListView(
          children: [
            _buildProfileCard(context),
            const SizedBox(height: 8),
            FutureBuilder(
              future: languageSettings(context),
              builder: (BuildContext context, AsyncSnapshot<Widget> snapshot) {
                if (snapshot.hasData) {
                  return snapshot.data!;
                } else {
                  return Container();
                }
              },
            ),
            const SizedBox(
              height: 8,
            ),
            // The two preferences share the same neutral card styling as
            // Storage & cache. Each row opens a bottom-sheet selector.
            _buildPreferencesCard(context),
            const SizedBox(height: 8),
            const ReaderCacheSettings(),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(AppLocalizations.of(context)?.licenses ?? 'Licenses'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      showLicensePage(
                        context: context,
                        applicationName: 'Jellybook',
                        applicationVersion: version,
                        applicationIcon: Image.asset('assets/images/Logo.png'),
                        applicationLegalese:
                            'MIT License. Made with love by Kara Wilson',
                      );
                    },
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.logout_rounded),
                    title: const Text('Log out'),
                    onTap: logout,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 25,
              backgroundColor: scheme.surfaceContainerHighest,
              foregroundImage: _profileReady ? _profilePic : null,
              child: Icon(Icons.person_outline, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    userName.isNotEmpty ? userName : 'Account',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (serverUrl.isNotEmpty)
                    InkWell(
                      onTap: () async {
                        final uri = Uri.tryParse(serverUrl);
                        if (uri != null && await canLaunchUrl(uri)) {
                          await launchUrl(uri,
                              mode: LaunchMode.externalApplication);
                        }
                      },
                      child: Text(
                        serverUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreferencesCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final themeOptions = <String, String>{
      'system': l10n?.systemTheme ?? 'System',
      'light': l10n?.lightTheme ?? 'Light',
      'dark': l10n?.darkTheme ?? 'Dark',
      'amoled': l10n?.amoledTheme ?? 'AMOLED',
    };
    final directionOptions = <String, String>{
      'LTR': l10n?.ltr ?? 'Left to Right',
      'RTL': l10n?.rtl ?? 'Right to Left',
      'Vertical': l10n?.vertical ?? 'Vertical',
    };
    final selectedTheme = prefs?.getString('themeSelection') ??
        prefs?.getString('theme') ?? 'system';
    final selectedDirection = prefs?.getString('readingDirection') ?? 'LTR';

    return Card(
      child: Column(
        children: [
          _choiceTile(
            icon: Icons.color_lens_outlined,
            title: l10n?.theme ?? 'Theme',
            value: themeOptions[selectedTheme] ?? themeOptions['system']!,
            onTap: () async {
              final selected = await _showChoices(
                title: l10n?.theme ?? 'Theme',
                options: themeOptions,
                selected: selectedTheme,
              );
              if (!mounted || selected == null || selected == selectedTheme) {
                return;
              }
              final sharedPrefs = await SharedPreferences.getInstance();
              // Persist the selection independently. ThemeChangeNotifier
              // writes the *applied* theme to 'theme', which may be light or
              // dark when the selection is 'system'.
              await sharedPrefs.setString('themeSelection', selected);
              if (!mounted) return;
              prefs = sharedPrefs;
              context.read<ThemeChangeNotifier>().setTheme = selected;
              setState(() {});
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _choiceTile(
            icon: Icons.format_textdirection_l_to_r_rounded,
            title: l10n?.readingDirection ?? 'Reading Direction',
            value: directionOptions[selectedDirection] ?? directionOptions['LTR']!,
            onTap: () async {
              final selected = await _showChoices(
                title: l10n?.readingDirection ?? 'Reading Direction',
                options: directionOptions,
                selected: selectedDirection,
              );
              if (!mounted || selected == null || selected == selectedDirection) {
                return;
              }
              final sharedPrefs = await SharedPreferences.getInstance();
              await sharedPrefs.setString('readingDirection', selected);
              if (!mounted) return;
              prefs = sharedPrefs;
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Widget _choiceTile({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 130),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }

  Future<String?> _showChoices({
    required String title,
    required Map<String, String> options,
    required String selected,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(title,
                  style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            ...options.entries.map((option) => ListTile(
                  title: Text(option.value),
                  trailing: option.key == selected
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, option.key),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<ImageProvider?> getProfilePic() async {
    p_info.PackageInfo packageInfo = await p_info.PackageInfo.fromPlatform();
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString('server') ?? '';
    final userId = prefs.getString('UserId') ?? '';
    final token = prefs.getString('accessToken') ?? '';
    final username = prefs.getString('username') ?? '';
    final version = packageInfo.version;
    const _client = "JellyBook";
    const _device = "Unknown Device";
    const _deviceId = "Unknown Device id";

    userName = username;
    serverUrl = server;

    // Disk-cache key (same CacheManager as covers). Avoids re-download + layout jump.
    final cacheKey = 'user_profile_$userId';
    try {
      final cached =
          await JellyBookCacheManager.instance.getFileFromCache(cacheKey);
      if (cached != null && await cached.file.exists()) {
        return FileImage(cached.file);
      }
    } catch (e) {
      logger.e('profile cache read failed: $e');
    }

    final headers = {
      'Accept': 'application/json',
      'Accept-Language': 'en-US,en;q=0.5',
      'Accept-Encoding': 'gzip, deflate',
      'Content-Type': 'application/json',
      "Authorization":
          "MediaBrowser Client=\"$_client\", Device=\"$_device\", DeviceId=\"$_deviceId\", Version=\"$version\", Token=\"$token\"",
      'Connection': 'keep-alive',
      'Origin': server,
      'Host': server.substring(server.indexOf("//") + 2, server.length),
      'Content-Length': '0',
    };
    final api = Tentacle(basePathOverride: server).getImageApi();
    Uint8List image = Uint8List(0);
    ImageProvider? imageProvider;
    try {
      var response = await api.getUserImage(
        userId: userId,
        headers: headers,
      );
      logger.i(response.statusCode);
      if (response != null && response.statusCode == 200) {
        image = response.data!;
      }
    } catch (e) {
      logger.e(e.toString());
    }
    if (image.isNotEmpty) {
      try {
        await JellyBookCacheManager.instance.putFile(
          cacheKey,
          image,
          fileExtension: 'jpg',
        );
      } catch (e) {
        logger.e('profile cache write failed: $e');
      }
      imageProvider = MemoryImage(image);
    }
    return imageProvider;
  }

  // Widget themeSettings(BuildContext context) => DropDownSettingsTile(
  //       settingKey: 'theme',
  //       title: AppLocalizations.of(context)?.theme ?? 'theme',
  //       selected: Settings.getValue<String>('theme') ?? 'System',
  //       leading: const Icon(Icons.color_lens),
  //       values: <String, String>{
  //         'System': AppLocalizations.of(context)?.systemTheme ?? 'System',
  //         'Light': AppLocalizations.of(context)?.lightTheme ?? 'Light',
  //         'Dark': AppLocalizations.of(context)?.darkTheme ?? 'Dark',
  //         'Amoled': AppLocalizations.of(context)?.amoledTheme ?? 'Amoled',
  //         // AppLocalizations.of(context)?.systemTheme ?? 'System': 'System',
  //         // AppLocalizations.of(context)?.lightTheme ?? 'Light': 'Light',
  //         // AppLocalizations.of(context)?.darkTheme ?? 'Dark': 'Dark',
  //         // AppLocalizations.of(context)?.amoledTheme ?? 'Amoled': 'Amoled',
  //       },
  //       // give the key and value of the selected theme
  //       onChange: (value) async {
  //         debugPrint('Settings theme: ${Settings.getValue<String>('theme')}');
  //         // debugPrint('Theme changed to $value');
  //         SharedPreferences prefs = await SharedPreferences.getInstance();
  //         ThemeChangeNotifier themeChangeNotifier =
  //             Provider.of<ThemeChangeNotifier>(context, listen: false);
  //         // set the theme to the english value of the selected theme
  //         Settings.setValue<String>('theme', value.toString());
  //         prefs.setString('theme', value.toString().toLowerCase());
  //         themeChangeNotifier.setTheme = value.toString().toLowerCase();
  //       },
  //     );

  // static String capitalize(String s) => s[0].toUpperCase() + s.substring(1);

  static final isoLangs = {
    "ab": {"name": "Abkhaz", "nativeName": "аҧсуа"},
    "aa": {"name": "Afar", "nativeName": "Afaraf"},
    "af": {"name": "Afrikaans", "nativeName": "Afrikaans"},
    "afh": {"name": "Afrihili", "nativeName": "Afrihili"},
    "ak": {"name": "Akan", "nativeName": "Akan"},
    "sq": {"name": "Albanian", "nativeName": "Shqip"},
    "am": {"name": "Amharic", "nativeName": "አማርኛ"},
    "ar": {"name": "Arabic", "nativeName": "العربية"},
    "an": {"name": "Aragonese", "nativeName": "Aragonés"},
    "hy": {"name": "Armenian", "nativeName": "Հայերեն"},
    "as": {"name": "Assamese", "nativeName": "অসমীয়া"},
    "av": {"name": "Avaric", "nativeName": "авар мацӀ, магӀарул мацӀ"},
    "ae": {"name": "Avestan", "nativeName": "avesta"},
    "ay": {"name": "Aymara", "nativeName": "aymar aru"},
    "az": {"name": "Azerbaijani", "nativeName": "azərbaycan dili"},
    "bm": {"name": "Bambara", "nativeName": "bamanankan"},
    "ba": {"name": "Bashkir", "nativeName": "башҡорт теле"},
    "eu": {"name": "Basque", "nativeName": "euskara, euskera"},
    "be": {"name": "Belarusian", "nativeName": "Беларуская"},
    "bn": {"name": "Bengali", "nativeName": "বাংলা"},
    "bh": {"name": "Bihari", "nativeName": "भोजपुरी"},
    "bi": {"name": "Bislama", "nativeName": "Bislama"},
    "bs": {"name": "Bosnian", "nativeName": "bosanski jezik"},
    "br": {"name": "Breton", "nativeName": "brezhoneg"},
    "bg": {"name": "Bulgarian", "nativeName": "български език"},
    "my": {"name": "Burmese", "nativeName": "ဗမာစာ"},
    "ca": {"name": "Catalan; Valencian", "nativeName": "Català"},
    "ch": {"name": "Chamorro", "nativeName": "Chamoru"},
    "ce": {"name": "Chechen", "nativeName": "нохчийн мотт"},
    "ny": {
      "name": "Chichewa; Chewa; Nyanja",
      "nativeName": "chiCheŵa, chinyanja"
    },
    "zh": {"name": "Chinese", "nativeName": "中文 (Zhōngwén), 汉语, 漢語"},
    "zh_CHT": {
      "name": "Chinese (Simplified CHT)",
      "nativeName": "中文 (Zhōngwén), 汉语, 漢語"
    },
    "zh_Hant": {
      "name": "Chinese (Simplified Hant)",
      "nativeName": "中文 (Zhōngwén), 汉语, 漢語"
    },
    "cv": {"name": "Chuvash", "nativeName": "чӑваш чӗлхи"},
    "kw": {"name": "Cornish", "nativeName": "Kernewek"},
    "co": {"name": "Corsican", "nativeName": "corsu, lingua corsa"},
    "cr": {"name": "Cree", "nativeName": "ᓀᐦᐃᔭᐍᐏᐣ"},
    "hr": {"name": "Croatian", "nativeName": "hrvatski"},
    "cs": {"name": "Czech", "nativeName": "česky, čeština"},
    "da": {"name": "Danish", "nativeName": "dansk"},
    "dv": {"name": "Divehi; Dhivehi; Maldivian;", "nativeName": "ދިވެހި"},
    "nl": {"name": "Dutch", "nativeName": "Nederlands, Vlaams"},
    "en": {"name": "English", "nativeName": "English"},
    "en_pirate": {"name": "English (Pirate)", "nativeName": "English (Pirate)"},
    "eo": {"name": "Esperanto", "nativeName": "Esperanto"},
    "et": {"name": "Estonian", "nativeName": "eesti, eesti keel"},
    "ee": {"name": "Ewe", "nativeName": "Eʋegbe"},
    "fo": {"name": "Faroese", "nativeName": "føroyskt"},
    "fj": {"name": "Fijian", "nativeName": "vosa Vakaviti"},
    "fi": {"name": "Finnish", "nativeName": "suomi, suomen kieli"},
    "fr": {"name": "French", "nativeName": "français, langue française"},
    "ff": {
      "name": "Fula; Fulah; Pulaar; Pular",
      "nativeName": "Fulfulde, Pulaar, Pular"
    },
    "gl": {"name": "Galician", "nativeName": "Galego"},
    "ka": {"name": "Georgian", "nativeName": "ქართული"},
    "de": {"name": "German", "nativeName": "Deutsch"},
    "el": {"name": "Greek, Modern", "nativeName": "Ελληνικά"},
    "gn": {"name": "Guaraní", "nativeName": "Avañeẽ"},
    "gu": {"name": "Gujarati", "nativeName": "ગુજરાતી"},
    "ht": {"name": "Haitian; Haitian Creole", "nativeName": "Kreyòl ayisyen"},
    "ha": {"name": "Hausa", "nativeName": "Hausa, هَوُسَ"},
    "he": {"name": "Hebrew (modern)", "nativeName": "עברית"},
    "hz": {"name": "Herero", "nativeName": "Otjiherero"},
    "hi": {"name": "Hindi", "nativeName": "हिन्दी, हिंदी"},
    "ho": {"name": "Hiri Motu", "nativeName": "Hiri Motu"},
    "hu": {"name": "Hungarian", "nativeName": "Magyar"},
    "ia": {"name": "Interlingua", "nativeName": "Interlingua"},
    "id": {"name": "Indonesian", "nativeName": "Bahasa Indonesia"},
    "ie": {
      "name": "Interlingue",
      "nativeName": "Originally called Occidental; then Interlingue after WWII"
    },
    "ga": {"name": "Irish", "nativeName": "Gaeilge"},
    "ig": {"name": "Igbo", "nativeName": "Asụsụ Igbo"},
    "ik": {"name": "Inupiaq", "nativeName": "Iñupiaq, Iñupiatun"},
    "io": {"name": "Ido", "nativeName": "Ido"},
    "is": {"name": "Icelandic", "nativeName": "Íslenska"},
    "it": {"name": "Italian", "nativeName": "Italiano"},
    "iu": {"name": "Inuktitut", "nativeName": "ᐃᓄᒃᑎᑐᑦ"},
    "ja": {"name": "Japanese", "nativeName": "日本語 (にほんご／にっぽんご)"},
    "jv": {"name": "Javanese", "nativeName": "basa Jawa"},
    "kl": {
      "name": "Kalaallisut, Greenlandic",
      "nativeName": "kalaallisut, kalaallit oqaasii"
    },
    "kn": {"name": "Kannada", "nativeName": "ಕನ್ನಡ"},
    "kr": {"name": "Kanuri", "nativeName": "Kanuri"},
    "ks": {"name": "Kashmiri", "nativeName": "कश्मीरी, كشميري‎"},
    "kk": {"name": "Kazakh", "nativeName": "Қазақ тілі"},
    "km": {"name": "Khmer", "nativeName": "ភាសាខ្មែរ"},
    "ki": {"name": "Kikuyu, Gikuyu", "nativeName": "Gĩkũyũ"},
    "rw": {"name": "Kinyarwanda", "nativeName": "Ikinyarwanda"},
    "ky": {"name": "Kirghiz, Kyrgyz", "nativeName": "кыргыз тили"},
    "kv": {"name": "Komi", "nativeName": "коми кыв"},
    "kg": {"name": "Kongo", "nativeName": "KiKongo"},
    "ko": {"name": "Korean", "nativeName": "한국어 (韓國語), 조선말 (朝鮮語)"},
    "ku": {"name": "Kurdish", "nativeName": "Kurdî, كوردی‎"},
    "kj": {"name": "Kwanyama, Kuanyama", "nativeName": "Kuanyama"},
    "la": {"name": "Latin", "nativeName": "latine, lingua latina"},
    "lb": {"name": "Letzeburgesch", "nativeName": "Lëtzebuergesch"},
    "lg": {"name": "Luganda", "nativeName": "Luganda"},
    "li": {
      "name": "Limburgish, Limburgan, Limburger",
      "nativeName": "Limburgs"
    },
    "ln": {"name": "Lingala", "nativeName": "Lingála"},
    "lo": {"name": "Lao", "nativeName": "ພາສາລາວ"},
    "lt": {"name": "Lithuanian", "nativeName": "lietuvių kalba"},
    "lu": {"name": "Luba-Katanga", "nativeName": ""},
    "lv": {"name": "Latvian", "nativeName": "latviešu valoda"},
    "gv": {"name": "Manx", "nativeName": "Gaelg, Gailck"},
    "mk": {"name": "Macedonian", "nativeName": "македонски јазик"},
    "mg": {"name": "Malagasy", "nativeName": "Malagasy fiteny"},
    "ms": {"name": "Malay", "nativeName": "bahasa Melayu, بهاس ملايو‎"},
    "ml": {"name": "Malayalam", "nativeName": "മലയാളം"},
    "mt": {"name": "Maltese", "nativeName": "Malti"},
    "mi": {"name": "Māori", "nativeName": "te reo Māori"},
    "mr": {"name": "Marathi (Marāṭhī)", "nativeName": "मराठी"},
    "mh": {"name": "Marshallese", "nativeName": "Kajin M̧ajeļ"},
    "mn": {"name": "Mongolian", "nativeName": "монгол"},
    "na": {"name": "Nauru", "nativeName": "Ekakairũ Naoero"},
    "nv": {"name": "Navajo, Navaho", "nativeName": "Diné bizaad, Dinékʼehǰí"},
    "nb": {"name": "Norwegian Bokmål", "nativeName": "Norsk bokmål"},
    "nd": {"name": "North Ndebele", "nativeName": "isiNdebele"},
    "ne": {"name": "Nepali", "nativeName": "नेपाली"},
    "ng": {"name": "Ndonga", "nativeName": "Owambo"},
    "nn": {"name": "Norwegian Nynorsk", "nativeName": "Norsk nynorsk"},
    "no": {"name": "Norwegian", "nativeName": "Norsk"},
    "ii": {"name": "Nuosu", "nativeName": "ꆈꌠ꒿ Nuosuhxop"},
    "nr": {"name": "South Ndebele", "nativeName": "isiNdebele"},
    "oc": {"name": "Occitan", "nativeName": "Occitan"},
    "oj": {"name": "Ojibwe, Ojibwa", "nativeName": "ᐊᓂᔑᓈᐯᒧᐎᓐ"},
    "cu": {
      "name":
          "Old Church Slavonic, Church Slavic, Church Slavonic, Old Bulgarian, Old Slavonic",
      "nativeName": "ѩзыкъ словѣньскъ"
    },
    "om": {"name": "Oromo", "nativeName": "Afaan Oromoo"},
    "or": {"name": "Oriya", "nativeName": "ଓଡ଼ିଆ"},
    "os": {"name": "Ossetian, Ossetic", "nativeName": "ирон æвзаг"},
    "pa": {"name": "Panjabi, Punjabi", "nativeName": "ਪੰਜਾਬੀ, پنجابی‎"},
    "pi": {"name": "Pāli", "nativeName": "पाऴि"},
    "fa": {"name": "Persian", "nativeName": "فارسی"},
    "pl": {"name": "Polish", "nativeName": "polski"},
    "ps": {"name": "Pashto, Pushto", "nativeName": "پښتو"},
    "pt": {"name": "Portuguese", "nativeName": "Português"},
    "qu": {"name": "Quechua", "nativeName": "Runa Simi, Kichwa"},
    "rm": {"name": "Romansh", "nativeName": "rumantsch grischun"},
    "rn": {"name": "Kirundi", "nativeName": "kiRundi"},
    "ro": {"name": "Romanian", "nativeName": "română"},
    "ru": {"name": "Russian", "nativeName": "русский язык"},
    "sa": {"name": "Sanskrit (Saṁskṛta)", "nativeName": "संस्कृतम्"},
    "sc": {"name": "Sardinian", "nativeName": "sardu"},
    "sd": {"name": "Sindhi", "nativeName": "सिन्धी, سنڌي، سندھی‎"},
    "se": {"name": "Northern Sami", "nativeName": "Davvisámegiella"},
    "sm": {"name": "Samoan", "nativeName": "gagana faa Samoa"},
    "sg": {"name": "Sango", "nativeName": "yângâ tî sängö"},
    "sr": {"name": "Serbian", "nativeName": "српски језик"},
    "gd": {"name": "Scottish Gaelic; Gaelic", "nativeName": "Gàidhlig"},
    "sn": {"name": "Shona", "nativeName": "chiShona"},
    "si": {"name": "Sinhala, Sinhalese", "nativeName": "සිංහල"},
    "sk": {"name": "Slovak", "nativeName": "slovenčina"},
    "sl": {"name": "Slovene", "nativeName": "slovenščina"},
    "so": {"name": "Somali", "nativeName": "Soomaaliga, af Soomaali"},
    "st": {"name": "Southern Sotho", "nativeName": "Sesotho"},
    "es": {"name": "Spanish; Castilian", "nativeName": "español, castellano"},
    "es_US": {"name": "Spanish (US)", "nativeName": "español (Estados Unidos)"},
    "su": {"name": "Sundanese", "nativeName": "Basa Sunda"},
    "sw": {"name": "Swahili", "nativeName": "Kiswahili"},
    "ss": {"name": "Swati", "nativeName": "SiSwati"},
    "sv": {"name": "Swedish", "nativeName": "svenska"},
    "ta": {"name": "Tamil", "nativeName": "தமிழ்"},
    "te": {"name": "Telugu", "nativeName": "తెలుగు"},
    "tg": {"name": "Tajik", "nativeName": "тоҷикӣ, toğikī, تاجیکی‎"},
    "th": {"name": "Thai", "nativeName": "ไทย"},
    "ti": {"name": "Tigrinya", "nativeName": "ትግርኛ"},
    "bo": {
      "name": "Tibetan Standard, Tibetan, Central",
      "nativeName": "བོད་ཡིག"
    },
    "tk": {"name": "Turkmen", "nativeName": "Türkmen, Түркмен"},
    "tl": {"name": "Tagalog", "nativeName": "Wikang Tagalog, ᜏᜒᜃᜅ᜔ ᜆᜄᜎᜓᜄ᜔"},
    "tn": {"name": "Tswana", "nativeName": "Setswana"},
    "to": {"name": "Tonga (Tonga Islands)", "nativeName": "faka Tonga"},
    "tr": {"name": "Turkish", "nativeName": "Türkçe"},
    "ts": {"name": "Tsonga", "nativeName": "Xitsonga"},
    "tt": {"name": "Tatar", "nativeName": "татарча, tatarça, تاتارچا‎"},
    "tw": {"name": "Twi", "nativeName": "Twi"},
    "ty": {"name": "Tahitian", "nativeName": "Reo Tahiti"},
    "ug": {"name": "Uighur, Uyghur", "nativeName": "Uyƣurqə, ئۇيغۇرچە‎"},
    "uk": {"name": "Ukrainian", "nativeName": "українська"},
    "ur": {"name": "Urdu", "nativeName": "اردو"},
    "uz": {"name": "Uzbek", "nativeName": "zbek, Ўзбек, أۇزبېك‎"},
    "ve": {"name": "Venda", "nativeName": "Tshivenḓa"},
    "vi": {"name": "Vietnamese", "nativeName": "Tiếng Việt"},
    "vo": {"name": "Volapük", "nativeName": "Volapük"},
    "wa": {"name": "Walloon", "nativeName": "Walon"},
    "cy": {"name": "Welsh", "nativeName": "Cymraeg"},
    "wo": {"name": "Wolof", "nativeName": "Wollof"},
    "fy": {"name": "Western Frisian", "nativeName": "Frysk"},
    "xh": {"name": "Xhosa", "nativeName": "isiXhosa"},
    "yi": {"name": "Yiddish", "nativeName": "ייִדיש"},
    "yo": {"name": "Yoruba", "nativeName": "Yorùbá"},
    "za": {"name": "Zhuang, Chuang", "nativeName": "Saɯ cueŋƅ, Saw cuengh"}
  };
  // Locales
  Map<String, String> localesMap(BuildContext context, String? languageCode) {
    // map the AppLocalizations.supportedLocales with a Map of the Locale name and the Locale code
    Map<String, String> locales = {};
    // add the locales to the map
    for (var locale in AppLocalizations.supportedLocales) {
      locales.addAll({
        locale.toString():
            // get the language name (ex. English) from isoLangs map
            isoLangs[locale.toString()]!['name'].toString() == locale.toString()
                ? isoLangs[locale.toString()]!['nativeName'] ??
                    locale.toString()
                : isoLangs[locale.toString()]!['name'] ?? locale.toString()
      });
      // remove the entry that has en_pirate as the key
      if (locale.toString() == 'en_pirate' || locale.toString() == 'zh_CHT') {
        locales.remove(locale.toString());
      }
    }

    // add a default value

    logger.d(locales);
    return locales;
  }

  // language settings Widget
  Future<Widget> languageSettings(BuildContext context) async => SettingsItem(
        // settingKey: 'language',
        title: AppLocalizations.of(context)?.language ?? 'Language',
        selected:
            AppLocalizations.of(context)?.localeName.toString() ?? 'System',
        backgroundColor: Theme.of(context).splashColor,
        icon: Icons.language,
        values:
            localesMap(context, prefs?.getString('localeString') ?? 'System'),
        onChange: (value) async {
          logger.d(value);
          // change the locale
          final localeProvider =
              Provider.of<LocaleChangeNotifier>(context, listen: false);
          localeProvider.setLocale = value.toString();
          prefs?.setString('localeString', value.toString());

          setState(() {});
        },
      );

  // page transition settings
  Future<Widget> pageTransitionSettings() async => SettingsItem(
        // settingKey: 'pageTransition',
        title:
            AppLocalizations.of(context)?.pageTransition ?? 'Page Transition',
        selected: prefs?.getString('pageTransition') ?? 'Page Turn',
        backgroundColor: Theme.of(context).splashColor,
        icon: Icons.pageview,
        values: const <String, String>{
          'Page Turn': 'Page Turn',
          'Slide': 'Slide',
        },
        onChange: (value) async {
          SharedPreferences prefs = await SharedPreferences.getInstance();
          prefs.setString('pageTransition', value.toString());
        },
      );

}
