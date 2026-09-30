import 'dart:io';

import 'package:flutter/material.dart';
import 'app.dart';
import 'core/ads/ad_manager.dart';
import 'features/desktop/desktop_app.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Escritorio: solo la ventana del emulador con barra de menús (args = archivo a abrir).
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await DesktopApp.init();
    runApp(DesktopApp(args: args));
    return;
  }
  await AdManager.instance.initialize();
  runApp(const EasySpectrumApp());
}
