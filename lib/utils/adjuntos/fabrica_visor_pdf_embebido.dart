import 'visor_pdf_embebido.dart';
import 'visor_pdf_embebido_io.dart'
    if (dart.library.js_interop) 'visor_pdf_embebido_web.dart'
    as impl;

export 'visor_pdf_embebido.dart';

/// Fábrica del visor de PDF embebido (#258).
///
/// Import CONDICIONAL, igual que `fabrica_abridor_adjuntos.dart` (#234):
/// compilando para web ni se mira la rama io (que no embebe), y compilando para
/// io ni se mira la de `dart:ui_web`/`package:web`. La app la llama en `build`;
/// los tests inyectan un doble para fijar el despacho sin correr la rama web.
VisorPdfEmbebido crearVisorPdfEmbebido() => impl.crearVisorPdfEmbebido();
