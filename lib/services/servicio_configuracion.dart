import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Servicio encargado de cargar, almacenar y proveer variables de configuración
/// de entorno desde el archivo "assets/.env" y desde variables de compilación.
///
/// Convención de nombres de variables:
///   - SUPABASE_URL / SUPABASE_ANON_KEY  → conexión al backend Supabase
///   - APP_USE_MEMORY_DB                 → base de datos volátil en memoria
///   - APP_DATABASE_PATH                 → ruta personalizada del archivo SQLite
///   - APP_STORE_REVIEW                  → bypass de onboarding para revisores de tiendas
class ServicioConfiguracion {
  // Mapa de clave-valor que mantiene las configuraciones en memoria.
  static final Map<String, String> _valores = {};

  /// Carga y parsea las variables de entorno de forma asíncrona.
  /// Prioridad: variables de compilación (--dart-define) > archivo assets/.env
  static Future<void> inicializar() async {
    // 1. Variables de compilación (vía --dart-define). Tienen la mayor prioridad.
    // NOTA: String.fromEnvironment DEBE usarse como const con un literal string
    // hardcodeado — no puede recibir variables dinámicas (restricción de Dart).
    const appUseMemoryDb = String.fromEnvironment('APP_USE_MEMORY_DB');
    if (appUseMemoryDb.isNotEmpty) {
      _valores['APP_USE_MEMORY_DB'] = appUseMemoryDb;
    }

    const appDatabasePath = String.fromEnvironment('APP_DATABASE_PATH');
    if (appDatabasePath.isNotEmpty) {
      _valores['APP_DATABASE_PATH'] = appDatabasePath;
    }

    const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
    if (supabaseUrl.isNotEmpty) _valores['SUPABASE_URL'] = supabaseUrl;

    const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    if (supabaseAnonKey.isNotEmpty) {
      _valores['SUPABASE_ANON_KEY'] = supabaseAnonKey;
    }

    const appStoreReview = String.fromEnvironment('APP_STORE_REVIEW');
    if (appStoreReview.isNotEmpty) {
      _valores['APP_STORE_REVIEW'] = appStoreReview;
    }

    // 2. Archivo assets/.env — fuente de configuración por defecto para desarrollo.
    await _cargarDesdeArchivo();
  }

  /// Parsea el archivo assets/.env e inyecta las claves no sobreescritas por compilación.
  static Future<void> _cargarDesdeArchivo() async {
    try {
      final contenido = await rootBundle.loadString('assets/.env');
      final lineas = contenido.split('\n');

      for (var linea in lineas) {
        linea = linea.trim();
        // Ignorar líneas vacías y comentarios
        if (linea.isEmpty || linea.startsWith('#')) continue;

        final indiceSeparador = linea.indexOf('=');
        if (indiceSeparador == -1) continue;

        final llave = linea.substring(0, indiceSeparador).trim();
        final valor = linea.substring(indiceSeparador + 1).trim();

        // Limpiar comillas simples o dobles alrededor del valor
        var valorLimpio = valor;
        if (valorLimpio.startsWith('"') && valorLimpio.endsWith('"')) {
          valorLimpio = valorLimpio.substring(1, valorLimpio.length - 1);
        } else if (valorLimpio.startsWith("'") && valorLimpio.endsWith("'")) {
          valorLimpio = valorLimpio.substring(1, valorLimpio.length - 1);
        }

        // Las variables de compilación (--dart-define) tienen prioridad sobre el archivo .env.
        if (!_valores.containsKey(llave)) {
          _valores[llave] = valorLimpio;
        }
      }
    } catch (_) {
      // Si el archivo no existe o falla su lectura, se continúa con las variables ya cargadas.
    }
  }

  /// Obtiene un valor de configuración de texto por su clave.
  static String obtener(String clave, {String valorPorDefecto = ''}) {
    return _valores[clave] ?? valorPorDefecto;
  }

  /// Obtiene un valor de configuración booleano por su clave.
  static bool obtenerBooleano(String clave, {bool valorPorDefecto = false}) {
    final valor = _valores[clave];
    if (valor == null) return valorPorDefecto;
    return valor.toLowerCase() == 'true' || valor == '1';
  }

  /// Expone una vista de solo lectura del mapa de configuración (útil para diagnóstico).
  /// Fija un valor en memoria. **Sólo para test.**
  ///
  /// Existe porque sin `SUPABASE_URL` el drenaje del Outbox es un no-op, y eso
  /// dejaba sin cubrir justo el cableado donde vive la regla de reintentos
  /// (C-02): se podía revertir el criterio entero y la suite seguía en verde.
  /// En producción los valores salen de `--dart-define` o de `assets/.env`.
  @visibleForTesting
  static void definirParaTest(String clave, String valor) =>
      _valores[clave] = valor;

  /// Quita un valor fijado por [definirParaTest], para no filtrar entre tests.
  @visibleForTesting
  static void olvidarParaTest(String clave) => _valores.remove(clave);

  static Map<String, String> get todosLosValores => Map.unmodifiable(_valores);
}
