import 'package:drift/drift.dart';

import '../../database/database.dart';

/// Contrato del repositorio de cursores de pull incremental (#250).
///
/// Guarda, por (negocio, tabla), la ALTA-MARCA del timestamp server-set más
/// nuevo ya aplicado localmente. El orquestador del pull lo lee al empezar
/// (para filtrar `>= cursor − lag`) y lo avanza al terminar cada tabla, sólo si
/// el pull de esa tabla fue confiable (llegó, no se salteó, no omitió filas).
///
/// A diferencia del resto de los repositorios, este NO extiende
/// `RepositorioSincronizable` y NO recibe el Outbox: el cursor es estado LOCAL
/// PURO, derivado de lo que este dispositivo ya bajó. Subirlo no tendría sentido
/// (cada dispositivo tiene su propio avance) y encolarlo ensuciaría la cola.
/// Mismo criterio que el caché de bytes de #248.
abstract class RepositorioCursoresPull {
  /// Todos los cursores de un negocio, como mapa `tabla → alta-marca`. Una tabla
  /// AUSENTE del mapa nunca se pulleó en este dispositivo → el orquestador la
  /// baja completa (cursor epoch).
  Future<Map<String, DateTime>> leer(String negocioId);

  /// Avanza (o crea) el cursor de una (negocio, tabla) a [cursor]. Es un upsert
  /// local puro; nunca toca el Outbox.
  Future<void> guardar(String negocioId, String tabla, DateTime cursor);

  /// Borra todos los cursores de un negocio: fuerza un pull completo la próxima
  /// vez. Lo usa una migración/reset que invalidó lo que había local (si la
  /// forma de una tabla cambió, su alta-marca vieja ya no es de fiar).
  ///
  /// HOY no tiene caller en `lib/` a propósito: la migración v23 sólo CREA la
  /// tabla de cursores, no recrea ninguna tabla de datos, así que no hay
  /// alta-marca que invalidar. Es la costura que debe llamar la próxima
  /// migración que recree o reescriba una tabla pulleada por cursor.
  Future<void> resetear(String negocioId);
}

class RepositorioCursoresPullDrift implements RepositorioCursoresPull {
  final BaseDatosApp _db;

  RepositorioCursoresPullDrift(this._db);

  @override
  Future<Map<String, DateTime>> leer(String negocioId) async {
    final filas = await (_db.select(
      _db.cursoresPull,
    )..where((c) => c.negocioId.equals(negocioId))).get();
    return {for (final f in filas) f.tabla: f.cursor};
  }

  @override
  Future<void> guardar(String negocioId, String tabla, DateTime cursor) async {
    await _db
        .into(_db.cursoresPull)
        .insertOnConflictUpdate(
          CursoresPullCompanion(
            negocioId: Value(negocioId),
            tabla: Value(tabla),
            cursor: Value(cursor),
          ),
        );
  }

  @override
  Future<void> resetear(String negocioId) async {
    await (_db.delete(
      _db.cursoresPull,
    )..where((c) => c.negocioId.equals(negocioId))).go();
  }
}
