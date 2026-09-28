import 'package:flutter/material.dart';
import 'core/edition.dart';
import 'core/l10n.dart';
import 'core/theme/easy_theme.dart';
import 'features/home/home_screen.dart';

class EasySpectrumApp extends StatelessWidget {
  const EasySpectrumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Edition.appName,
      theme: EasyTheme.theme,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      // El primero (en) es el idioma de reserva para locales no soportados.
      supportedLocales: AppLocalizations.supportedLocales,
      home: const HomeScreen(),
    );
  }
}
