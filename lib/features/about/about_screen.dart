import 'package:flutter/material.dart';

import '../../core/edition.dart';
import '../../core/l10n.dart';
import '../../core/theme/easy_theme.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(t.about)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Center(child: RainbowStripes(height: 40)),
          const SizedBox(height: 16),
          _Section(
            title: '${Edition.appName} v1.0',
            body: '${t.aboutDescription}\n\n${t.developedBy}\nsoporte@easysoft.cl',
          ),
          _Section(
            title: t.engineTitle,
            body: 'Clock Signal (CLK) — Thomas Harte\n'
                '${t.licenseMit}\n'
                'github.com/TomHarte/CLK\n\n'
                '${t.engineBody}',
          ),
          _Section(title: t.romsTitle, body: t.romsBody),
          _Section(
            title: t.formatsTitle,
            body: '${t.formatTapes}: .tap .tzx .csw\n'
                'Snapshots: .z80 .sna .szx\n'
                'ZX Spectrum Next: .nex\n'
                '${t.formatDisks}: .dsk\n'
                '${t.formatZip}',
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
