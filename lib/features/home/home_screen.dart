import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../core/ads/ad_manager.dart';
import '../../core/edition.dart';
import '../../core/l10n.dart';
import '../../core/storage/game_library.dart';
import '../../core/storage/game_thumbnail.dart';
import '../../core/theme/easy_theme.dart';
import '../game/game_screen.dart';
import '../settings/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  BannerAd? _banner;
  bool _bannerReady = false;
  List<File> _games = [];

  @override
  void initState() {
    super.initState();
    _banner = AdManager.instance.createBanner(
      onLoaded: () => setState(() => _bannerReady = true),
    );
    AdManager.instance.preloadInterstitial();
    _refresh();
  }

  @override
  void dispose() {
    _banner?.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final games = await GameLibrary.list();
    if (mounted) setState(() => _games = games);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg, style: const TextStyle(fontSize: 18))),
    );
  }

  Future<void> _play({String path = ''}) async {
    if (path.isNotEmpty) await GameLibrary.touch(path);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GameScreen(mediaPath: path)),
    );
    _refresh();
  }

  Future<void> _pickGame() async {
    final t = context.l10n;
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    } catch (e) {
      _snack(t.pickerError('$e'));
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;

    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) {
      _snack(t.readFileError);
      return;
    }

    try {
      final path = await GameLibrary.import(file.name, bytes);
      await _play(path: path);
    } on GameImportException catch (e) {
      _snack(e.extension == null ? t.zipWithoutGame : t.unsupportedFormat(e.extension!));
    } catch (e) {
      _snack(t.importError('$e'));
    }
  }

  Future<void> _deleteGame(File f) async {
    final t = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.deleteGame),
        content: Text(t.deleteGameConfirm(GameLibrary.titleOf(f.path)),
            style: const TextStyle(fontSize: 18)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.delete)),
        ],
      ),
    );
    if (ok == true) {
      try {
        await f.delete();
        await GameThumbnail.forget(f.path);
      } catch (_) {}
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Easy Spectrum'),
            if (Edition.isPro) ...[
              SizedBox(width: 8),
              _ProBadge(),
            ],
            SizedBox(width: 12),
            RainbowStripes(height: 22),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_rounded, size: 30),
            tooltip: t.settings,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _BigButton(
                  icon: Icons.folder_open_rounded,
                  label: t.loadGame,
                  color: ZxColors.cyan,
                  onTap: _pickGame,
                ),
                const SizedBox(height: 14),
                _BigButton(
                  icon: Icons.keyboard_rounded,
                  label: t.powerOnBasic,
                  color: ZxColors.yellow,
                  onTap: () => _play(),
                ),
                const SizedBox(height: 28),
                if (_games.isNotEmpty) ...[
                  Text(t.myGames,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  for (final g in _games)
                    Card(
                      color: ZxColors.bodyLight,
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      child: ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        leading: _GameThumb(path: g.path),
                        title: Text(GameLibrary.titleOf(g.path),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(GameLibrary.extensionOf(g.path).toUpperCase()),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, size: 28),
                          tooltip: t.delete,
                          onPressed: () => _deleteGame(g),
                        ),
                        onTap: () => _play(path: g.path),
                      ),
                    ),
                ] else
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      t.emptyLibrary,
                      style: const TextStyle(fontSize: 18, color: ZxColors.textDim),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
          if (_bannerReady && _banner != null)
            SafeArea(
              top: false,
              child: SizedBox(height: 50, child: AdWidget(ad: _banner!)),
            ),
        ],
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _BigButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 72,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 32),
        label: Text(label, style: const TextStyle(fontSize: 22)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }
}

class _ProBadge extends StatelessWidget {
  const _ProBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: ZxColors.yellow,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text('PRO',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Colors.black)),
    );
  }
}

/// Miniatura 4:3 con la pantalla de carga o del snapshot; ícono genérico si el
/// formato no trae pantalla (.dsk, .csw) o mientras se genera.
class _GameThumb extends StatelessWidget {
  final String path;
  const _GameThumb({required this.path});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 80,
      height: 60,
      child: FutureBuilder<ui.Image?>(
        future: GameThumbnail.load(path),
        builder: (context, snap) {
          final image = snap.data;
          if (image == null) {
            return const Icon(Icons.videogame_asset_rounded, size: 40, color: ZxColors.green);
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
          );
        },
      ),
    );
  }
}
