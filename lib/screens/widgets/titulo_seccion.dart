import 'package:flutter/material.dart';

/// Encabezado de una sección dentro de una lista (#277).
///
/// Extraído de la copia privada de `pagos/pagos_screen.dart`. **Esa pantalla no
/// se migró a propósito**, ni las otras dos copias que existen
/// (`pagos/cuenta_corriente_screen.dart` y
/// `recurrentes/widgets/selector_insumos_agenda.dart`): la migración la hace la
/// HU que reescriba cada layout. Duplicación temporal y deliberada — tocar tres
/// pantallas ajenas "de paso por DRY" es cómo una HU de listado termina
/// rompiendo la de pagos.
class TituloSeccion extends StatelessWidget {
  final String texto;

  /// Cuántos elementos trae la sección. Se muestra al lado del título y no
  /// adentro del texto para que el rótulo siga siendo una constante: un título
  /// con el número embebido no se puede comparar ni testear por igualdad.
  ///
  /// `null` = sin contador, que es como lo usaba la copia original.
  final int? cantidad;

  const TituloSeccion(this.texto, {super.key, this.cantidad});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Row(
        children: [
          // `Flexible` y no `Expanded`: el título ocupa lo suyo y el contador
          // queda pegado, en vez de separarse hasta el otro borde. Y si el
          // título no entra —"Posteriores al 15/08" con la tipografía al
          // 1.3x— se acomoda en vez de desbordar (#180).
          Flexible(
            child: Text(
              texto,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ),
          if (cantidad != null) ...[
            const SizedBox(width: 6),
            Text(
              '($cantidad)',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }
}
