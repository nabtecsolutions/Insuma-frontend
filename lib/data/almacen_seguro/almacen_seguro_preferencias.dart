import 'package:shared_preferences/shared_preferences.dart';

import 'almacen_seguro.dart';

/// [AlmacenSeguro] respaldado por SharedPreferences (HU-036).
///
/// Se usa en WEB: la implementación web de `flutter_secure_storage` es
/// experimental ("use at your own risk") y su beneficio es marginal —cifra con
/// WebCrypto sobre localStorage, pero sin hardware y cualquier script del mismo
/// origen (XSS) puede invocar las mismas APIs y leer igual—. En web la sesión se
/// protege con HTTPS + higiene anti-XSS + rotación de tokens de Supabase y la
/// RLS, no con este paquete. Mantiene el comportamiento actual de la app.
class AlmacenSeguroPreferencias extends AlmacenSeguro {
  const AlmacenSeguroPreferencias();

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<String?> leer(String clave) async => (await _prefs).getString(clave);

  @override
  Future<void> escribir(String clave, String valor) async =>
      (await _prefs).setString(clave, valor);

  @override
  Future<void> borrar(String clave) async => (await _prefs).remove(clave);

  @override
  Future<void> borrarClaves(Iterable<String> claves) async {
    final prefs = await _prefs;
    for (final clave in claves) {
      await prefs.remove(clave);
    }
  }
}
