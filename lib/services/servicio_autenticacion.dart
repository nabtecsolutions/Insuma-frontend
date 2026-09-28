import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show compute, debugPrint, kDebugMode, kIsWeb, visibleForTesting;

/// Servicio de autenticación local: hashing de credenciales para la operación
/// offline-first. Nunca se persiste la contraseña ni el PIN en texto plano
/// (HU-001 / HU-002). El backend de identidad de referencia es Supabase Auth;
/// este hash cubre el modo offline cuando no hay conexión.
///
/// HU-112: el hash pasó de **SHA-256 de 1 ronda** (sin costo, vulnerable a fuerza
/// bruta si se filtra la base local) a **PBKDF2-HMAC-SHA256** con un factor de
/// trabajo configurable y sal aleatoria por hash. El formato es AUTODESCRIPTIVO y
/// VERSIONADO:
///
///   `pbkdf2$<iteraciones>$<sal_base64>$<derivado_base64>`
///
/// Un hash sin ese prefijo es un **legacy** (SHA-256 de 1 ronda): se sigue
/// aceptando para no expulsar a nadie, y en el primer login exitoso se re-hashea a
/// PBKDF2 (rehash-on-login, en `ServicioAcceso`), de modo que el esquema viejo
/// desaparece solo a medida que la gente entra.
class ServicioAutenticacion {
  /// Pimienta del esquema legacy (SHA-256). Se conserva SÓLO para poder verificar
  /// los hashes viejos; los nuevos ya no la usan.
  static const String _pimienta = 'insuma::v1';

  /// Factor de trabajo de PBKDF2. Configurable: subirlo encarece el ataque por
  /// fuerza bruta (y el login) de forma proporcional. Se guarda EN el hash, así
  /// que subirlo no invalida los hashes ya emitidos (se re-derivan con su propio
  /// número al verificar; el rehash-on-login los sube al entrar).
  static const int _iteraciones = 120000;

  /// Longitud del derivado en bytes (32 = una salida de SHA-256, un solo bloque
  /// PBKDF2).
  static const int _longitudDerivado = 32;

  /// Tope de iteraciones al VERIFICAR: un hash adulterado en la base local con un
  /// número enorme colgaría el login (DoS). Muy por encima de cualquier valor que
  /// emitamos, así que no rechaza hashes legítimos.
  static const int _maxIteraciones = 1000000;

  static final Random _rng = Random.secure();

  /// Genera el hash PBKDF2 de una contraseña, con sal aleatoria. [salt] (el email)
  /// se mantiene por compatibilidad de firma y se usa sólo en la verificación de
  /// hashes legacy; los PBKDF2 llevan su propia sal aleatoria embebida.
  static String hashearPassword(String password, {String salt = ''}) {
    final sal = Uint8List.fromList(
      List<int>.generate(16, (_) => _rng.nextInt(256)),
    );
    final derivado = _pbkdf2(password, sal, _iteraciones);
    return 'pbkdf2\$$_iteraciones\$${base64.encode(sal)}\$${base64.encode(derivado)}';
  }

  /// Verifica una contraseña contra su hash almacenado (PBKDF2 o legacy SHA-256).
  static bool verificarPassword(
    String password,
    String? hashAlmacenado, {
    String salt = '',
  }) {
    if (hashAlmacenado == null || hashAlmacenado.isEmpty) return false;

    if (hashAlmacenado.startsWith('pbkdf2\$')) {
      final partes = hashAlmacenado.split('\$');
      if (partes.length != 4) return false;
      final iteraciones = int.tryParse(partes[1]);
      if (iteraciones == null ||
          iteraciones <= 0 ||
          iteraciones > _maxIteraciones) {
        return false;
      }
      final Uint8List sal;
      final Uint8List esperado;
      try {
        sal = base64.decode(partes[2]);
        esperado = base64.decode(partes[3]);
      } on FormatException {
        return false;
      }
      final derivado = _pbkdf2(password, sal, iteraciones);
      return _igualesEnTiempoConstante(derivado, esperado);
    }

    // Legacy: SHA-256 de 1 ronda (pre-HU-112). Comparación directa; si coincide, el
    // llamador debería re-hashear (ver `esLegacy` + rehash-on-login en ServicioAcceso).
    final legacy = sha256
        .convert(utf8.encode('$_pimienta::$salt::$password'))
        .toString();
    return _igualesEnTiempoConstante(
      legacy.codeUnits,
      hashAlmacenado.codeUnits,
    );
  }

  /// `true` si el hash está en el esquema viejo (SHA-256 de 1 ronda) y conviene
  /// re-hashearlo a PBKDF2 tras un login exitoso.
  static bool esLegacy(String? hashAlmacenado) =>
      hashAlmacenado != null &&
      hashAlmacenado.isNotEmpty &&
      !hashAlmacenado.startsWith('pbkdf2\$');

  // ─── Variantes que NO bloquean la UI (HU-133 / HU-136) ─────────────────────
  //
  // Las 120k iteraciones de PBKDF2 en Dart puro cuestan ~0,5 s en desktop y
  // varios segundos en un teléfono. Ejecutadas en el isolate de UI bloquean el
  // event loop y CONGELAN la animación del spinner de login. En NATIVO estas
  // variantes derivan en un isolate aparte vía [compute]; en WEB no existen los
  // isolates (compute degrada a ejecución directa), así que se usa el camino
  // COOPERATIVO: el mismo bucle troceado en tandas que ceden el event loop, para
  // que la UI siga pintando frames (HU-136). Las síncronas quedan para tests y
  // helpers fríos.

  /// [hashearPassword] sin bloquear la UI (isolate en nativo, cooperativo en web).
  static Future<String> hashearPasswordAsync(
    String password, {
    String salt = '',
  }) {
    _avisarSiWebDebug();
    if (kIsWeb) return hashearPasswordCooperativo(password, salt: salt);
    return compute(_hashearMensaje, (password: password, salt: salt));
  }

  static String _hashearMensaje(({String password, String salt}) m) =>
      hashearPassword(m.password, salt: m.salt);

  /// [verificarPassword] sin bloquear la UI (isolate en nativo, cooperativo en web).
  static Future<bool> verificarPasswordAsync(
    String password,
    String? hashAlmacenado, {
    String salt = '',
  }) {
    // HU-136: cortocircuito — sin hash el resultado es constante `false`; no se
    // paga ni el spawn del isolate ni una pasada de KDF.
    if (hashAlmacenado == null || hashAlmacenado.isEmpty) {
      return Future.value(false);
    }
    _avisarSiWebDebug();
    if (kIsWeb) {
      return verificarPasswordCooperativo(password, hashAlmacenado, salt: salt);
    }
    return compute(_verificarMensaje, (
      password: password,
      hash: hashAlmacenado,
      salt: salt,
    ));
  }

  static bool _verificarMensaje(
    ({String password, String? hash, String salt}) m,
  ) => verificarPassword(m.password, m.hash, salt: m.salt);

  // ─── Camino COOPERATIVO para web (HU-136) ──────────────────────────────────

  /// [hashearPassword] con el KDF troceado en tandas que ceden el event loop.
  /// Mismo resultado bit a bit que la variante síncrona (lo fija un test).
  /// Público con @visibleForTesting: en la VM de tests `kIsWeb` es false y el
  /// camino no se ejercitaría.
  @visibleForTesting
  static Future<String> hashearPasswordCooperativo(
    String password, {
    String salt = '',
  }) async {
    final sal = Uint8List.fromList(
      List<int>.generate(16, (_) => _rng.nextInt(256)),
    );
    final derivado = await _pbkdf2Cooperativo(password, sal, _iteraciones);
    return 'pbkdf2\$$_iteraciones\$${base64.encode(sal)}\$${base64.encode(derivado)}';
  }

  /// [verificarPassword] cooperativo. El camino legacy (SHA-256 de 1 ronda) es
  /// barato y se delega a la variante síncrona.
  @visibleForTesting
  static Future<bool> verificarPasswordCooperativo(
    String password,
    String hashAlmacenado, {
    String salt = '',
  }) async {
    if (!hashAlmacenado.startsWith('pbkdf2\$')) {
      return verificarPassword(password, hashAlmacenado, salt: salt);
    }
    final partes = hashAlmacenado.split('\$');
    if (partes.length != 4) return false;
    final iteraciones = int.tryParse(partes[1]);
    if (iteraciones == null ||
        iteraciones <= 0 ||
        iteraciones > _maxIteraciones) {
      return false;
    }
    final Uint8List sal;
    final Uint8List esperado;
    try {
      sal = base64.decode(partes[2]);
      esperado = base64.decode(partes[3]);
    } on FormatException {
      return false;
    }
    final derivado = await _pbkdf2Cooperativo(password, sal, iteraciones);
    return _igualesEnTiempoConstante(derivado, esperado);
  }

  /// Iteraciones por tanda del camino cooperativo: ~2k mantiene cada bloqueo del
  /// hilo muy por debajo de un frame (16 ms) con overhead total marginal.
  static const int _iteracionesPorTanda = 2000;

  /// Réplica de [_pbkdf2] que cede el event loop entre tandas (HU-136). La
  /// matemática debe mantenerse IDÉNTICA a la síncrona: el test de equivalencia
  /// `cooperativo ≡ síncrono` protege contra divergencias.
  static Future<Uint8List> _pbkdf2Cooperativo(
    String password,
    Uint8List sal,
    int iteraciones,
  ) async {
    final hmac = Hmac(sha256, utf8.encode(password));
    final entrada = Uint8List(sal.length + 4)
      ..setRange(0, sal.length, sal)
      ..[sal.length + 3] = 1;
    var u = Uint8List.fromList(hmac.convert(entrada).bytes);
    final resultado = Uint8List.fromList(u);
    for (var i = 1; i < iteraciones; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var j = 0; j < resultado.length; j++) {
        resultado[j] ^= u[j];
      }
      if (i % _iteracionesPorTanda == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return Uint8List.sublistView(resultado, 0, _longitudDerivado);
  }

  /// Aviso de observabilidad (HU-136): en web+debug el KDF corre en el hilo de
  /// UI y compilado por DDC — la performance del login NO es representativa.
  static bool _avisoWebEmitido = false;
  static void _avisarSiWebDebug() {
    if (!kIsWeb || !kDebugMode || _avisoWebEmitido) return;
    _avisoWebEmitido = true;
    debugPrint(
      '[AUTH] Plataforma WEB en debug: el KDF corre en el hilo de UI (sin '
      'isolates) en modo cooperativo, y DDC lo hace varias veces más lento. '
      'Evaluar la performance real del login en un dispositivo nativo o build '
      'release.',
    );
  }

  /// PBKDF2-HMAC-SHA256 de un solo bloque (dkLen = 32 = tamaño de salida de
  /// SHA-256). Implementado sobre el `crypto` ya presente para no sumar
  /// dependencias. El bucle es CPU-intensivo: en caminos con UI usar las
  /// variantes `*Async` (HU-133) para no congelar el event loop.
  static Uint8List _pbkdf2(String password, Uint8List sal, int iteraciones) {
    final hmac = Hmac(sha256, utf8.encode(password));
    // Bloque 1: U1 = HMAC(P, S || INT_32_BE(1)).
    final entrada = Uint8List(sal.length + 4)
      ..setRange(0, sal.length, sal)
      ..[sal.length + 3] = 1;
    var u = Uint8List.fromList(hmac.convert(entrada).bytes);
    final resultado = Uint8List.fromList(u);
    for (var i = 1; i < iteraciones; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var j = 0; j < resultado.length; j++) {
        resultado[j] ^= u[j];
      }
    }
    return Uint8List.sublistView(resultado, 0, _longitudDerivado);
  }

  /// Comparación en tiempo constante (evita filtrar cuántos bytes coinciden por el
  /// tiempo de respuesta).
  static bool _igualesEnTiempoConstante(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
