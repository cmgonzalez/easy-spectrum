import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

class AdManager {
  AdManager._();
  static final AdManager instance = AdManager._();

  // TODO: reemplazar con IDs reales antes de publicar
  static String get _bannerId => Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/6300978111'
      : 'ca-app-pub-3940256099942544/2934735716';

  static String get _interstitialId => Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/1033173712'
      : 'ca-app-pub-3940256099942544/4411468910';

  BannerAd? _banner;
  InterstitialAd? _interstitial;

  BannerAd createBanner({VoidCallback? onLoaded}) {
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
