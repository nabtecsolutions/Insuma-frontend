import 'package:flutter/material.dart';

import '../../../controllers/controlador_adjuntos.dart';
import '../../../controllers/controlador_procesar_recepcion.dart';
import '../../../theme/insuma_colors.dart';
import '../../../utils/formatos_entrada.dart';
import '../../../utils/iva.dart' as iva;
import '../../../utils/origen_precio.dart';
import '../../widgets/campo_numerico.dart';
import 'widgets/preview_factura_staged.dart';

/// Paso 2 de 3: el costo de cada insumo recibido.
///
/// Un panel desplegable por ítem con los cinco datos que pidió el PO —Subtotal
/// neto, Alícuota, P. neto unitario, P. unitario c/IVA y Subtotal c/IVA— de los
/// que se CARGAN dos (neto y alícuota) y el resto se deriva a la vista. La
/// cantidad es fija: viene de la recepción, acá se carga el precio.
class PasoDetalleItems extends StatelessWidget {
  final ControladorProcesarRecepcion ctrl;

  /// Los comprobantes staged del paso 1: el escaneo (HU-144) lee de ahí la
  /// primera imagen para sugerir los costos, y desde #255 se muestra de guía.
  final ControladorAdjuntos comprobantes;
  final double anchoMaximo;

  /// #255: degrada el visor de "todos los adjuntos" por rol (la decisión la
  /// aplica el Service; acá solo se transporta). Viene de la sesión, computado
  /// una vez en el wizard.
  final bool puedeVerFinanzas;

  const PasoDetalleItems({
    super.key,
    required this.ctrl,
    required this.comprobantes,
    required this.anchoMaximo,
    required this.puedeVerFinanzas,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: anchoMaximo),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // #255: la factura recién adjuntada, de guía para tipear los
              // precios, + acceso a todos los adjuntos del pedido (fallback
              // cuando no se distingue cuál es la factura).
              PreviewFacturaStaged(
                comprobantes: comprobantes,
                recepcionId: ctrl.recepcion.recepcionId,
                pedidoId: ctrl.recepcion.pedidoId,
                proveedorNombre: ctrl.recepcion.proveedorNombre,
                puedeVerFinanzas: puedeVerFinanzas,
              ),
              // Escaneo (HU-144), mudado de la recepción: acá es donde los
              // costos se cargan, así que acá es donde se sugieren.
              if (ctrl.puedeEscanear) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: ctrl.escaneando
                        ? null
                        : () => ctrl.escanearFactura(comprobantes),
                    icon: ctrl.escaneando
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.auto_awesome,
                            size: 16,
                            color: Colors.amber,
                          ),
                    label: const Text(
                      'Escanear factura (sugerir costos)',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                if (ctrl.avisoOcr != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Text(
                      ctrl.avisoOcr!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.orange,
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
              ],
              for (final linea in ctrl.lineas)
                _PanelItem(ctrl: ctrl, linea: linea),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelItem extends StatelessWidget {
  final ControladorProcesarRecepcion ctrl;
  final LineaCostoEditable linea;

  const _PanelItem({required this.ctrl, required this.linea});

  @override
  Widget build(BuildContext context) {
    final l = linea.comoLineaCosto;
    return Card(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: InsumaColors.cardBorderLight),
      ),
      child: ExpansionTile(
        // Sin key por índice a propósito: el estado expandido es efímero y el
        // dato REAL vive en el controlador, así que colapsar no pierde nada.
        shape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        title: Text(
          linea.nombre,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        subtitle: Text(
          // La cantidad FIJA a la vista, y el estado de carga del renglón: es
          // lo que se ve sin abrir el panel.
          linea.completa
              ? '${linea.cantidad} ${linea.unidad} · '
                    'Subtotal c/IVA: \$${l.subtotalBruto.toStringAsFixed(2)}'
                    '${linea.origenPrecio == OrigenPrecio.compraOcr ? ' · sugerido por escaneo' : ''}'
              : '${linea.cantidad} ${linea.unidad} · sin costo cargado',
          style: TextStyle(
            fontSize: 11,
            color: linea.completa ? Colors.grey : Colors.orange[800],
          ),
        ),
        children: [
          // Cómo se carga: unitario (default del PO) o total de la línea.
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11)),
            ),
            segments: const [
              ButtonSegment(value: false, label: Text('Por unitario')),
              ButtonSegment(value: true, label: Text('Por total')),
            ],
            selected: {linea.cargaPorTotal},
            onSelectionChanged: (s) => ctrl.cambiarModoCarga(linea, s.first),
          ),
          const SizedBox(height: 8),
          if (!linea.cargaPorTotal)
            CampoNumerico(
              // La key incluye el modo: al alternar unitario↔total el campo se
              // rearma con el valor derivado y no con el texto viejo.
              key: ValueKey(
                'neto_unit_${linea.insumoId}_${linea.cargaPorTotal}'
                '_${ctrl.escaneos}',
              ),
              etiqueta: 'P. neto unitario',
              prefijo: r'$',
              valorInicial: linea.netoUnitario,
              decimales: FormatosEntrada.decimalesDinero,
              obligatorio: false,
              permitirCero: true,
              denso: true,
              estilo: const TextStyle(fontSize: 13, color: Colors.black87),
              alCambiar: (v) => ctrl.cambiarNetoUnitario(linea, v),
            )
          else
            CampoNumerico(
              key: ValueKey(
                'neto_total_${linea.insumoId}_${linea.cargaPorTotal}'
                '_${ctrl.escaneos}',
              ),
              etiqueta: 'Subtotal neto de la línea',
              prefijo: r'$',
              valorInicial: linea.completa ? l.subtotalNeto : null,
              decimales: FormatosEntrada.decimalesDinero,
              obligatorio: false,
              permitirCero: true,
              denso: true,
              estilo: const TextStyle(fontSize: 13, color: Colors.black87),
              ayuda: 'Se divide por la cantidad para obtener el unitario.',
              alCambiar: (v) => ctrl.cambiarTotalNetoLinea(linea, v),
            ),
          const SizedBox(height: 8),
          // La alícuota: las cuatro de la casa, 21% por defecto.
          DropdownButtonFormField<double>(
            initialValue: linea.alicuota,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Alícuota IVA',
              isDense: true,
            ),
            items: [
              for (final a in iva.alicuotas)
                DropdownMenuItem(
                  value: a.fraccion,
                  child: Text(a.etiqueta, style: const TextStyle(fontSize: 13)),
                ),
            ],
            onChanged: (v) {
              if (v != null) ctrl.cambiarAlicuota(linea, v);
            },
          ),
          const SizedBox(height: 8),
          // Los derivados, a la vista mientras se carga. Wrap: a 360 dp las
          // cuatro cifras no entran en una línea.
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              _derivado('Subtotal neto', l.subtotalNeto),
              _derivado('P. unit. c/IVA', l.brutoUnitario),
              _derivado('IVA', l.iva),
              _derivado('Subtotal c/IVA', l.subtotalBruto),
            ],
          ),
        ],
      ),
    );
  }

  Widget _derivado(String etiqueta, double valor) => Text(
    '$etiqueta: \$${valor.toStringAsFixed(2)}',
    style: const TextStyle(fontSize: 11, color: Colors.black54),
  );
}
