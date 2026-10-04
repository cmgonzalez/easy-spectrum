import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Lista de favoritos: rutas de juegos que el usuario quiere tener a mano en el menú
/// Favoritos. Solo guarda las rutas; los que ya no existen en disco se ocultan.
class Favorites {
  static const _key = 'favorites';

  static Future<List<String>> load() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_key) ?? []).where((e) => File(e).existsSync()).toList();
  }

  /// Añade [path] (sin duplicar) al final y devuelve la lista nueva.
  static Future<List<String>> add(String path) async {
    final p = await SharedPreferences.getInstance();
    final list = (p.getStringList(_key) ?? []).where((e) => e != path).toList()..add(path);
    await p.setStringList(_key, list);
    return load();
  }

  static Future<List<String>> remove(String path) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_key, (p.getStringList(_key) ?? []).where((e) => e != path).toList());
    return load();
  }
}
