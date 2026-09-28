import 'package:flutter/material.dart';

import '../../../theme/insuma_colors.dart';

/// Elige uno o varios días de la semana para una agenda semanal (HU-013).
///
/// Devuelve los días con la convención de [DateTime.weekday] (1 = lunes … 7 =
/// domingo), que es la MISMA que usa `AgendaRecurrente`: así el widget no
/// traduce nada y no hay dónde equivocarse de origen.
///
/// Varios días son legítimos y esperados: "lunes y jueves" es el caso real que
/// el PO nombró. Pero eso es UNA serie, no dos —si no se recepciona la del
/// lunes, la del jueves no aparece—, y por eso la pantalla lo dice cuando hay
/// más de un día elegido.
class SelectorDiasSemana extends StatelessWidget {
  /// Días elegidos, 1..7 con la convención de [DateTime.weekday].
  final Set<int> valor;

  final ValueChanged<Set<int>> onCambiar;

  /// Si es `false` se ve pero no se toca (una agenda en modo consulta).
  final bool habilitado;

  const SelectorDiasSemana({
    super.key,
    required this.valor,
    required this.onCambiar,
    this.habilitado = true,
  });

  /// Índice = weekday - 1. Iniciales en vez de nombres completos: siete chips
  /// con "Miércoles" no entran en un teléfono sin romper en dos filas.
  static const _iniciales = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
  static const _nombres = [
    'lunes',
    'martes',
    'miércoles',
    'jueves',
    'viernes',
    'sábado',
    'domingo',
  ];

  /// "los martes" / "los martes y jueves" / "los lunes, miércoles y viernes".
  /// Se arma acá porque lo usan el subtítulo de este selector y el resumen del
  /// wizard, y tenían que decir exactamente lo mismo.
  static String describir(Set<int> dias) {
    if (dias.isEmpty) return '';
    final ordenados = dias.toList()..sort();
    final nombres = ordenados.map((d) => _nombres[d - 1]).toList();
    if (nombres.length == 1) return 'los ${nombres.single}';
    final ultimo = nombres.removeLast();
    return 'los ${nombres.join(", ")} y $ultimo';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '¿Qué días?',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [for (var i = 0; i < 7; i++) _chip(i + 1, _iniciales[i])],
        ),
        const SizedBox(height: 8),
        if (valor.isEmpty)
          const Text(
            'Elegí al menos un día.',
            style: TextStyle(fontSize: 12, color: Colors.redAccent),
          )
        else
          Text(
            'Se recibe ${describir(valor)}, todas las semanas.',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        // El PO lo pidió como UNA serie por agenda, así que conviene decirlo
        // antes de confirmar y no cuando el jueves no aparezca.
        if (valor.length > 1) ...[
          const SizedBox(height: 6),
          Text(
            'Son una sola serie: hasta que no recibas la entrega de un día, no '
            'se agenda la del siguiente. Si querés que corran por separado, '
            'creá un pedido recurrente para cada día.',
            style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
          ),
        ],
      ],
    );
  }

  /// Suma o saca [dia]. Siempre devuelve un Set NUEVO: el padre guarda la
  /// referencia en su estado, y mutar el que ya tiene haría que `setState` no
  /// vea ningún cambio.
  void _alternar(int dia) {
    final nuevos = Set<int>.from(valor);
    if (!nuevos.remove(dia)) nuevos.add(dia);
    onCambiar(nuevos);
  }

  Widget _chip(int dia, String inicial) {
    final elegido = valor.contains(dia);
    return Semantics(
      label: _nombres[dia - 1],
      selected: elegido,
      child: InkWell(
        // La key hace testeable el chip: en pantalla muestra una inicial y hay
        // dos "M" (martes y miércoles).
        key: ValueKey('dia_semana_$dia'),
        borderRadius: BorderRadius.circular(10),
        onTap: habilitado ? () => _alternar(dia) : null,
        child: Container(
          width: 40,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: elegido ? InsumaColors.primaryBlue : Colors.grey[100],
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            inicial,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: elegido ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }
}
