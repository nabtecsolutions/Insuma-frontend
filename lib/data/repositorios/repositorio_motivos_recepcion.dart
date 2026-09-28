import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../database/database.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio del catálogo de motivos de recepción (HU-065).
///
/// Es la ÚNICA capa que toca la persistencia de motivos: escribe en el store
/// local (Drift, offline-first) y encola la mutación hacia Supabase vía Outbox.
/// La lógica de negocio (validaciones, unicidad, reactivación) vive en el Service.
abstract class RepositorioMotivosRecepcion {
  /// Lista los motivos del negocio. Por defecto solo los activos; con
  /// [incluirInactivos] trae también los desactivados (para reactivar/auditar).
  Future<List<MotivosRecepcionData>> listar(
    String negocioId, {
    bool incluirInactivos = false,
  });

  /// Crea un motivo nuevo. No valida unicidad: eso es responsabilidad del Service.
  Future<MotivosRecepcionData> crear({
    required String negocioId,
    required String nombre,
  });

  /// Renombra un motivo existente.
  Future<MotivosRecepcionData> renombrar({
    required String id,
    required String nombre,
  });

  /// Activa o desactiva un motivo (soft-delete).
  Future<MotivosRecepcionData> cambiarEstado(String id, bool activo);
}

/// Implementación local (Drift) con encolado de sincronización hacia Supabase.
class RepositorioMotivosRecepcionDrift extends RepositorioSincronizable
    implements RepositorioMotivosRecepcion {
  RepositorioMotivosRecepcionDrift(super.db, super.sync);

  static const String _tabla = 'motivos_recepcion';

  @override
  Future<List<MotivosRecepcionData>> listar(
    String negocioId, {
    bool incluirInactivos = false,
  }) {
    final query = db.select(db.motivosRecepcion)
      ..where(
        (m) => incluirInactivos
            ? m.negocioId.equals(negocioId)
            : m.negocioId.equals(negocioId) & m.activo.equals(true),
      )
      ..orderBy([(m) => OrderingTerm(expression: m.nombre)]);
    return query.get();
  }

  @override
  Future<MotivosRecepcionData> crear({
    required String negocioId,
    required String nombre,
  }) async {
    final id = const Uuid().v4();
    final ahora = DateTime.now();
    await db
        .into(db.motivosRecepcion)
        .insert(
          MotivosRecepcionCompanion.insert(
            id: id,
            negocioId: negocioId,
            nombre: nombre,
            fechaCreacion: Value(ahora),
            fechaActualizacion: Value(ahora),
          ),
        );
    final creado = await _porId(id);
    await encolarInsert(_tabla, id, _aMapa(creado));
    return creado;
  }

  @override
  Future<MotivosRecepcionData> renombrar({
    required String id,
    required String nombre,
  }) async {
    final actual = await _porId(id);
    await (db.update(db.motivosRecepcion)..where((m) => m.id.equals(id))).write(
      MotivosRecepcionCompanion(
        nombre: Value(nombre),
        version: Value(actual.version + 1),
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    final actualizado = await _porId(id);
    // HU-028: versionBase = la que tenía la fila antes de incrementarla.
    await encolarUpdate(
      _tabla,
      id,
      _aMapa(actualizado),
      versionBase: actual.version,
    );
    return actualizado;
  }

  @override
  Future<MotivosRecepcionData> cambiarEstado(String id, bool activo) async {
    final actual = await _porId(id);
    await (db.update(db.motivosRecepcion)..where((m) => m.id.equals(id))).write(
      MotivosRecepcionCompanion(
        activo: Value(activo),
        version: Value(actual.version + 1),
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    final actualizado = await _porId(id);
    // HU-028: versionBase = la que tenía la fila antes de incrementarla.
    await encolarUpdate(
      _tabla,
      id,
      _aMapa(actualizado),
      versionBase: actual.version,
    );
    return actualizado;
  }

  Future<MotivosRecepcionData> _porId(String id) => (db.select(
    db.motivosRecepcion,
  )..where((m) => m.id.equals(id))).getSingle();

  /// Mapeo a snake_case para Supabase (Outbox).
  Map<String, dynamic> _aMapa(MotivosRecepcionData m) => {
    'id': m.id,
    'negocio_id': m.negocioId,
    'nombre': m.nombre,
    'activo': m.activo,
    'version': m.version,
  };
}
