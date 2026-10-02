import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../edition.dart';

/// Anuncios de la edición gratuita. En la Pro ([Edition.showAds] = false) todo es
/// no-op: no se inicializa AdMob ni se pide ningún anuncio.
class AdManager {
  AdManager._();
  static final AdManager instance = AdManager._();

  // En debug siempre IDs de prueba (clics propios = tráfico inválido en AdMob).
  static String get _bannerId => kDebugMode || !Platform.isAndroid
      ? (Platform.isAndroid
          ? 'ca-app-pub-3940256099942544/6300978111'
          : 'ca-app-pub-3940256099942544/2934735716')
      : 'ca-app-pub-4383534162647782/2568261422';

  static String get _interstitialId => kDebugMode || !Platform.isAndroid
      ? (Platform.isAndroid
          ? 'ca-app-pub-3940256099942544/1033173712'
          : 'ca-app-pub-3940256099942544/4411468910')
      : 'ca-app-pub-4383534162647782/5449400629';

  BannerAd? _banner;
  InterstitialAd? _interstitial;

  Future<void> initialize() async {
    if (!Edition.showAds) return;
    await _gatherConsent();
    if (await ConsentInformation.instance.canRequestAds()) {
      await MobileAds.instance.initialize();
    }
  }

  /// Consentimiento UMP (EEE/Reino Unido/Suiza): formulario solo si hace falta.
  Future<void> _gatherConsent() async {
    final done = Completer<void>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () async {
        await ConsentForm.loadAndShowConsentFormIfRequired((_) {});
        done.complete();
      },
      (_) => done.complete(),
    );
    await done.future;
  }

  /// ¿Hay que ofrecer "Privacidad y anuncios" en Ajustes?
  Future<bool> privacyOptionsRequired() async {
    if (!Edition.showAds) return false;
    return await ConsentInformation.instance.getPrivacyOptionsRequirementStatus() ==
        PrivacyOptionsRequirementStatus.required;
  }

  Future<void> showPrivacyOptions() => ConsentForm.showPrivacyOptionsForm((_) {});

  /// null en la Pro.
  BannerAd? createBanner({VoidCallback? onLoaded}) {
    if (!Edition.showAds) return null;
    _banner?.dispose();
    _banner = BannerAd(
      adUnitId: _bannerId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) => onLoaded?.call(),
        onAdFailedToLoad: (ad, _) => ad.dispose(),
      ),
    )..load();
    return _banner!;
  }

  Future<void> preloadInterstitial() async {
    if (!Edition.showAds) return;
    await InterstitialAd.load(
      adUnitId: _interstitialId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) => _interstitial = ad,
        onAdFailedToLoad: (_) => _interstitial = null,
      ),
    );
  }

  Future<void> showInterstitialThenDo(VoidCallback after) async {
    final ad = _interstitial;
    _interstitial = null;
    if (ad != null) {
      ad.fullScreenContentCallback = FullScreenContentCallback(
        onAdDismissedFullScreenContent: (_) {
          ad.dispose();
          after();
          preloadInterstitial();
        },
        onAdFailedToShowFullScreenContent: (_, __) {
          ad.dispose();
          after();
        },
      );
      await ad.show();
    } else {
      after();
    }
  }

  void dispose() {
    _banner?.dispose();
    _interstitial?.dispose();
    _banner = null;
    _interstitial = null;
  }
}
