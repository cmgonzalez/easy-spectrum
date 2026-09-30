import 'dart:io';

import 'package:flutter/services.dart';

/// Edición de la app según el flavor de Android con que se compiló
/// (`flutter build ... --flavor free|pro`). Flutter expone el nombre en [appFlavor].
class Edition {
  static const bool isPro = appFlavor == 'pro';

  /// Sin anuncios en la Pro ni en escritorio (AdMob solo existe en Android/iOS).
  static bool get showAds => !isPro && (Platform.isAndroid || Platform.isIOS);

  static String get appName => isPro ? 'Easy Spectrum Pro' : 'Easy Spectrum';
}
