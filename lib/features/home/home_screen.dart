import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../core/ads/ad_manager.dart';
import '../../core/storage/game_library.dart';
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
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    } catch (e) {
      _snack('No se pudo abrir el selector: $e');
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;

    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) {
      _snack('No se pudo leer el archivo.');
      return;
    }

    try {
      final path = await GameLibrary.import(file.name, bytes);
      await _play(path: path);
    } on FormatException catch (e) {
      _snack('${e.message}. Usa .tap, .tzx, .z80, .sna, .szx, .dsk o .zip');
    } catch (e) {
      _snack('Error al importar: $e');
    }
  }

  Future<void> _deleteGame(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar juego'),
        content: Text('¿Quitar "${GameLibrary.titleOf(f.path)}" de la lista?',
            style: const TextStyle(fontSize: 18)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok == true) {
      try {
        await f.delete();
      } catch (_) {}
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Easy Spectrum'),
            SizedBox(width: 12),
            RainbowStripes(height: 22),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_rounded, size: 30),
            tooltip: 'Ajustes',
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
                  label: 'Cargar juego',
                  color: ZxColors.cyan,
                  onTap: _pickGame,
                ),
                const SizedBox(height: 14),
                _BigButton(
                  icon: Icons.keyboard_rounded,
                  label: 'Encender (BASIC)',
                  color: ZxColors.yellow,
                  onTap: () => _play(),
                ),
                const SizedBox(height: 28),
                if (_games.isNotEmpty) ...[
                  const Text('Mis juegos',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  for (final g in _games)
                    Card(
                      color: ZxColors.bodyLight,
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      child: ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        leading: const Icon(Icons.videogame_asset_rounded,
                            size: 36, color: ZxColors.green),
                        title: Text(GameLibrary.titleOf(g.path),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(GameLibrary.extensionOf(g.path).toUpperCase()),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, size: 28),
                          tooltip: 'Borrar',
                          onPressed: () => _deleteGame(g),
                        ),
                        onTap: () => _play(path: g.path),
                      ),
                    ),
                ] else
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Carga un juego (.tap, .tzx, .z80, .sna, .dsk o .zip) '
                      'y aparecerá aquí para jugarlo con un toque.',
                      style: TextStyle(fontSize: 18, color: ZxColors.textDim),
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
