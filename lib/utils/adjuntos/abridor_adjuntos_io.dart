import 'dart:io';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'abridor_adjuntos.dart';

AbridorAdjuntos crearAbridorAdjuntos() => const _AbridorIo();

/// Android/desktop: temporal + visor del sistema. Es el camino que el visor de
/// remitos ya tenía adentro; #234 lo mudó acá SIN cambios de comportamiento
/// para poder darle a web el suyo.
class _AbridorIo implements AbridorAdjuntos {
  const _AbridorIo();

  @override
  bool get abreEnPestana => false;

  @override
  Future<void> abrir(
    Uint8List bytes, {
    required String mimeType,
    required String nombreArchivo,
  }) async {
    final dir = await getTemporaryDirectory();
    final archivo = File(
      p.join(dir.path, nombreSeguroDeArchivo(nombreArchivo)),
    );
    await archivo.writeAsBytes(bytes, flush: true);
    final res = await OpenFilex.open(archivo.path, type: mimeType);
    if (res.type != ResultType.done) {
      throw Exception(res.message);
    }
  }
}
