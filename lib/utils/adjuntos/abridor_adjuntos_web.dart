import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'abridor_adjuntos.dart';

AbridorAdjuntos crearAbridorAdjuntos() => const _AbridorWeb();

/// Web: Blob → Object URL → pestaña nueva (#234).
///
/// Los bytes viven en el BLOB local (no hay URL remota que abrir), así que se
/// fabrica una URL de objeto y se le pide al navegador la pestaña. El
/// `window.open` tiene que salir del MISMO gesto del usuario o el bloqueador
/// de popups lo frena: los bytes ya están locales, el await previo es corto y
/// no rompe esa cadena.
class _AbridorWeb implements AbridorAdjuntos {
  const _AbridorWeb();

  @override
  bool get abreEnPestana => true;

  @override
  Future<void> abrir(
    Uint8List bytes, {
    required String mimeType,
    required String nombreArchivo,
  }) async {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final url = web.URL.createObjectURL(blob);
    final ventana = web.window.open(url, '_blank');
    // Revocar de inmediato rompería la pestaña recién abierta (el navegador
    // puede no haber terminado de cargar el recurso). 60 s alcanza de sobra y
    // libera los hasta 5 MB que la URL retiene.
    Timer(const Duration(seconds: 60), () => web.URL.revokeObjectURL(url));
    if (ventana == null) {
      throw Exception('El navegador bloqueó la pestaña nueva.');
    }
  }
}
