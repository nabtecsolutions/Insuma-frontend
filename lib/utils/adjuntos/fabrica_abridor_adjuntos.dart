import 'abridor_adjuntos.dart';
import 'abridor_adjuntos_io.dart'
    if (dart.library.js_interop) 'abridor_adjuntos_web.dart'
    as impl;

export 'abridor_adjuntos.dart';

/// Fábrica del abridor de adjuntos (#234).
///
/// Import CONDICIONAL: compilando para web ni se mira la rama de
/// dart:io/open_filex (que allá no existen), y compilando para io ni se mira
/// la de package:web. Mismo patrón que `fabrica_reconocedor.dart` (HU-144).
AbridorAdjuntos crearAbridorAdjuntos() => impl.crearAbridorAdjuntos();
