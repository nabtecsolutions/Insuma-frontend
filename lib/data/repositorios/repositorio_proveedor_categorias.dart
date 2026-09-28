import 'package:drift/drift.dart';

import '../../database/database.dart';
import '../../utils/id_determinista.dart';
import '../mapeadores_supabase.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio de la relación proveedor↔categoría (#262): qué
/// categorías suministra cada proveedor.
///
/// Es la ÚNICA capa que toca la persistencia de estos vínculos: escribe en el
/// store local (Drift, offline-first) y encola la mutación hacia Supabase por el
/// Outbox. Sigue el molde del viejo repo de vínculos insumo↔proveedor (HU-138,
/// retirado en #262) — id determinista, alta idempotente con reactivación, baja
/// lógica — PERO sin `precio` (el precio de lista por vínculo se abandonó: el
/// costo se estima sobre el último real).
abstract class RepositorioProveedorCategorias {
  /// Categorías que suministra [proveedorId]. Por defecto solo los vínculos vivos.
  Future<List<ProveedorCategoria>> deProveedor(
    String proveedorId, {
    bool incluirInactivos = false,
  });

  /// Proveedores que suministran [categoriaId]. Por defecto solo los vivos.
  Future<List<ProveedorCategoria>> deCategoria(
    String categoriaId, {
    bool incluirInactivos = false,
  });

  /// Todos los vínculos vivos del negocio (para resolver en lote sin pegarle a la
  /// base una vez por proveedor).
  Future<List<ProveedorCategoria>> delNegocio(
    String negocioId, {
    bool incluirInactivos = false,
  });

  /// Observa los vínculos vivos del negocio (reactividad, patrón HU-089).
  Stream<List<ProveedorCategoria>> observarDelNegocio(String negocioId);

  /// Asigna la categoría al proveedor, o la REACTIVA si ya existía dada de baja.
  ///
  /// Es idempotente: el id se deriva del par proveedor↔categoría, así que llamarlo
  /// dos veces actualiza la misma fila en vez de crear una segunda.
  Future<ProveedorCategoria> asignar({
    required String negocioId,
    required String proveedorId,
    required String categoriaId,
  });

  /// Baja LÓGICA del vínculo (nunca DELETE físico: ver el doc de la tabla).
  Future<ProveedorCategoria> desasignar(String id);
}

/// Implementación local (Drift) con encolado hacia Supabase.
class RepositorioProveedorCategoriasDrift extends RepositorioSincronizable
    implements RepositorioProveedorCategorias {
  RepositorioProveedorCategoriasDrift(super.db, super.sync);

  static const String _tabla = 'proveedor_categorias';

  @override
  Future<List<ProveedorCategoria>> deProveedor(
    String proveedorId, {
    bool incluirInactivos = false,
  }) {
    final q = db.select(db.proveedorCategorias)
      ..where(
        (v) => incluirInactivos
            ? v.proveedorId.equals(proveedorId)
            : v.proveedorId.equals(proveedorId) & v.activo.equals(true),
      );
    return q.get();
  }

  @override
  Future<List<ProveedorCategoria>> deCategoria(
    String categoriaId, {
    bool incluirInactivos = false,
  }) {
    final q = db.select(db.proveedorCategorias)
      ..where(
        (v) => incluirInactivos
            ? v.categoriaId.equals(categoriaId)
            : v.categoriaId.equals(categoriaId) & v.activo.equals(true),
      );
    return q.get();
  }

  @override
  Future<List<ProveedorCategoria>> delNegocio(
    String negocioId, {
    bool incluirInactivos = false,
  }) {
    final q = db.select(db.proveedorCategorias)
      ..where(
        (v) => incluirInactivos
            ? v.negocioId.equals(negocioId)
            : v.negocioId.equals(negocioId) & v.activo.equals(true),
      );
    return q.get();
  }

  @override
  Stream<List<ProveedorCategoria>> observarDelNegocio(String negocioId) {
    final q = db.select(db.proveedorCategorias)
      ..where((v) => v.negocioId.equals(negocioId) & v.activo.equals(true));
    return q.watch();
  }

  @override
  Future<ProveedorCategoria> asignar({
    required String negocioId,
    required String proveedorId,
    required String categoriaId,
  }) async {
    final id = IdDeterminista.parProveedorCategoria(proveedorId, categoriaId);
    final existente = await _porIdOrNull(id);
    final ahora = DateTime.now();

    if (existente == null) {
      await db
          .into(db.proveedorCategorias)
          .insert(
            ProveedorCategoriasCompanion.insert(
              id: id,
              negocioId: negocioId,
              proveedorId: proveedorId,
              categoriaId: categoriaId,
              fechaCreacion: Value(ahora),
              fechaActualizacion: Value(ahora),
            ),
          );
      final creado = await _porId(id);
      await encolarInsert(
        _tabla,
        id,
        MapeadoresSupabase.proveedorCategoria(creado),
      );
      return creado;
    }

    // Ya existía (típicamente dado de baja): se REACTIVA. Nunca se inserta una
    // segunda fila del mismo par — el índice único lo impediría y se perdería el
    // historial de ese vínculo.
    return _escribir(
      existente,
      const ProveedorCategoriasCompanion(activo: Value(true)),
    );
  }

  @override
  Future<ProveedorCategoria> desasignar(String id) async => _escribir(
    await _porId(id),
    const ProveedorCategoriasCompanion(activo: Value(false)),
  );

  /// Aplica [cambios] sobre [actual] avanzando la versión y encolando el UPDATE.
  ///
  /// HU-028: `versionBase` es la versión que la fila tenía ANTES de incrementarla
  /// — es el token con el que el push detecta que alguien más la tocó.
  Future<ProveedorCategoria> _escribir(
    ProveedorCategoria actual,
    ProveedorCategoriasCompanion cambios,
  ) async {
    await (db.update(
      db.proveedorCategorias,
    )..where((v) => v.id.equals(actual.id))).write(
      cambios.copyWith(
        version: Value(actual.version + 1),
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    final actualizado = await _porId(actual.id);
    await encolarUpdate(
      _tabla,
      actual.id,
      MapeadoresSupabase.proveedorCategoria(actualizado),
      versionBase: actual.version,
    );
    return actualizado;
  }

  Future<ProveedorCategoria> _porId(String id) => (db.select(
    db.proveedorCategorias,
  )..where((v) => v.id.equals(id))).getSingle();

  Future<ProveedorCategoria?> _porIdOrNull(String id) => (db.select(
    db.proveedorCategorias,
  )..where((v) => v.id.equals(id))).getSingleOrNull();
}
