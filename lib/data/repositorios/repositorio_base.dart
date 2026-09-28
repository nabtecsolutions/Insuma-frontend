import '../../database/database.dart';
import '../../services/servicio_sincronizacion_supabase.dart';

/// Base de todos los repositorios. Centraliza el acceso al store local (Drift)
/// y el encolado de mutaciones hacia el "Model" remoto (Supabase) vía Outbox.
///
/// Arquitectura: los repositorios son la ÚNICA capa que toca la persistencia.
/// Escriben siempre en el store local (offline-first) y, cuando la sincronización
/// está activa (ver ConfigPersistencia/.env), encolan la mutación para Supabase.
/// El [sync] es nulo en modo `local`.
abstract class RepositorioSincronizable {
  final BaseDatosApp db;
  final ServicioSincronizacionSupabase? sync;

  RepositorioSincronizable(this.db, this.sync);

  Future<void> encolarInsert(
    String tabla,
    String id,
    Map<String, dynamic> datosSnake,
  ) =>
      sync?.encolarMutacion(
        nombreTabla: tabla,
        registroId: id,
        accion: 'INSERT',
        datos: datosSnake,
      ) ??
      Future.value();

  /// Encola un UPDATE. [versionBase] es la `version` que tenía la fila ANTES de
  /// mutarla (HU-028): el push la usa como guarda de concurrencia optimista para
  /// no pisar un cambio que otro dispositivo ya subió. Null en tablas sin
  /// `version` (append-only), que se resuelven por otra política.
  Future<void> encolarUpdate(
    String tabla,
    String id,
    Map<String, dynamic> datosSnake, {
    int? versionBase,
  }) =>
      sync?.encolarMutacion(
        nombreTabla: tabla,
        registroId: id,
        accion: 'UPDATE',
        datos: datosSnake,
        versionBase: versionBase,
      ) ??
      Future.value();

  /// Próxima `version` de una fila mutable (HU-028). Es un contador exacto: se
  /// prefiere a los timestamps porque no depende del reloj del dispositivo (uno
  /// mal configurado ganaría todos los last-write-wins por fecha).
  int siguienteVersion(int versionActual) => versionActual + 1;

  Future<void> encolarDelete(String tabla, String id) =>
      sync?.encolarMutacion(
        nombreTabla: tabla,
        registroId: id,
        accion: 'DELETE',
        datos: {'id': id},
      ) ??
      Future.value();

  /// Serializa una fecha al formato que espera Supabase (ISO-8601 UTC).
  String iso(DateTime fecha) => fecha.toUtc().toIso8601String();
}
