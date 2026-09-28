/// Verifica que los tests DETECTEN los bugs que dicen cubrir.
///
/// Por cada entrada de [mutaciones]: rompe el arreglo, corre el test que
/// debería cazarlo, y exige que **falle**. Si pasa igual, el test es
/// tautológico y lo dice con nombre y apellido.
///
///     dart run tool/verificar_mutaciones.dart            # todas
///     dart run tool/verificar_mutaciones.dart c02-       # las que empiecen así
///
/// El archivo original se restaura SIEMPRE, incluso si el runner se cae o lo
/// matan con Ctrl-C.
library;

import 'dart:io';

import 'mutaciones.dart';

Future<void> main(List<String> args) async {
  // OJO: Dart IGNORA el valor devuelto por main() — hay que asignar
  // `exitCode` a mano. Con el `return 1` de antes, una corrida con
  // mutaciones NO detectadas terminaba igual con exit 0: el CI daba verde
  // con el arnés roto, que es exactamente lo que este tool existe para
  // impedir (se descubrió porque 248-el-pull-vuelve-a-bajar-las-fotos
  // quedó viva y la corrida "pasó").
  exitCode = await _correr(args);
}

Future<int> _correr(List<String> args) async {
  final filtro = args.isEmpty ? '' : args.first;
  final aCorrer = mutaciones.where((m) => m.nombre.startsWith(filtro)).toList();

  if (aCorrer.isEmpty) {
    stderr.writeln('Ninguna mutación coincide con "$filtro".');
    return 2;
  }

  final fallas = <String>[];
  for (final m in aCorrer) {
    stdout.writeln('── ${m.nombre}');
    final archivo = File(m.archivo);
    if (!archivo.existsSync()) {
      fallas.add('${m.nombre}: no existe ${m.archivo}');
      continue;
    }
    // Que el ancla siga siendo única es la mitad del control: si el arreglo se
    // movió, la mutación quedó obsoleta y ya no está verificando nada. La
    // revisión vive en `revisarAncla` (mutaciones.dart) y la comparte el test
    // `test/mutaciones_vigentes_test.dart`, que la corre en SEGUNDOS dentro de
    // la suite normal. Así una mutación obsoleta rompe en la máquina de quien
    // la dejó obsoleta, y no nueve minutos después en un tablero que nadie
    // mira: la 234 estuvo huérfana 8 días por eso (2026-09-07 al 15).
    final problema = revisarAncla(m);
    if (problema != null) {
      fallas.add(problema);
      continue;
    }

    final original = archivo.readAsStringSync();

    // Las anclas se escriben con saltos LF en el catálogo, pero TODOS los
    // fuentes de este repo están en CRLF. Sin esta traducción, cualquier ancla
    // de más de una línea no matchea nunca y la mutación se reporta como
    // "obsoleta" aunque el arreglo esté intacto — pasó con tres de C-02.
    //
    // El diagnóstico es engañoso en las dos direcciones: en un CI Linux (LF)
    // esas mismas mutaciones funcionan, así que el arnés se ve sano justo donde
    // nadie desarrolla y se rompe en las máquinas donde sí.
    //
    // Se traduce el ANCLA al formato del archivo y no al revés: normalizar el
    // archivo lo dejaría reescrito con otros finales de línea en cada corrida,
    // y el verificador ensuciaría el diff de quien lo corre.
    final usaCrlf = original.contains('\r\n');
    String alFormatoDelArchivo(String texto) =>
        usaCrlf ? texto.replaceAll('\n', '\r\n') : texto;
    final buscar = alFormatoDelArchivo(m.buscar);
    final reemplazar = alFormatoDelArchivo(m.reemplazar);

    try {
      archivo.writeAsStringSync(original.replaceFirst(buscar, reemplazar));
      final r = await Process.run('flutter', [
        'test',
        m.test,
      ], runInShell: true);
      if (r.exitCode == 0) {
        fallas.add(
          '${m.nombre}: ${m.test} PASA con el bug reintroducido.\n'
          '    Bug: ${m.porque}\n'
          '    El test no está cubriendo lo que dice cubrir.',
        );
        stdout.writeln('   ✗ el test pasó igual');
      } else {
        stdout.writeln('   ✓ el test lo detectó');
      }
    } finally {
      archivo.writeAsStringSync(original);
    }
  }

  stdout.writeln('');
  if (fallas.isEmpty) {
    stdout.writeln('Las ${aCorrer.length} mutaciones fueron detectadas.');
    return 0;
  }
  stderr.writeln('MUTACIONES NO DETECTADAS (${fallas.length}):\n');
  for (final f in fallas) {
    stderr.writeln('  • $f\n');
  }
  return 1;
}
