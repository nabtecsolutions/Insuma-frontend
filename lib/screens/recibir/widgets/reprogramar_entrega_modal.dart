import 'package:flutter/material.dart';

import '../../../database/database.dart';
import '../../../theme/insuma_colors.dart';
import '../../../utils/acciones_tarjeta_pedido.dart';
import '../../../utils/fecha_recepcion.dart';
import '../../widgets/campo_fecha.dart';

/// Diálogo para mover la fecha de entrega, o quitarla (#269).
///
/// ## Lo que NO hace, a propósito
///
/// No llama a `showDatePicker` por su cuenta: usa [CampoFecha], que ya resuelve
/// las dos cosas que este caso necesita y que son fáciles de rehacer mal.
///
///  • **Recorta la fecha inicial** al rango permitido. `showDatePicker` lanza
///    un assert si `initialDate` cae fuera de \[firstDate, lastDate\], y el caso
///    principal de esta pantalla —reprogramar una entrega VENCIDA— es
///    exactamente ése: su fecha vieja es anterior a hoy.
///  • **Trae el botón de quitar la fecha**, que acá es una acción legítima y no
///    un descarte.
///
/// Los límites salen de [FechaRecepcion] —hoy y hoy + 6 meses—, las mismas
/// reglas que el formulario del pedido. El Service las vuelve a validar: esto
/// es comodidad de la interfaz, no la barrera.
///
/// ## La advertencia
///
/// Aparece **sólo** cuando se deja la entrega sin fecha, y es obligatoria por
/// decisión del PO. Lo que avisa es contraintuitivo: quien saca la fecha suele
/// querer posponer la entrega, y el efecto es el contrario —la entrega sube a
/// la primera sección de Recepciones y deja de estar sujeta a la ventana de 7
/// días, así que pasa a verse siempre—. El texto vive en
/// `utils/acciones_tarjeta_pedido.dart`, con las demás reglas.
class ReprogramarEntregaModal extends StatefulWidget {
  final Pedido pedido;

  const ReprogramarEntregaModal({super.key, required this.pedido});

  @override
  State<ReprogramarEntregaModal> createState() =>
      _ReprogramarEntregaModalState();
}

class _ReprogramarEntregaModalState extends State<ReprogramarEntregaModal> {
  late DateTime? _fecha = widget.pedido.fechaRecepcionSolicitada;

  /// La fecha original, para poder decir si hubo cambio. Se congela al abrir:
  /// comparar contra `widget.pedido` funcionaría igual hoy, pero este diálogo
  /// no debería depender de que nadie le cambie el pedido abajo.
  late final DateTime? _original = widget.pedido.fechaRecepcionSolicitada;

  bool get _sinFecha => _fecha == null;
  bool get _huboCambio => _fecha != _original;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Cambiar fecha de entrega',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.pedido.proveedorNombre,
            style: const TextStyle(fontSize: 13, color: Colors.black87),
          ),
          const SizedBox(height: 4),
          Text(
            _original == null
                ? 'Hoy no tiene fecha.'
                : 'Hoy está para el ${FechaRecepcion.formatear(_original)}.',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 14),
          CampoFecha(
            etiqueta: 'Nueva fecha',
            valor: _fecha,
            primeraFecha: FechaRecepcion.minima(),
            ultimaFecha: FechaRecepcion.maxima(),
            textoVacio: 'Sin fecha',
            onCambiar: (f) => setState(() => _fecha = f),
          ),
          if (_sinFecha) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: InsumaColors.entregaSinFechaBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 14,
                    color: InsumaColors.entregaSinFechaFg,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      advertenciaQuitarFecha,
                      style: const TextStyle(
                        fontSize: 11,
                        color: InsumaColors.entregaSinFechaFg,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Volver'),
        ),
        TextButton(
          // Deshabilitado si no cambió nada: guardar lo mismo gastaría una
          // `version` y un lugar en el Outbox para nada.
          onPressed: _huboCambio
              ? () => Navigator.pop(context, _ResultadoReprogramar(_fecha))
              : null,
          child: Text(_sinFecha ? 'Quitar la fecha' : 'Guardar'),
        ),
      ],
    );
  }
}

/// Envoltorio del resultado.
///
/// Hace falta porque el valor elegido puede ser `null` —quitar la fecha— y un
/// `Navigator.pop(context, null)` es indistinguible de cerrar el diálogo sin
/// elegir nada. Sin esto, quitar la fecha se leería como "cancelé".
class _ResultadoReprogramar {
  final DateTime? fecha;
  const _ResultadoReprogramar(this.fecha);
}

/// Abre el diálogo y devuelve la fecha elegida, o `null` si se cerró sin
/// confirmar.
///
/// El `bool` del par dice si HUBO elección: `(true, null)` es "quitar la
/// fecha" y `(false, null)` es "se cerró el diálogo".
Future<(bool, DateTime?)> pedirNuevaFechaEntrega(
  BuildContext context,
  Pedido pedido,
) async {
  final r = await showDialog<_ResultadoReprogramar>(
    context: context,
    builder: (_) => ReprogramarEntregaModal(pedido: pedido),
  );
  return r == null ? (false, null) : (true, r.fecha);
}
