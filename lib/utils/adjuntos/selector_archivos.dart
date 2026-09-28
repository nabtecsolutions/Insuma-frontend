import 'contenido_archivo.dart';

/// Contrato de captura de un archivo desde el almacenamiento local del dispositivo
/// (HU-066). Aísla el plugin (file_picker) para que el service y el controlador no
/// dependan de él, y para poder fakearlo en tests.
abstract class SelectorArchivos {
  /// Abre el selector del sistema para elegir UN archivo (PDF/JPG/PNG) desde el
  /// almacenamiento local. Devuelve `null` si el usuario cancela.
  Future<ContenidoArchivo?> elegirArchivo();
}
