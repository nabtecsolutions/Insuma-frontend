import '../database/database.dart';
import '../data/repositorios/repositorio_categorias.dart';
import '../data/repositorios/repositorio_proveedor_categorias.dart';
import '../utils/id_determinista.dart';

/// Servicio de negocio de la relación proveedor↔categoría (#262): qué categorías
/// suministra cada proveedor.
///
/// Coordina DOS repositorios: la tabla puente [RepositorioProveedorCategorias] y
/// el catálogo [RepositorioCategorias]. La UI necesita los NOMBRES de las
/// categorías (no ids sueltos), así que este servicio cruza el vínculo vivo con
/// el catálogo activo y devuelve entidades [Categoria] listas para mostrar.
///
/// División de responsabilidades: la validación del NOMBRE de una categoría (no
/// vacío, unicidad, reactivación) vive en [ServicioCategorias] y NO se repite
/// acá. Este servicio sólo asigna/desasigna vínculos por id.
class ServicioProveedorCategorias {
  final RepositorioProveedorCategorias _vinculos;
  final RepositorioCategorias _categorias;

  ServicioProveedorCategorias(this._vinculos, this._categorias);

  /// Categorías ACTIVAS que suministra [proveedorId], como entidades ordenadas
  /// por nombre. Una categoría desactivada deja de aparecer aunque el vínculo
  /// siga vivo: si se reactiva, vuelve a mostrarse (el vínculo no se pierde).
  Future<List<Categoria>> categoriasDe(
    String negocioId,
    String proveedorId,
  ) async {
    final vinculos = await _vinculos.deProveedor(proveedorId);
    final ids = vinculos.map((v) => v.categoriaId).toSet();
    final catalogo = await _categorias.listar(negocioId);
    return catalogo.where((c) => ids.contains(c.id)).toList();
  }

  /// Categorías activas del negocio que [proveedorId] AÚN NO suministra: las
  /// candidatas a asignar en la ficha del proveedor. Ordenadas por nombre.
  Future<List<Categoria>> disponiblesPara(
    String negocioId,
    String proveedorId,
  ) async {
    final vinculos = await _vinculos.deProveedor(proveedorId);
    final asignadas = vinculos.map((v) => v.categoriaId).toSet();
    final catalogo = await _categorias.listar(negocioId);
    return catalogo.where((c) => !asignadas.contains(c.id)).toList();
  }

  /// Asigna la categoría al proveedor (idempotente: reactiva si estaba dada de
  /// baja, nunca duplica — el id del vínculo se deriva del par).
  Future<void> asignar({
    required String negocioId,
    required String proveedorId,
    required String categoriaId,
  }) => _vinculos.asignar(
    negocioId: negocioId,
    proveedorId: proveedorId,
    categoriaId: categoriaId,
  );

  /// Baja lógica del vínculo proveedor↔categoría (nunca DELETE físico).
  Future<void> desasignar({
    required String proveedorId,
    required String categoriaId,
  }) => _vinculos.desasignar(
    IdDeterminista.parProveedorCategoria(proveedorId, categoriaId),
  );
}
