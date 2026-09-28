import 'contenido_archivo.dart';

/// Contrato del manejo de imágenes de un adjunto (HU-066): compresión/normalización.
///
/// Mantiene la lógica de imagen FUERA del service, el controlador y la vista. Para
/// archivos que NO son imagen (PDF), la implementación debe devolver el contenido
/// intacto. Tener una interfaz permite fakearlo en tests (sin plugin nativo).
abstract class ProcesadorImagenes {
  /// Devuelve una versión optimizada de [original] cuando es una imagen que supera
  /// [objetivoBytes]; si es PDF o ya está por debajo del objetivo, devuelve el mismo
  /// contenido sin cambios.
  Future<ContenidoArchivo> optimizar(
    ContenidoArchivo original, {
    int objetivoBytes,
  });
}
