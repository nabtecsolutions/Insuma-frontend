import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'visor_pdf_embebido.dart';

VisorPdfEmbebido crearVisorPdfEmbebido() => const _VisorPdfInerte();

/// Android/desktop: no hay embebido (#258). El PDF se sigue abriendo con la app
/// del sistema por el [AbridorAdjuntos], como antes de #258 — el alcance de la
/// HU es sólo web (donde el PO reportó "abre en pestaña aparte"). Un embebido
/// nativo acá necesitaría una librería de render (pdfium/pdfrx); si el PO lo
/// pide, va como HU aparte y esta clase deja de devolver `false`.
///
/// [construir] nunca se llama con [puedeEmbeber] en `false`, pero devuelve un
/// widget vacío por contrato (no lanza) para no volver frágil al llamador.
class _VisorPdfInerte implements VisorPdfEmbebido {
  const _VisorPdfInerte();

  @override
  bool get puedeEmbeber => false;

  @override
  Widget construir(Uint8List bytes, {required String nombreArchivo}) =>
      const SizedBox.shrink();
}
