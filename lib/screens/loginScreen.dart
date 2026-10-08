// This Files purpose is to have a login screen where the user can login into the server
import 'package:flutter/material.dart';
import 'package:jellybook/providers/login.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jellybook/providers/themeProvider.dart';
import 'package:jellybook/screens/homeScreen.dart';
import 'package:jellybook/providers/languageProvider.dart';

import 'package:jellybook/l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jellybook/variables.dart';
import 'package:isar/isar.dart';
import 'package:jellybook/models/login.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen();

  @override
  _LoginScreenState createState() => _LoginScreenState(
        url: null,
        username: null,
        password: null,
      );
}

class _LoginScreenState extends State<LoginScreen> {
  final String? url;
  final String? username;
  final String? password;
  _LoginScreenState({
    required this.url,
    required this.username,
    required this.password,
  });

  final storage = FlutterSecureStorage();
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _passwordVisible = false;
  bool _loading = false;
  String _error = '';
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

  FocusNode _focusNode1 = FocusNode();
  FocusNode _focusNode2 = FocusNode();
  FocusNode _focusNode3 = FocusNode();
  FocusNode _focusNode4 = FocusNode();

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Form(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                "JellyBook",
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
                  onPressed: () async {
                    setState(() {
                      _loading = true;
                    });
                    logger.d("username: " + _username.text);
                    LoginProvider.loginStatic(
                      _url.text,
                      _username.text,
                      context,
                      _password.text,
                    ).then((value) {
                      if (value == "true") {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (context) => HomeScreen(),
                          ),
                        );
                      } else {
                        setState(() {
                          _error = value;
                          _loading = false;
                        });
                      }
                    });
                  },
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
