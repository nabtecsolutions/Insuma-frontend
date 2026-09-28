import '../database/database.dart';
import '../data/repositorios/repositorio_categorias.dart';

/// Resultado de una operación de escritura del catálogo: éxito con la categoría,
/// o un mensaje de error de validación listo para mostrar en la UI.
class ResultadoCategoria {
  final Categoria? categoria;
  final String? error;

  const ResultadoCategoria._(this.categoria, this.error);
  factory ResultadoCategoria.ok(Categoria c) => ResultadoCategoria._(c, null);
  factory ResultadoCategoria.error(String mensaje) =>
      ResultadoCategoria._(null, mensaje);

  bool get esOk => categoria != null;
}

/// Servicio de negocio del catálogo de CATEGORÍAS de insumo (rediseño
/// insumos-por-categoría).
///
/// Concentra TODA la lógica: validación de nombre, unicidad por negocio
/// (case-insensitive) y soft-delete. El controlador solo orquesta el estado de la
/// vista; la persistencia y el encolado de sync viven en el repositorio. Espeja
/// 1:1 a [ServicioMotivosRecepcion] (HU-065).
class ServicioCategorias {
  final RepositorioCategorias _repo;

  ServicioCategorias(this._repo);

  /// Lista las categorías del negocio (solo activas salvo [incluirInactivos]).
  Future<List<Categoria>> listar(
    String negocioId, {
    bool incluirInactivos = false,
  }) => _repo.listar(negocioId, incluirInactivos: incluirInactivos);

  /// Crea una categoría validando nombre no vacío y unicidad por negocio
  /// (case-insensitive, ignorando espacios). Si ya existe una INACTIVA con ese
  /// nombre, la reactiva en lugar de fallar: evita el choque con la unicidad de
  /// la base y resulta más intuitivo para el admin.
  Future<ResultadoCategoria> crear(String negocioId, String nombreCrudo) async {
    final nombre = nombreCrudo.trim();
    if (nombre.isEmpty) {
      return ResultadoCategoria.error('El nombre no puede estar vacío.');
    }

    final existentes = await _repo.listar(negocioId, incluirInactivos: true);
    final coincidente = _buscarPorNombre(existentes, nombre);
    if (coincidente != null) {
      if (coincidente.activo) {
        return ResultadoCategoria.error(
          'Ya existe una categoría con ese nombre.',
        );
      }
      return ResultadoCategoria.ok(
        await _repo.cambiarEstado(coincidente.id, true),
      );
    }
    return ResultadoCategoria.ok(
      await _repo.crear(negocioId: negocioId, nombre: nombre),
    );
  }

  /// Renombra una categoría validando nombre no vacío y unicidad por negocio
  /// (excluyendo a la propia categoría que se está editando).
  Future<ResultadoCategoria> renombrar(
    String negocioId,
    String id,
    String nombreCrudo,
  ) async {
    final nombre = nombreCrudo.trim();
    if (nombre.isEmpty) {
      return ResultadoCategoria.error('El nombre no puede estar vacío.');
    }

    final existentes = await _repo.listar(negocioId, incluirInactivos: true);
    final coincidente = _buscarPorNombre(existentes, nombre);
    if (coincidente != null && coincidente.id != id) {
      return ResultadoCategoria.error(
        'Ya existe una categoría con ese nombre.',
      );
    }
    return ResultadoCategoria.ok(await _repo.renombrar(id: id, nombre: nombre));
  }

  /// Activa o desactiva (soft-delete) una categoría.
  Future<Categoria> cambiarEstado(String id, bool activo) =>
      _repo.cambiarEstado(id, activo);

  /// Busca en [lista] una categoría cuyo nombre coincida (trim + case-insensitive).
  Categoria? _buscarPorNombre(List<Categoria> lista, String nombre) {
    final objetivo = nombre.toLowerCase();
    for (final c in lista) {
      if (c.nombre.trim().toLowerCase() == objetivo) return c;
    }
    return null;
  }
}
