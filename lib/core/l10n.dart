import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';
import 'emulator/zx_types.dart';

export '../l10n/app_localizations.dart';

extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

String ulaplusModeLabel(AppLocalizations t, UlaplusMode m) => switch (m) {
      UlaplusMode.off => t.ulaplusOff,
      UlaplusMode.palette => t.ulaplusPalette,
      UlaplusMode.extended => t.ulaplusExtended,
    };

/// Traduce el código de error de zx_last_error() (ver native/zx_bridge.h).
String zxErrorText(AppLocalizations t, String code) => switch (code) {
      'missing_roms' => t.errMissingRoms,
      'bad_snapshot' => t.errBadSnapshot,
      'cpc_snapshot' => t.errCpcSnapshot,
      'unsupported_format' => t.errUnsupportedFormat,
      'machine_failed' => t.errMachineFailed,
      'open_failed' => t.errOpenFailed,
      'bad_nex' => t.errBadNex,
      'snapshot_unsupported' => t.errSnapshotUnsupported,
      'snapshot_failed' => t.errSnapshotFailed,
      'write_failed' => t.errWriteFailed,
      _ => code,
    };
