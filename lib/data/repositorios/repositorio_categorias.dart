import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../database/database.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio del catálogo de CATEGORÍAS de insumo (rediseño
/// insumos-por-categoría).
///
/// Es la ÚNICA capa que toca la persistencia de categorías: escribe en el store
/// local (Drift, offline-first) y encola la mutación hacia Supabase vía Outbox.
/// La lógica de negocio (validaciones, unicidad, reactivación) vive en el Service.
/// Espeja 1:1 a [RepositorioMotivosRecepcion] (HU-065): mismo patrón de catálogo
/// negocio-scoped con soft-delete.
abstract class RepositorioCategorias {
  /// Lista las categorías del negocio. Por defecto solo las activas; con
  /// [incluirInactivos] trae también las desactivadas (para reactivar/auditar).
  Future<List<Categoria>> listar(
    String negocioId, {
    bool incluirInactivos = false,
  });

  /// Crea una categoría nueva. No valida unicidad: eso es del Service.
  Future<Categoria> crear({required String negocioId, required String nombre});

  /// Renombra una categoría existente.
  Future<Categoria> renombrar({required String id, required String nombre});

  /// Activa o desactiva una categoría (soft-delete).
  Future<Categoria> cambiarEstado(String id, bool activo);
}

/// Implementación local (Drift) con encolado de sincronización hacia Supabase.
class RepositorioCategoriasDrift extends RepositorioSincronizable
    implements RepositorioCategorias {
  RepositorioCategoriasDrift(super.db, super.sync);

  static const String _tabla = 'categorias';

  @override
  Future<List<Categoria>> listar(
    String negocioId, {
    bool incluirInactivos = false,
  }) {
    final query = db.select(db.categorias)
      ..where(
        (c) => incluirInactivos
            ? c.negocioId.equals(negocioId)
            : c.negocioId.equals(negocioId) & c.activo.equals(true),
      )
      ..orderBy([(c) => OrderingTerm(expression: c.nombre)]);
    return query.get();
  }

  @override
  Future<Categoria> crear({
    required String negocioId,
    required String nombre,
  }) async {
    final id = const Uuid().v4();
    final ahora = DateTime.now();
    await db
        .into(db.categorias)
        .insert(
          CategoriasCompanion.insert(
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
  Future<Categoria> renombrar({
    required String id,
    required String nombre,
  }) async {
    final actual = await _porId(id);
    await (db.update(db.categorias)..where((c) => c.id.equals(id))).write(
      CategoriasCompanion(
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
  Future<Categoria> cambiarEstado(String id, bool activo) async {
    final actual = await _porId(id);
    await (db.update(db.categorias)..where((c) => c.id.equals(id))).write(
      CategoriasCompanion(
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

  Future<Categoria> _porId(String id) =>
      (db.select(db.categorias)..where((c) => c.id.equals(id))).getSingle();

  /// Mapeo a snake_case para Supabase (Outbox).
  Map<String, dynamic> _aMapa(Categoria c) => {
    'id': c.id,
    'negocio_id': c.negocioId,
    'nombre': c.nombre,
    'activo': c.activo,
    'version': c.version,
  };
}
