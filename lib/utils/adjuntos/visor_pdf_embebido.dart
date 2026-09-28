import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Renderiza un PDF DENTRO del visor, sin sacarlo a otra pestaña ni a la app del
/// sistema (#258).
///
/// Es el punto de swap por plataforma, hermano de [AbridorAdjuntos] (#234): en
/// web se embebe el visor de PDF nativo del navegador (Blob → Object URL →
/// `<embed>` dentro de un `HtmlElementView`), sin sumar ninguna dependencia ni
/// tocar la caché del service worker; en Android/desktop no hay embebido y el
/// PDF sigue abriéndose con la app del sistema vía el abridor. La implementación
/// la elige un import condicional en `fabrica_visor_pdf_embebido.dart`, el mismo
/// patrón que el abridor y el OCR (interfaz y fábrica en archivos separados para
/// que ninguna plataforma importe código de la otra).
abstract class VisorPdfEmbebido {
  /// `true` cuando esta plataforma sabe embeber un PDF (hoy, sólo web). El visor
  /// consulta esto para decidir entre mostrar el PDF inline o caer al camino de
  /// "abrir afuera" de siempre.
  bool get puedeEmbeber;

  /// Widget que muestra el PDF de [bytes] embebido, ocupando el espacio que le
  /// den los padres (el visor lo pone en `Positioned.fill`; el preview de guía,
  /// en un `ConstrainedBox` de alto acotado). Sólo se llama cuando
  /// [puedeEmbeber] es `true`. [nombreArchivo] es metadato (título/descarga del
  /// visor nativo), no cambia el render.
  Widget construir(Uint8List bytes, {required String nombreArchivo});
}
