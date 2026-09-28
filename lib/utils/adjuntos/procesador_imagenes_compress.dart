import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';

import 'contenido_archivo.dart';
import 'procesador_imagenes.dart';

/// Implementación de [ProcesadorImagenes] basada en `flutter_image_compress`.
///
/// Es la ÚNICA clase que conoce el plugin de compresión; el resto de las capas
/// dependen solo de la interfaz. Los PDF se devuelven intactos.
class ProcesadorImagenesCompress implements ProcesadorImagenes {
  const ProcesadorImagenesCompress();

  @override
  Future<ContenidoArchivo> optimizar(
    ContenidoArchivo original, {
    int objetivoBytes = kObjetivoBytesImagen,
  }) async {
    // PDF o imagen ya liviana: no se toca.
    if (!original.esImagen || original.tamanioBytes <= objetivoBytes) {
      return original;
    }

    final formato = original.mimeType == 'image/png'
        ? CompressFormat.png
        : CompressFormat.jpeg;

    final comprimido = await FlutterImageCompress.compressWithList(
      original.bytes,
      quality: 70,
      format: formato,
    );
    final bytes = Uint8List.fromList(comprimido);

    // Si la compresión no mejoró (o falló devolviendo vacío), conserva el original.
    if (bytes.isEmpty || bytes.length >= original.tamanioBytes) return original;
    return original.copyWith(bytes: bytes);
  }
}
