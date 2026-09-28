/// Marca, por negocio y por dispositivo, si ya se completó el PRIMER PULL de datos
/// del negocio, y bloquea la creación de movimientos hasta entonces (HU-090).
///
/// **Por qué existe.** Los saldos de cuenta corriente (C5/HU-083) y los anticipos
/// (HU-092) se DERIVAN de las tablas locales (facturas/pagos/imputaciones/movimientos)
/// con SUM. Si un dispositivo nuevo opera ANTES de haber bajado la historia completa,
/// derivaría cifras incorrectas (SUM de una cadena parcial) y el usuario podría actuar
/// sobre ellas (p. ej. pagar de más). Esta guarda impide registrar movimientos hasta
/// que el negocio esté hidratado en el dispositivo.
///
/// **Se persiste POR NEGOCIO** (no en memoria): un dispositivo que ya sincronizó una
/// vez no vuelve a bloquearse —ni siquiera offline—; sólo se bloquea uno realmente
/// nuevo que nunca bajó ese negocio. Al estar clavado por `negocio_id`, cambiar de
/// tenant no necesita "reset": se consulta la clave del negocio activo.
abstract class GuardaPrimerPull {
  /// ¿El [negocioId] ya completó su primer pull en este dispositivo?
  bool primerPullHecho(String negocioId);

  /// Marca que el [negocioId] terminó su primer pull, o que es un negocio recién
  /// creado (hidratado por definición: no hay nada que bajar).
  Future<void> marcarPrimerPull(String negocioId);
}

/// Se lanza al intentar registrar un movimiento financiero antes de que el negocio
/// haya completado su primer pull en este dispositivo (HU-090). El mensaje es apto
/// para mostrarse tal cual al usuario (los controladores muestran `$e`).
class PrimerPullPendienteException implements Exception {
  const PrimerPullPendienteException();

  @override
  String toString() =>
      'Todavía se están descargando los datos del negocio. Conectate a internet '
      'para completar la primera sincronización antes de registrar movimientos.';
}

/// Lanza [PrimerPullPendienteException] si [guarda] existe y el [negocioId] todavía
/// no completó su primer pull en este dispositivo. No-op si [guarda] es null (tests
/// o build sin backend). Centraliza el check que usan los servicios financieros.
void verificarPrimerPull(GuardaPrimerPull? guarda, String negocioId) {
  if (guarda != null && !guarda.primerPullHecho(negocioId)) {
    throw const PrimerPullPendienteException();
  }
}
