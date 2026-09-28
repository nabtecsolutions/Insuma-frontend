import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'almacen_seguro.dart';

/// [AlmacenSeguro] respaldado por hardware (HU-036): Android Keystore (la llave
/// AES vive en el TEE/StrongBox y nunca sale del chip) e iOS Keychain.
///
/// Opciones elegidas y por qué:
///  • `resetOnError: true` — es el DEFAULT de v10 y se deja EXPLÍCITO para que
///    quede documentado: ante un error de descifrado (Keystore invalidado, OS
///    update, restore parcial) el plugin PURGA el almacén y devuelve null en vez
///    de lanzar. Para tokens/sesión es el comportamiento correcto: el usuario
///    re-loguea, no hay crash-loop.
///  • `migrateWithBackup: true` — migración de formato resistente a crashes
///    (el paquete tiene historial de pérdida de datos en upgrades).
///  • NO se pasa `encryptedSharedPreferences`: quedó deprecado e IGNORADO en v10
///    (se elimina en v11); los datos escritos por v9 migran solos gracias a
///    `migrateOnAlgorithmChange`, que ya viene en true.
///  • iOS `first_unlock_this_device`: legible desde el primer desbloqueo tras el
///    boot (permite refrescar el token en background) y NO migra a otro
///    dispositivo por backup. El default del paquete es `unlocked`, así que hay
///    que pasarlo explícito.
class AlmacenSeguroSecureStorage extends AlmacenSeguro {
  final FlutterSecureStorage _storage;

  AlmacenSeguroSecureStorage([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              resetOnError: true,
              migrateWithBackup: true,
            ),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  @override
  Future<String?> leer(String clave) async {
    try {
      return await _storage.read(key: clave);
    } on PlatformException catch (e) {
      // Almacén ilegible (clave del Keystore perdida/invalidada). Se descarta la
      // entrada dañada y se degrada a "no hay valor" → la app pide login.
      debugPrint('[ALMACEN] Lectura fallida de "$clave": ${e.code}');
      await borrar(clave);
      return null;
    } catch (e) {
      debugPrint('[ALMACEN] Lectura fallida de "$clave": $e');
      return null;
    }
  }

  @override
  Future<void> escribir(String clave, String valor) async {
    try {
      await _storage.write(key: clave, value: valor);
    } catch (e) {
      // Una escritura fallida NO debe tumbar el login: la sesión sigue viva en
      // memoria durante esta ejecución; el usuario re-logueará en la próxima.
      debugPrint('[ALMACEN] Escritura fallida de "$clave": $e');
    }
  }

  @override
  Future<void> borrar(String clave) async {
    try {
      await _storage.delete(key: clave);
    } catch (e) {
      debugPrint('[ALMACEN] Borrado fallido de "$clave": $e');
    }
  }

  @override
  Future<void> borrarClaves(Iterable<String> claves) async {
    for (final clave in claves) {
      await borrar(clave);
    }
  }
}
