import '../database/database.dart';
import '../data/repositorios/repositorio_motivos_recepcion.dart';

/// Resultado de una operación de escritura del catálogo: éxito con el motivo, o
/// un mensaje de error de validación listo para mostrar en la UI.
class ResultadoMotivo {
  final MotivosRecepcionData? motivo;
  final String? error;

  const ResultadoMotivo._(this.motivo, this.error);
  factory ResultadoMotivo.ok(MotivosRecepcionData m) =>
      ResultadoMotivo._(m, null);
  factory ResultadoMotivo.error(String mensaje) =>
      ResultadoMotivo._(null, mensaje);

  bool get esOk => motivo != null;
}

/// Servicio de negocio del catálogo de motivos de recepción (HU-065).
///
/// Concentra TODA la lógica: validación de nombre, unicidad por negocio
/// (case-insensitive) y soft-delete. El controlador solo orquesta el estado de la
/// vista; la persistencia y el encolado de sync viven en el repositorio.
class ServicioMotivosRecepcion {
  final RepositorioMotivosRecepcion _repo;

  ServicioMotivosRecepcion(this._repo);

  /// Lista los motivos del negocio (solo activos salvo [incluirInactivos]).
  Future<List<MotivosRecepcionData>> listar(
    String negocioId, {
    bool incluirInactivos = false,
  }) => _repo.listar(negocioId, incluirInactivos: incluirInactivos);

  /// Crea un motivo validando nombre no vacío y unicidad por negocio
  /// (case-insensitive, ignorando espacios). Si ya existe uno INACTIVO con ese
  /// nombre, lo reactiva en lugar de fallar: evita el choque con la unicidad de
  /// la base y resulta más intuitivo para el admin.
  Future<ResultadoMotivo> crear(String negocioId, String nombreCrudo) async {
    final nombre = nombreCrudo.trim();
    if (nombre.isEmpty) {
      return ResultadoMotivo.error('El nombre no puede estar vacío.');
    }

    final existentes = await _repo.listar(negocioId, incluirInactivos: true);
    final coincidente = _buscarPorNombre(existentes, nombre);
    if (coincidente != null) {
      if (coincidente.activo) {
        return ResultadoMotivo.error('Ya existe un motivo con ese nombre.');
      }
      return ResultadoMotivo.ok(
        await _repo.cambiarEstado(coincidente.id, true),
      );
    }
    return ResultadoMotivo.ok(
      await _repo.crear(negocioId: negocioId, nombre: nombre),
    );
  }

  /// Renombra un motivo validando nombre no vacío y unicidad por negocio
  /// (excluyendo al propio motivo que se está editando).
  Future<ResultadoMotivo> renombrar(
    String negocioId,
    String id,
    String nombreCrudo,
  ) async {
    final nombre = nombreCrudo.trim();
    if (nombre.isEmpty) {
      return ResultadoMotivo.error('El nombre no puede estar vacío.');
    }

    final existentes = await _repo.listar(negocioId, incluirInactivos: true);
    final coincidente = _buscarPorNombre(existentes, nombre);
    if (coincidente != null && coincidente.id != id) {
      return ResultadoMotivo.error('Ya existe un motivo con ese nombre.');
    }
    return ResultadoMotivo.ok(await _repo.renombrar(id: id, nombre: nombre));
  }

  /// Activa o desactiva (soft-delete) un motivo.
  Future<MotivosRecepcionData> cambiarEstado(String id, bool activo) =>
      _repo.cambiarEstado(id, activo);

  /// Busca en [lista] un motivo cuyo nombre coincida (trim + case-insensitive).
  MotivosRecepcionData? _buscarPorNombre(
    List<MotivosRecepcionData> lista,
    String nombre,
  ) {
    final objetivo = nombre.toLowerCase();
    for (final m in lista) {
      if (m.nombre.trim().toLowerCase() == objetivo) return m;
    }
    return null;
  }
}
