import 'dart:io';

import 'reconocedor_texto.dart';
import 'reconocedor_texto_mlkit.dart';

/// Rama CON dart:io: ML Kit sólo existe en Android/iOS; el resto de las
/// plataformas io (Windows/macOS/Linux, y los tests) usan el null-object.
ReconocedorTexto crearReconocedorTexto() {
  if (Platform.isAndroid || Platform.isIOS) {
    return ReconocedorTextoMlKit();
  }
  return const ReconocedorTextoNoDisponible();
}
