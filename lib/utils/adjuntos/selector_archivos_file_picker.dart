import 'package:file_picker/file_picker.dart';

import 'contenido_archivo.dart';
import 'selector_archivos.dart';

/// Implementación de [SelectorArchivos] basada en `file_picker`.
///
/// Es la ÚNICA clase que conoce el plugin de selección de archivos. Pide los bytes
/// (`withData: true`) para no depender de un path local (coherente offline-first y
/// multi-dispositivo: el archivo se persiste, no se referencia por ruta).
class SelectorArchivosFilePicker implements SelectorArchivos {
  const SelectorArchivosFilePicker();

  static const List<String> _extensiones = ['pdf', 'jpg', 'jpeg', 'png'];

  @override
  Future<ContenidoArchivo?> elegirArchivo() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _extensiones,
      withData: true,
    );
    if (res == null || res.files.isEmpty) return null;

    final archivo = res.files.first;
    final bytes = archivo.bytes;
    if (bytes == null) return null;

    return ContenidoArchivo(
      bytes: bytes,
      nombreArchivo: archivo.name,
      mimeType: _mimeDeExtension(archivo.extension),
    );
  }

  /// Deriva el MIME a partir de la extensión (file_picker no lo provee directo).
  String _mimeDeExtension(String? ext) {
    switch (ext?.toLowerCase()) {
      case 'pdf':
        return 'application/pdf';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      default:
        return 'application/octet-stream';
    }
  }
}
