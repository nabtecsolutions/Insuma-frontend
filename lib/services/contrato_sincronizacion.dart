/// Limpieza de la cola local, DESACOPLADA del sincronizador (HU-132).
///
/// La invariante "tenant reconciliado ⇒ cola limpia" no depende de que haya
/// backend: descartar la cola es un DELETE local. Con la sync desactivada
/// (`_sync == null`, modo APP_PERSISTENCIA=local) la reconciliación de tenant
/// debe poder limpiar igual — si no, las mutaciones del tenant viejo sobreviven
/// y, al volver a modo híbrido, se drenan con el JWT del tenant nuevo (42501).
abstract class DescartadorCola {
  /// Descarta TODA la cola pendiente (mutaciones selladas con un tenant inválido).
  Future<void> descartarPendientes();
}

/// Operaciones del Outbox (cola de sincronización) que necesita el flujo de
/// acceso (HU-072).
///
/// Es una costura mínima: permite que `ServicioAcceso` dependa de un contrato en
/// vez del `ServicioSincronizacionSupabase` concreto (que exige un `SupabaseClient`
/// real), y así su lógica —incluida la reconciliación de tenant— es testeable.
///
/// El nombre evita `ColaSincronizacion`, que ya es la tabla generada por Drift.
abstract class SincronizadorOutbox implements DescartadorCola {
  /// Intenta drenar las mutaciones pendientes hacia el backend.
  Future<void> sincronizarPendientes();
}
