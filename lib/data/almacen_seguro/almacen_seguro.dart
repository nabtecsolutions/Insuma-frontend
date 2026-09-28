/// Contrato del almacenamiento de SECRETOS locales (HU-036).
///
/// Existe para que ningún servicio importe `flutter_secure_storage` directo: la
/// lógica depende de esta interfaz y las implementaciones deciden el backend por
/// plataforma (Keystore/Keychain en nativo, SharedPreferences en web — donde la
/// implementación del paquete es experimental y sin hardware que respalde la
/// llave, así que no aportaría seguridad real).
///
/// Es string-only a propósito (KISS): los booleanos se serializan como
/// 'true'/'false'. Nunca lanza por una lectura fallida: un almacén corrupto
/// (p. ej. clave del Keystore invalidada tras un restore) devuelve `null` y la
/// app degrada a "sin sesión" → re-login, en vez de crashear al arrancar.
abstract class AlmacenSeguro {
  const AlmacenSeguro();

  /// Valor de [clave], o `null` si no existe (o si el almacén no pudo leerlo).
  Future<String?> leer(String clave);

  Future<void> escribir(String clave, String valor);

  Future<void> borrar(String clave);

  /// Borra varias claves. Útil en el logout, que limpia el juego completo.
  Future<void> borrarClaves(Iterable<String> claves);
}
