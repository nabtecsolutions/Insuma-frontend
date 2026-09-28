import 'package:flutter/material.dart';

import '../../../controllers/controlador_procesar_recepcion.dart';
import '../../../theme/insuma_colors.dart';
import '../../../utils/formatos_entrada.dart';
import '../../widgets/campo_numerico.dart';

/// Paso 3 de 3: la vista previa y el Finalizar (que vive en la botonera).
///
/// Muestra los renglones cargados, el total manual (HU-143: pisa la deuda,
/// nunca el costeo), el aviso comparativo contra lo estimado al recibir y el
/// switch de efectivo — editable por el admin (decisión del PO, 2026-08-27):
/// quien mira el comprobante al final es quien mejor puede corregir la marca.
class PasoConfirmacion extends StatelessWidget {
  final ControladorProcesarRecepcion ctrl;
  final double anchoMaximo;

  const PasoConfirmacion({
    super.key,
    required this.ctrl,
    required this.anchoMaximo,
  });

  @override
  Widget build(BuildContext context) {
    final numero = ctrl.numeroFactura.trim();
    final estimado = ctrl.recepcion.montoRecibido;
    final difiere = (ctrl.totalFactura - estimado).abs() > 0.001;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: anchoMaximo),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                numero.isEmpty
                    ? 'Sin factura del proveedor (queda como S/F)'
                    : 'Factura $numero',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              Text(
                'Vence: ${_fecha(ctrl.fechaVencimiento)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              // Los renglones, uno por línea: lo que el Finalizar va a escribir
              // como detalle de la factura y como costo de cada insumo.
              Card(
                color: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: InsumaColors.cardBorderLight),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final linea in ctrl.lineas) _renglon(linea),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // HU-143: el total escrito a mano PISA el total de la factura —
              // la diferencia (flete, percepciones, redondeos) es deuda con el
              // proveedor, no costo de mercadería. Los costos por insumo salen
              // SIEMPRE de los renglones de arriba.
              CampoNumerico(
                etiqueta: 'Total facturado (si difiere de la suma)',
                prefijo: r'$',
                valorInicial: ctrl.totalManual,
                decimales: FormatosEntrada.decimalesDinero,
                obligatorio: false,
                permitirCero: true,
                denso: true,
                estilo: const TextStyle(fontSize: 13, color: Colors.black87),
                ayuda:
                    'Vacío: vale la suma de los renglones. Si lo escribís, '
                    'manda sobre la deuda; los costos por insumo no cambian.',
                alCambiar: ctrl.cambiarTotalManual,
              ),
              if (difiere) ...[
                const SizedBox(height: 8),
                // Aviso comparativo, SIN bloquear (decisión A6): el detalle por
                // renglón ya es la justificación que antes se pedía tipear.
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.10),
                    border: Border.all(color: Colors.amber),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'El total (\$${ctrl.totalFactura.toStringAsFixed(2)}) '
                    'difiere de lo estimado al recibir '
                    '(\$${estimado.toStringAsFixed(2)}). El estimado usaba los '
                    'precios del pedido; vale el que cargaste acá.',
                    style: const TextStyle(fontSize: 11, color: Colors.black87),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Pagada en efectivo al recibir',
                  style: TextStyle(fontSize: 13, color: Colors.black87),
                ),
                subtitle: Text(
                  ctrl.pagadoEnEfectivo
                      ? 'Al finalizar queda asentado el pago (fecha: la de la '
                            'recepción) y el pedido pasa a PAGADO.'
                      : 'La factura queda pendiente y se paga desde Pagos.',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                value: ctrl.pagadoEnEfectivo,
                onChanged: ctrl.cambiarPagadoEnEfectivo,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _renglon(LineaCostoEditable linea) {
    final l = linea.comoLineaCosto;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        children: [
          Text(
            '${linea.nombre} · ${linea.cantidad} ${linea.unidad} × '
            '\$${l.netoUnitario.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 12, color: Colors.black87),
          ),
          Text(
            '\$${l.subtotalBruto.toStringAsFixed(2)}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  String _fecha(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}
