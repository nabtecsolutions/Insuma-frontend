import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show LocalStorage;

import 'almacen_seguro.dart';
import 'migracion_lectura.dart';

/// [LocalStorage] de Supabase Auth respaldado por el almacén seguro (HU-036).
///
/// Es el secreto MÁS valioso del dispositivo: el JSON de la sesión incluye el
/// **refresh token**, que permite renovar el acceso indefinidamente como ese
/// usuario. Por defecto `supabase_flutter` lo guarda EN CLARO en
/// SharedPreferences; este adapter lo mueve al Keystore/Keychain.
///
/// Se inyecta en `Supabase.initialize(authOptions: FlutterAuthClientOptions(
/// localStorage: ...))`. Solo en plataformas nativas: en web la sesión vive
/// directo en `window.localStorage` (no pasa por shared_preferences) y el
/// paquete no aporta seguridad real ahí.
class AlmacenLocalSupabaseSeguro extends LocalStorage {
  final AlmacenSeguro seguro;

  /// MISMA clave que usa `SharedPreferencesLocalStorage` por defecto, para que la
  /// migración lea exactamente la entrada que la app ya tiene escrita:
  /// `sb-<primer segmento del host>-auth-token`.
  final String claveSesion;

  AlmacenLocalSupabaseSeguro({required this.seguro, required this.claveSesion});

  /// Deriva la clave igual que `supabase_flutter`: `sb-<ref>-auth-token`, donde
  /// `<ref>` es el primer segmento del host de la URL del proyecto.
  static String claveDesdeUrl(String url) =>
      'sb-${Uri.parse(url).host.split('.').first}-auth-token';

  /// La sesión ya migrada/leída en [initialize], para no repetir el read-through
  /// en cada consulta (`hasAccessToken` se llama antes de `accessToken`, y ambas
  /// deben ver lo mismo).
  String? _sesion;
  bool _inicializado = false;

  @override
  Future<void> initialize() async {
    // Read-through: si el almacén seguro no la tiene, se toma la copia en claro
    // de SharedPreferences, se cifra y se borra la vieja → la sesión de Auth
    // sobrevive a la actualización (nadie se desloguea).
    final prefs = await SharedPreferences.getInstance();
    _sesion = await leerOMigrar(
      seguro: seguro,
      prefs: prefs,
      clave: claveSesion,
    );
    _inicializado = true;
  }

  Future<String?> _leerSesion() async {
    if (_inicializado) return _sesion;
    await initialize();
    return _sesion;
  }

  @override
  Future<bool> hasAccessToken() async => (await _leerSesion()) != null;

  @override
  Future<String?> accessToken() => _leerSesion();

  @override
  Future<void> persistSession(String persistSessionString) async {
    // Se dispara en cada evento con sesión (incluye cada refresh del token).
    _sesion = persistSessionString;
    _inicializado = true;
    await seguro.escribir(claveSesion, persistSessionString);
  }

  @override
  Future<void> removePersistedSession() async {
    _sesion = null;
    _inicializado = true;
    await seguro.borrar(claveSesion);
  }
}
