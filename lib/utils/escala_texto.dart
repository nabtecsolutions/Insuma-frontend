import 'package:flutter/material.dart';

import '../models/preferencias/tamano_tipografia.dart';

/// Combina el tamaño de letra del SISTEMA con la preferencia elegida en INSUMA
/// (HU-054).
///
/// El camino corto sería `TextScaler.linear(preferencia.factor)`, y es el que
/// sale escribir sin pensarlo. Pero eso DESCARTA el ajuste de accesibilidad del
/// sistema operativo: alguien con baja visión que puso letra grande en todo el
/// teléfono abriría INSUMA y la vería chica de nuevo, sin entender por qué esta
/// app y no las otras.
///
/// Componer respeta las dos intenciones: el sistema fija la línea de base para
/// todas las apps, y la preferencia de INSUMA ajusta desde ahí.
TextScaler escalaDeTexto({
  required TextScaler delSistema,
  required TamanoTipografia preferencia,
}) {
  if (preferencia.factor == 1.0) return delSistema;
  return _EscalaCompuesta(delSistema, preferencia.factor);
}

/// Aplica [escalaDeTexto] a todo su subárbol.
///
/// Existe como widget con nombre, y no como un `MediaQuery` suelto dentro del
/// `builder` del `MaterialApp`, para que el cableado sea testeable: sustituirlo
/// por un `TextScaler.linear(factor)` —que descarta el ajuste del sistema— es
/// un cambio de una línea que, sin este widget, ningún test podría atrapar.
class EscaladorDeTexto extends StatelessWidget {
  const EscaladorDeTexto({
    super.key,
    required this.preferencia,
    required this.child,
  });

  final TamanoTipografia preferencia;
  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: escalaDeTexto(
        delSistema: MediaQuery.textScalerOf(context),
        preferencia: preferencia,
      ),
    ),
    child: child,
  );
}

/// Escalador que aplica [factor] sobre el resultado de [base].
///
/// Se implementa a mano porque `TextScaler` no ofrece composición: `linear`
/// reemplaza y `clamp` acota, pero ninguno multiplica sobre lo que el sistema
/// venía aplicando. Delegar en [base] además preserva el escalado NO LINEAL que
/// Android usa en los tamaños grandes (agranda menos los títulos que el cuerpo),
/// cosa que un factor plano perdería.
class _EscalaCompuesta extends TextScaler {
  const _EscalaCompuesta(this.base, this.factor);

  final TextScaler base;
  final double factor;

  /// Escala compuesta: lo que pidió el sistema, ajustado por la preferencia.
  ///
  /// **Sin tope sobre el total, y es un compromiso elegido, no un olvido.**
  ///
  /// Un tope no puede cumplir a la vez las tres cosas que uno querría:
  ///
  /// 1. **Monotonía** — elegir un tamaño mayor nunca debe achicar, y las cuatro
  ///    opciones deben verse distintas.
  /// 2. **No regresión** — nunca quedar por debajo de lo que el sistema pidió;
  ///    quien puso la letra del teléfono en 3,1x ya veía la app así ANTES de
  ///    esta HU.
  /// 3. **Cota superior** — que el total no pase de un techo fijo.
  ///
  /// Con un techo T: por encima de T sólo se puede devolver T (rompe 1: todas
  /// las opciones colapsan) o devolver el del sistema (rompe 3). Y si "Normal"
  /// pasa de largo pero "Grande" se recorta, elegir "Grande" ACHICA (rompe 1 de
  /// la peor manera). Hubo un tope de 2x en un commit anterior y cayó justo ahí:
  /// con el sistema en 2x, "Normal", "Grande" y "Muy grande" renderizaban
  /// idéntico y el panel quedaba muerto para quien más lo necesita.
  ///
  /// Se eligen 1 y 2. Lo que sí queda acotado es el aporte de la app:
  /// [TamanoTipografia] limita su factor a [0,85 – 1,3], así que INSUMA nunca
  /// agrega más de un 30% sobre lo que el sistema ya dictaba. La robustez del
  /// layout ante escalas extremas es un problema aparte y anterior —la app ya
  /// recibía el 3,1x de iOS tal cual—, y se arregla en el layout, no recortando
  /// acá lo que el usuario pidió.
  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  // `textScaleFactor` está deprecado en Flutter (asume escalado lineal), pero
  // `TextScaler` lo declara abstracto: hay que implementarlo igual.
  //
  // Se DERIVA de `scale` en vez de multiplicar `base.textScaleFactor`, que
  // Flutter documenta como un token opaco de comparación, no apto para
  // aritmética: en Android 14+ el escalado es no lineal, así que el producto no
  // se corresponde con lo que `scale` mide de verdad. Derivándolo, las dos APIs
  // dicen lo mismo.
  @Deprecated('Sólo para satisfacer el contrato de TextScaler. Usar scale().')
  @override
  double get textScaleFactor =>
      scale(_tamanoDeReferencia) / _tamanoDeReferencia;

  /// Tamaño base de Material sobre el que se mide el factor equivalente.
  static const double _tamanoDeReferencia = 14.0;

  @override
  bool operator ==(Object other) =>
      other is _EscalaCompuesta && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);

  @override
  String toString() => 'sistema($base) × app($factor)';
}
