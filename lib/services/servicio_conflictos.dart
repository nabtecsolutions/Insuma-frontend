import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database/database.dart';

/// Motivos por los que se registra un conflicto de sincronización (HU-028).
class MotivoConflicto {
  const MotivoConflicto._();

  /// El push encontró la fila remota en otra versión (o inexistente): la
  /// mutación local NO llegó al servidor.
  static const String pushRechazado = 'push_rechazado';

  /// El pull aplicó la versión remota sobre un cambio local que estaba en vuelo.
  static const String pullPisoLocal = 'pull_piso_local';

  /// El pull NO aplicó la versión remota (append-only o importes divergentes):
  /// hay dos versiones vivas del mismo registro.
  static const String pullRechazado = 'pull_rechazado';
}

/// Bitácora de conflictos de sincronización (HU-028).
///
/// Antes de esta HU un conflicto simplemente no existía como concepto: el
/// perdedor desaparecía en silencio. Acá se registra qué registro se cruzó, por
/// qué y con qué versiones, para que el equipo pueda revisarlo — especialmente
/// en finanzas, donde la política es NO resolver automáticamente.
///
/// Es LOCAL y append-only: no se sincroniza (cada dispositivo ve los suyos) y no
/// se borra; un conflicto atendido se marca resuelto.
class ServicioConflictos {
  final BaseDatosApp _db;
  final Uuid _uuid;

  ServicioConflictos(this._db, [Uuid? uuid]) : _uuid = uuid ?? const Uuid();

  /// Registra un conflicto. IDEMPOTENTE: si ya hay uno PENDIENTE para el mismo
  /// `(tabla, registro, motivo, versiones)` no se duplica — así el mismo choque
  /// detectado en cada pull no llena la bitácora (criterio "un conflicto
  /// resuelto no reaparece"; y uno vivo no se multiplica).
  Future<void> registrar({
    required String nombreTabla,
    required String registroId,
    required String motivo,
    String? negocioId,
    int? versionLocal,
    int? versionRemota,
    String? detalle,
  }) async {
    final yaRegistrado =
        await (_db.select(_db.conflictosSync)..where(
              (c) =>
                  c.nombreTabla.equals(nombreTabla) &
                  c.registroId.equals(registroId) &
                  c.motivo.equals(motivo) &
                  c.resueltoEn.isNull(),
            ))
            .get();
    final duplicado = yaRegistrado.any(
      (c) => c.versionLocal == versionLocal && c.versionRemota == versionRemota,
    );
    if (duplicado) return;

    await _db
        .into(_db.conflictosSync)
        .insert(
          ConflictosSyncCompanion.insert(
            id: _uuid.v4(),
            negocioId: Value(negocioId),
            nombreTabla: nombreTabla,
            registroId: registroId,
            motivo: motivo,
            versionLocal: Value(versionLocal),
            versionRemota: Value(versionRemota),
            detalle: Value(detalle),
            fechaDeteccion: Value(DateTime.now()),
          ),
        );
  }

  /// Conflictos sin resolver, más recientes primero.
  Future<List<ConflictosSyncData>> pendientes({String? negocioId}) {
    final q = _db.select(_db.conflictosSync)
      ..where((c) => c.resueltoEn.isNull())
      ..orderBy([(c) => OrderingTerm.desc(c.fechaDeteccion)]);
    if (negocioId != null) {
      q.where((c) => c.negocioId.equals(negocioId));
    }
    return q.get();
  }

  /// Stream reactivo de conflictos pendientes (para un futuro indicador en la UI).
  Stream<List<ConflictosSyncData>> observarPendientes({String? negocioId}) {
    final q = _db.select(_db.conflictosSync)
      ..where((c) => c.resueltoEn.isNull())
      ..orderBy([(c) => OrderingTerm.desc(c.fechaDeteccion)]);
    if (negocioId != null) {
      q.where((c) => c.negocioId.equals(negocioId));
    }
    return q.watch();
  }

  Future<int> cantidadPendientes({String? negocioId}) async =>
      (await pendientes(negocioId: negocioId)).length;

  /// Marca un conflicto como atendido. No lo borra: la bitácora es append-only.
  Future<void> marcarResuelto(String id) async {
    await (_db.update(_db.conflictosSync)..where((c) => c.id.equals(id))).write(
      ConflictosSyncCompanion(resueltoEn: Value(DateTime.now())),
    );
  }

  /// Marca resueltos TODOS los conflictos vivos de un registro. Lo usa el flujo
  /// que vuelve a sincronizar ese registro con éxito: si el choque ya se saldó,
  /// no debe seguir figurando como pendiente.
  Future<void> marcarResueltosDe({
    required String nombreTabla,
    required String registroId,
  }) async {
    await (_db.update(_db.conflictosSync)..where(
          (c) =>
              c.nombreTabla.equals(nombreTabla) &
              c.registroId.equals(registroId) &
              c.resueltoEn.isNull(),
        ))
        .write(ConflictosSyncCompanion(resueltoEn: Value(DateTime.now())));
  }
}
