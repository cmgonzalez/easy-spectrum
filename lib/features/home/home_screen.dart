import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../core/ads/ad_manager.dart';
import '../../core/edition.dart';
import '../../core/l10n.dart';
import '../../core/settings.dart';
import '../../core/storage/game_info.dart';
import '../../core/storage/game_library.dart';
import '../../core/storage/game_thumbnail.dart';
import '../../core/storage/incoming_files.dart';
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
    IncomingFiles.listen(_openIncoming);
  }

  /// Archivo abierto desde otra app: se importa y se juega. Si había un juego (u
  /// otra pantalla) abierto, se vuelve al inicio y se espera a que se libere.
  Future<void> _openIncoming(IncomingFile file) async {
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    await GameScreen.whenClosed();
    if (!mounted) return;
    if (file.bytes == null) {
      _snack(context.l10n.readFileError);
      return;
    }
    await _importAndPlay(file.name, file.bytes!);
  }

  @override
  void dispose() {
    _banner?.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    GameInfoService.enabled = (await AppSettings.load()).onlineInfo;
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

    await _importAndPlay(file.name, bytes);
  }

  Future<void> _importAndPlay(String name, Uint8List bytes) async {
    final t = context.l10n;
    try {
      final path = await GameLibrary.import(name, bytes);
      GameThumbnail.forget(path);
      GameInfoService.forget(path);
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
      await GameLibrary.delete(f.path);
      GameThumbnail.forget(f.path);
      GameInfoService.forget(f.path);
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
            ).then((_) => _refresh()),
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
                      child: _GameTile(
                        key: ValueKey(g.path),
                        path: g.path,
                        deleteTooltip: t.delete,
                        onDelete: () => _deleteGame(g),
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

/// Fila de "Mis juegos": pide la ficha a ZXDB (si está activado) y, cuando llega,
/// se redibuja con el título real, año · editor y la pantalla de carga.
class _GameTile extends StatefulWidget {
  final String path;
  final String deleteTooltip;
  final VoidCallback onDelete;
  final VoidCallback onTap;
  const _GameTile({
    super.key,
    required this.path,
    required this.deleteTooltip,
    required this.onDelete,
    required this.onTap,
  });

  @override
  State<_GameTile> createState() => _GameTileState();
}

class _GameTileState extends State<_GameTile> {
  GameInfo? _info;

  @override
  void initState() {
    super.initState();
    _info = GameInfoService.cached(widget.path);
    GameInfoService.load(widget.path).then((info) {
      if (mounted && info != _info) setState(() => _info = info);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ext = GameLibrary.extensionOf(widget.path).toUpperCase();
    final info = _info;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      // La clave cambia al llegar la ficha: vuelve a pedir la miniatura (puede
      // haber llegado la pantalla de carga de ZXDB).
      leading: _GameThumb(key: ValueKey(info?.id), path: widget.path),
      title: Text(info?.title ?? GameLibrary.titleOf(widget.path),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(info == null || info.subtitle.isEmpty ? ext : '${info.subtitle} · $ext',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline_rounded, size: 28),
        tooltip: widget.deleteTooltip,
        onPressed: widget.onDelete,
      ),
      onTap: widget.onTap,
    );
  }
}

/// Miniatura 4:3 con la pantalla de carga o del snapshot; ícono genérico si el
/// formato no trae pantalla (.dsk, .csw) o mientras se genera.
class _GameThumb extends StatelessWidget {
  final String path;
  const _GameThumb({super.key, required this.path});

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
