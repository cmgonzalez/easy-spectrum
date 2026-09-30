import 'package:flutter/services.dart';

/// Elemento de la barra de menús nativa de Windows (windows/runner/native_menu.cpp).
/// En [label], "&" marca la letra de Alt; [shortcut] se muestra alineado a la derecha.
class MenuEntry {
  final String label;
  final String? shortcut;
  final VoidCallback? onSelected;
  final List<MenuEntry>? children;
  final bool checked;
  final bool radio;
  final bool enabled;
  final bool separator;

  const MenuEntry(
    this.label, {
    this.shortcut,
    this.onSelected,
    this.children,
    this.checked = false,
    this.radio = false,
    this.enabled = true,
  }) : separator = false;

  const MenuEntry.submenu(this.label, List<MenuEntry> this.children, {this.enabled = true})
      : shortcut = null,
        onSelected = null,
        checked = false,
        radio = false,
        separator = false;

  const MenuEntry.separator()
      : label = '',
        shortcut = null,
        onSelected = null,
        children = null,
        checked = false,
        radio = false,
        enabled = true,
        separator = true;
}

/// Barra de menús Win32 real: se abre y recorre como la de cualquier programa de Windows
/// (hover entre menús, teclado, Alt + letra). Se describe entera en cada [set]; si no
/// cambió respecto de la anterior no se envía nada.
class NativeMenuBar {
  NativeMenuBar({this.onMenuLoop}) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'select':
          _actions[call.arguments as int]?.call();
        case 'menuLoop':
          onMenuLoop?.call(call.arguments as bool);
      }
    });
  }

  static const _channel = MethodChannel('cl.easysoft.easyspectrum/menu');

  /// El usuario abrió (true) o cerró (false) un menú.
  final void Function(bool open)? onMenuLoop;

  final Map<int, VoidCallback> _actions = {};
  Object? _last;
  bool? _visible;

  void set(List<MenuEntry> menus) {
    final actions = <int, VoidCallback>{};
    final encoded = menus.map((m) => _encode(m, actions)).toList();
    _actions
      ..clear()
      ..addAll(actions);
    if (_same(encoded, _last)) return;
    _last = encoded;
    _channel.invokeMethod('setMenu', encoded);
  }

  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    _channel.invokeMethod('setVisible', visible);
  }

  Map<String, Object?> _encode(MenuEntry e, Map<int, VoidCallback> actions) {
    if (e.separator) return {'separator': true};
    int? id;
    if (e.onSelected != null) {
      id = actions.length + 1;
      actions[id] = e.onSelected!;
    }
    return {
      'label': e.shortcut == null ? e.label : '${e.label}\t${e.shortcut}',
      'id': id,
      'enabled': e.enabled && (e.children != null || e.onSelected != null),
      'checked': e.checked,
      'radio': e.radio,
      'children': e.children?.map((c) => _encode(c, actions)).toList(),
    };
  }

  static bool _same(Object? a, Object? b) {
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_same(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!_same(a[k], b[k])) return false;
      }
      return true;
    }
    return a == b;
  }
}
