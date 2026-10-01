import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/easy_theme.dart';

/// Una entrada de la barra de herramientas. [onTap] null = deshabilitada (aún sin
/// implementar o sin sentido ahora); [active] la resalta (un interruptor encendido).
class ToolItem {
  final String asset;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  const ToolItem(this.asset, this.tooltip, {this.onTap, this.active = false});
}

/// Barra de herramientas de la versión de escritorio. Los iconos son los de la barra de
/// PRISMA GUI (UIcons Regular Rounded, de Freepik/Flaticon, CC BY 4.0), tintados en blanco.
/// Una entrada `null` es un separador de grupos.
class DesktopToolbar extends StatelessWidget {
  static const height = 40.0;
  final List<ToolItem?> items;
  const DesktopToolbar({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        color: Color(0xFF111214),
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          for (final it in items)
            if (it == null)
              Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 8), color: Colors.white24)
            else
              _ToolButton(it),
        ],
      ),
    );
  }
}

class _ToolButton extends StatefulWidget {
  final ToolItem item;
  const _ToolButton(this.item);

  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final enabled = it.onTap != null;
    final colour = !enabled ? Colors.white30 : (it.active ? ZxColors.cyan : Colors.white);
    return Tooltip(
      message: it.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: it.onTap,
          child: Container(
            width: 36,
            height: 32,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: _hover && enabled ? Colors.white.withValues(alpha: 0.12) : Colors.transparent,
              border: it.active ? Border.all(color: ZxColors.cyan.withValues(alpha: 0.6)) : null,
            ),
            alignment: Alignment.center,
            child: SvgPicture.asset(
              'assets/toolbar/${it.asset}.svg',
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(colour, BlendMode.srcIn),
            ),
          ),
        ),
      ),
    );
  }
}
