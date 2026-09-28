import 'package:flutter/material.dart';

import '../../core/theme/easy_theme.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Acerca de')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: const [
          Center(child: RainbowStripes(height: 40)),
          SizedBox(height: 16),
          _Section(
            title: 'Easy Spectrum v1.0',
            body: 'Emulador de ZX Spectrum simple y accesible.\n\n'
                'Desarrollado por EasySoft SPA\nsoporte@easysoft.cl',
          ),
          _Section(
            title: 'Motor de emulación',
            body: 'Clock Signal (CLK) — Thomas Harte\n'
                'Licencia MIT\n'
                'github.com/TomHarte/CLK\n\n'
                'Emula con precisión de ciclo los modelos 16K, 48K, 128K, '
                '+2, +2A y +3, con sonido AY y carga de cintas y discos.',
          ),
          _Section(
            title: 'ROMs del Spectrum',
            body: 'Las ROMs del ZX Spectrum son copyright de Amstrad plc, '
                'que autoriza su distribución junto a emuladores. '
                'Amstrad no respalda ni da soporte a esta aplicación.',
          ),
          _Section(
            title: 'Formatos',
            body: 'Cintas: .tap .tzx .csw\n'
                'Snapshots: .z80 .sna .szx\n'
                'Discos +3: .dsk\n'
                'También dentro de archivos .zip',
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;
  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, color: ZxColors.cyan)),
          const SizedBox(height: 8),
          Text(body, style: const TextStyle(fontSize: 18, height: 1.4)),
        ],
      ),
    );
  }
}
