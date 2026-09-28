import 'package:flutter/material.dart';

import '../../../theme/insuma_colors.dart';
import '../../../utils/agenda_recurrente.dart';
import '../../../utils/fecha_recepcion.dart';

/// Elige el día del mes de una agenda mensual (HU-013).
///
/// **Grilla de 1 a 31 en 7 columnas, y no un mes real.** Dos motivos:
///  • una grilla NO PUEDE producir un día inválido. `DateTime(2026, 3, 0)`
///    devuelve EN SILENCIO el 28 de febrero, y un campo numérico deja tipear
///    "0" y "35"; acá esa clase entera de entrada mala es inalcanzable;
///  • con 7 columnas, cuatro filas cubren 1..28 y el 29/30/31 queda SOLO en su
///    propia fila, sin ningún día seguro mezclado. El dibujo cuenta por sí
///    mismo que esos tres son "los que sobran".
///
/// Que no se lea como un calendario real se resuelve con lo que NO tiene:
/// encabezados de días, nombre de mes, y sobre todo huecos — un mes de verdad
/// casi nunca arranca en la primera celda, y ésta arranca a ras.
///
/// La franja de abajo NO es decorativa. Para el día 30 las próximas tres
/// entregas son 30/08, 30/09 y 30/10: las tres limpias, y el primer corrimiento
/// recién en la séptima. O sea que "mostrar las próximas fechas" no alcanza
/// para enseñar la regla: por eso va además la línea que nombra el primer mes
/// que se corre.
class SelectorDiaMes extends StatelessWidget {
  /// Día elegido (1..31), o `null` si todavía no se eligió ninguno.
  final int? valor;

  final ValueChanged<int> onCambiar;

  /// Desde cuándo se proyectan las fechas de la vista previa. Inyectable para
  /// poder testear el widget sin depender del día en que corra la suite.
  final DateTime hoy;

  final bool habilitado;

  const SelectorDiaMes({
    super.key,
    required this.valor,
    required this.onCambiar,
    required this.hoy,
    this.habilitado = true,
  });

  /// Los días que pueden correrse al mes siguiente.
  static bool riesgoso(int dia) => dia >= 29;

  static const _meses = [
    'enero',
    'febrero',
    'marzo',
    'abril',
    'mayo',
    'junio',
    'julio',
    'agosto',
    'septiembre',
    'octubre',
    'noviembre',
    'diciembre',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Día del mes',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 8),
        // Sin tope, en una pantalla ancha las 7 celdas se estiran y la grilla
        // se ve deforme.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: GridView.builder(
            shrinkWrap: true,
            // Scrollea el slide, no la grilla: si no, en Chrome la rueda del
            // mouse queda peleando entre las dos.
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
              mainAxisExtent: 44,
            ),
            itemCount: 31,
            itemBuilder: (_, i) => _celda(i + 1),
          ),
        ),
        if (valor != null && riesgoso(valor!)) ...[
          const SizedBox(height: 10),
          _avisoDeCorrimiento(valor!),
        ],
        const SizedBox(height: 12),
        _vistaPrevia(),
      ],
    );
  }

  Widget _celda(int dia) {
    final elegido = valor == dia;
    final riesgo = riesgoso(dia);

    final fondo = elegido
        ? InsumaColors.primaryBlue
        : (riesgo ? Colors.orange.shade50 : Colors.grey[100]);
    final texto = elegido
        ? Colors.white
        : (riesgo ? Colors.orange.shade900 : Colors.black87);

    return Semantics(
      label: 'Día $dia del mes',
      selected: elegido,
      child: InkWell(
        key: ValueKey('dia_mes_$dia'),
        borderRadius: BorderRadius.circular(10),
        onTap: habilitado ? () => onCambiar(dia) : null,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fondo,
            borderRadius: BorderRadius.circular(10),
            // El ámbar NO se apaga al elegir: si se apagara, la señal de riesgo
            // desaparecería justo cuando el usuario se compromete con la
            // opción riesgosa.
            border: riesgo
                ? Border.all(
                    color: elegido
                        ? Colors.orange.shade400
                        : Colors.orange.shade200,
                    width: elegido ? 2 : 1,
                  )
                : null,
          ),
          child: Text(
            '$dia',
            style: TextStyle(
              fontSize: 13,
              fontWeight: elegido ? FontWeight.bold : FontWeight.normal,
              color: texto,
            ),
          ),
        ),
      ),
    );
  }

  Widget _avisoDeCorrimiento(int dia) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: InsumaColors.alertYellow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: Colors.orange.shade900),
          const SizedBox(width: 8),
          Expanded(
            // Una sola plantilla, verdadera para 29, 30 y 31. Y en criollo: ni
            // "desborde", ni "normalización", ni "clamp".
            child: Text(
              'Hay meses que no llegan al día $dia. Cuando pasa, la entrega se '
              'corre a los primeros días del mes siguiente.',
              style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
            ),
          ),
        ],
      ),
    );
  }

  Widget _vistaPrevia() {
    // La franja NO se oculta cuando no hay día elegido: aparecer y desaparecer
    // haría saltar el layout justo mientras el usuario elige.
    if (valor == null) {
      return const Text(
        'Elegí un día para ver cuándo llegarían los pedidos.',
        style: TextStyle(fontSize: 12, color: Colors.black45),
      );
    }

    final config = ConfigRecurrencia(
      tipo: TipoFrecuencia.mensual,
      diaMes: valor,
      fechaInicio: FechaRecepcion.soloDia(hoy),
    );
    final fechas = AgendaRecurrente.proximas(config, desde: hoy, cantidad: 3);
    final desborde = AgendaRecurrente.primerDesborde(valor!, desde: hoy);
    // Si alguna de las tres fechas visibles YA se corrió —su día no es el
    // elegido— el corrimiento se ve solo y la línea "Más adelante" sobra.
    final yaSeVe = fechas.any((f) => f.day != valor);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Próximas entregas',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 4),
        for (final f in fechas)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '•  ${FechaRecepcion.formatear(f)}'
              '${f.day != valor ? '  — ${_meses[_mesPrevio(f)]} no tiene $valor' : ''}',
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ),
        if (desborde != null && !yaSeVe) ...[
          const SizedBox(height: 6),
          Text(
            'Más adelante: ${_meses[desborde.mes - 1]} de ${desborde.anio} no '
            'tiene $valor, así que esa entrega cae el '
            '${FechaRecepcion.formatear(desborde.real)}.',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ],
    );
  }

  /// El mes que se quedó corto es el ANTERIOR al que muestra la fecha corrida:
  /// "01/10" salió de que septiembre no tiene 31.
  static int _mesPrevio(DateTime corrida) =>
      corrida.month == 1 ? 11 : corrida.month - 2;
}
