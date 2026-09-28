import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../adjuntos/contenido_archivo.dart';
import 'reconocedor_texto.dart';

/// Motor de reconocimiento ON-DEVICE con ML Kit (HU-144, costo $0).
///
/// Sólo Android/iOS (lo garantiza la fábrica). Gratis, offline y sin que el
/// remito salga del dispositivo (restricción del PO: costo $0 y sin datos del
/// negocio hacia terceros). Sólo imágenes: un PDF devuelve null y el flujo
/// manual sigue igual.
class ReconocedorTextoMlKit implements ReconocedorTexto {
  @override
  bool get disponible => true;

  @override
  Future<String?> reconocer(ContenidoArchivo archivo) async {
    if (!archivo.mimeType.startsWith('image/')) return null;
    File? temporal;
    TextRecognizer? recognizer;
    try {
      // ML Kit lee de un path de archivo: se materializan los bytes staged en
      // un temporal y se borra al final.
      final dir = await Directory.systemTemp.createTemp('insuma_ocr_');
      temporal = File('${dir.path}/${archivo.nombreArchivo}');
      await temporal.writeAsBytes(archivo.bytes, flush: true);

      recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final resultado = await recognizer.processImage(
        InputImage.fromFilePath(temporal.path),
      );
      final texto = resultado.text.trim();
      return texto.isEmpty ? null : texto;
    } catch (_) {
      // Criterio HU-144: si el reconocimiento falla, el flujo manual sigue
      // exactamente igual — nunca se propaga el error a la UI.
      return null;
    } finally {
      await recognizer?.close();
      try {
        await temporal?.parent.delete(recursive: true);
      } catch (_) {
        /* best-effort */
      }
    }
  }
}
