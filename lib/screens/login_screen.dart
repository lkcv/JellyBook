// This Files purpose is to have a login screen where the user can login into the server
import 'package:flutter/material.dart';
import 'package:kurage/providers/login.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kurage/screens/home_screen.dart';

import 'package:kurage/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kurage/variables.dart';
import 'package:isar/isar.dart';
import 'package:kurage/models/login.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {

  final storage = FlutterSecureStorage();
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _passwordVisible = false;
  String _error = '';
  bool _isConnecting = false;
  SharedPreferences? prefs;

  @override
  void initState() {
    super.initState();
    setSharedPrefs();
    _passwordVisible = false;
    
    // Prefill fields from saved login if available
    _prefillFromSavedLogin();
  }

  Future<void> setSharedPrefs() async {
    prefs = await SharedPreferences.getInstance();
  }

  Future<void> _prefillFromSavedLogin() async {
    final isar = Isar.getInstance();
    final savedLogin = await isar?.logins.where().findFirst();
    
    if (savedLogin != null && mounted) {
      setState(() {
        _url.text = savedLogin.serverUrl;
        _username.text = savedLogin.username;
        // Don't prefill password for security
      });
    }
  }

  final FocusNode _focusNode1 = FocusNode();
  final FocusNode _focusNode2 = FocusNode();
  final FocusNode _focusNode3 = FocusNode();
  final FocusNode _focusNode4 = FocusNode();

  @override
  void dispose() {
    _focusNode1.dispose();
    _focusNode2.dispose();
    _focusNode3.dispose();
    _focusNode4.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_isConnecting) return;
    final address = _url.text.trim();
    final username = _username.text.trim();
    if (address.isEmpty || username.isEmpty) {
      setState(() {
        _error = address.isEmpty
            ? 'Enter your server address.'
            : 'Enter your username.';
      });
      return;
    }

    setState(() {
      _isConnecting = true;
      _error = '';
    });
    try {
      final result = await LoginProvider.loginStatic(
        address, username, context, _password.text,
      );
      if (!mounted) return;
      if (result == 'true') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HomeScreen()),
        );
      } else {
        setState(() => _error = result);
      }
    } catch (e) {
      logger.e('Unexpected login screen failure (${e.runtimeType})');
      if (!mounted) return;
      setState(() => _error = 'Could not sign in. Please try again.');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Form(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                "クラゲ",
                style: TextStyle(
                  fontSize: 50,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(
                height: 50,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(25, 8, 25, 8),
                child: TextFormField(
                  key: const Key('urlField'),
                  controller: _url,
                  focusNode: _focusNode1,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context)?.pageLoginAddress ??
                        "Your Address",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(
                height: 5,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(25, 8, 25, 8),
                child: TextFormField(
                  key: const Key('usernameField'),
                  controller: _username,
                  focusNode: _focusNode2,
                  autofillHints: const [],
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText:
                        AppLocalizations.of(context)?.pageLoginUsername ??
                            "Username",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(
                height: 5,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(25, 8, 25, 8),
                child: TextFormField(
                  key: const Key('passwordField'),
                  controller: _password,
                  focusNode: _focusNode3,
                  obscureText: !_passwordVisible,
                  decoration: InputDecoration(
                    labelText:
                        AppLocalizations.of(context)?.pageLoginPassword ??
                            "Password",
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _passwordVisible
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                      onPressed: () {
                        setState(() {
                          _passwordVisible = !_passwordVisible;
                        });
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(
                height: 10,
              ),
              SizedBox(
                width: MediaQuery.of(context).size.width - 50,
                height: 50,
                child: ElevatedButton(
                  key: const Key('connectButton'),
                  focusNode: _focusNode4,
                  onPressed: _isConnecting ? null : _connect,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.login),
                      const SizedBox(
                        width: 10,
                      ),
                      Text(AppLocalizations.of(context)?.connect ?? "Connect",
                          style: const TextStyle(fontSize: 20)),
                    ],
                  ),
                ),
              ),
              const SizedBox(
                height: 15,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(25, 8, 25, 8),
                child: Text(
                  _error,
                  style: const TextStyle(
                    color: Colors.red,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
