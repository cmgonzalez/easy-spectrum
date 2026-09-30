import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/edition.dart';
import '../../core/emulator/zx_types.dart';
import '../../core/l10n.dart';
import '../../core/theme/easy_theme.dart';
import 'desktop_screen.dart';

/// App de escritorio (Windows): una ventana con la salida del Spectrum y barra de menús.
///
/// Línea de comandos (pensada para lanzarla desde otras herramientas, p. ej. PRISMA):
///   easy_spectrum.exe [archivo] [--model 16k|48k|128k|+2|+2a|+3]
class DesktopApp extends StatelessWidget {
  final List<String> args;
  const DesktopApp({super.key, required this.args});

  static Future<void> init() async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      title: 'Easy Spectrum',
      size: Size(zxFbWidth * 3 + 16, zxFbHeight * 3 + 80),
      minimumSize: Size(zxFbWidth + 16, zxFbHeight + 80),
      center: true,
      backgroundColor: Colors.black,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  /// Archivo y modelo pasados por línea de comandos.
  static (String?, ZxModel?) parseArgs(List<String> args) {
    String? file;
    ZxModel? model;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '--model' && i + 1 < args.length) {
        final m = args[++i].toUpperCase();
        for (final v in ZxModel.values) {
          if (v.label == m) model = v;
        }
      } else if (!a.startsWith('--') && File(a).existsSync()) {
        file = File(a).absolute.path;
      }
    }
    return (file, model);
  }

  @override
  Widget build(BuildContext context) {
    final (file, model) = parseArgs(args);
    return MaterialApp(
      title: Edition.appName,
      theme: EasyTheme.theme,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DesktopScreen(initialFile: file, initialModel: model),
    );
  }
}
