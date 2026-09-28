import '../services/servicio_configuracion.dart';

/// Estrategia de persistencia de datos elegida por configuración (`.env`).
///
///   - [local]    : sólo SQLite/Drift en el dispositivo. No sincroniza con backend.
///   - [supabase] : SQLite/Drift como caché local + sincronización ACTIVA con Supabase.
///   - [hibrido]  : igual que [supabase] (offline-first con sync). Valor por defecto.
///
/// Configurar en assets/.env:  APP_PERSISTENCIA=hibrido | local | supabase
enum TipoPersistencia { local, supabase, hibrido }

class ConfigPersistencia {
  /// Lee la estrategia desde `.env` (clave APP_PERSISTENCIA). Por defecto: híbrido.
  static TipoPersistencia obtener() {
    final valor = ServicioConfiguracion.obtener(
      'APP_PERSISTENCIA',
      valorPorDefecto: 'hibrido',
    ).trim().toLowerCase();
    switch (valor) {
      case 'local':
        return TipoPersistencia.local;
      case 'supabase':
        return TipoPersistencia.supabase;
      case 'hibrido':
      case 'hybrid':
      default:
        return TipoPersistencia.hibrido;
    }
  }

  /// Indica si la sincronización con Supabase debe estar activa.
  static bool get sincronizacionActiva => obtener() != TipoPersistencia.local;
}
