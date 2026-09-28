import '../../database/database.dart';
import '../../services/contrato_sincronizacion.dart';
import '../liberacion_pendientes.dart';

/// Limpiador de la cola local (HU-132): borra `cola_sincronizacion` directo en
/// Drift, sin depender del sincronizador. Existe para que la reconciliación de
/// tenant pueda descartar la cola aunque la sync esté desactivada
/// (`_sync == null`): la limpieza es un DELETE local, no necesita backend.
class DescartadorColaDrift implements DescartadorCola {
  final BaseDatosApp _db;

  DescartadorColaDrift(this._db);

  @override
  Future<void> descartarPendientes() async {
    // #223: las filas que estas mutaciones dejaban marcadas se SUELTAN antes de
    // borrar la cola. Sin esto quedaban en 'pendiente' para siempre, y una fila
    // así deja de recibir actualizaciones del servidor — en silencio.
    final items = await _db.select(_db.colaSincronizacion).get();
    await liberarFilasDeMutaciones(_db, items);
    await _db.delete(_db.colaSincronizacion).go();
  }
}
