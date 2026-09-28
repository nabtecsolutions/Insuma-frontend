import 'package:flutter/material.dart';

import '../../../controllers/controlador_adjuntos.dart';
import '../../../controllers/controlador_procesar_recepcion.dart';
import '../../../services/servicio_procesar_recepcion.dart';
import '../../../utils/formatos_entrada.dart';
import '../../recibir/widgets/selector_remito_widget.dart';
import '../../widgets/campo_fecha.dart';
import '../widgets/visor_remito.dart';

/// Paso 1 de 3: los datos de la factura.
///
/// Número (opcional en efectivo), UNA fecha de vencimiento (decisión del PO:
/// sin cuotas), acceso a los documentos que ya trae la recepción y el alta de
/// comprobantes nuevos. Los campos son CONTROLADOS desde el controlador del
/// wizard: el slide se desmonta al navegar y lo tipeado tiene que volver.
class PasoDatosFactura extends StatelessWidget {
  final ControladorProcesarRecepcion ctrl;
  final ControladorAdjuntos comprobantes;
  final double anchoMaximo;

  const PasoDatosFactura({
    super.key,
    required this.ctrl,
    required this.comprobantes,
    required this.anchoMaximo,
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
              // Ver lo que ya está: el remito (y la factura, si alguien la
              // adjuntó antes) de la recepción. SIEMPRE habilitado: el botón
              // existe justamente para mirar el papel mientras se carga.
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PantallaVisorRemito.deDocumentos(
                        documentosDeRecepcionId: ctrl.recepcion.recepcionId,
                        titulo:
                            'Documentos · ${ctrl.recepcion.proveedorNombre}',
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.attach_file, size: 16),
                  label: const Text(
                    'Ver remito y factura',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                // El valor vive en el controlador (sobrevive los slides); la
                // key fuerza rearmado si volviera a cambiar desde afuera.
                initialValue: ctrl.numeroFactura,
                inputFormatters: FormatosEntrada.alfanumerico(),
                style: const TextStyle(fontSize: 13, color: Colors.black87),
                decoration: InputDecoration(
                  labelText: ctrl.numeroEsOpcional
                      ? 'Número de factura (opcional en efectivo)'
                      : 'Número de factura *',
                  hintText: ctrl.numeroEsOpcional
                      ? 'Vacío: queda como '
                            '${ServicioProcesarRecepcion.numeroSinFactura(ctrl.recepcion.recepcionId)}'
                      : 'Ej.: A-0001-00001234',
                  isDense: true,
                ),
                onChanged: ctrl.cambiarNumero,
              ),
              const SizedBox(height: 12),
              CampoFecha(
                etiqueta: 'Vencimiento',
                valor: ctrl.fechaVencimiento,
                primeraFecha: DateTime(2020),
                ultimaFecha: DateTime(2100),
                permiteBorrar: false,
                onCambiar: (d) {
                  if (d != null) ctrl.cambiarVencimiento(d);
                },
              ),
              const SizedBox(height: 12),
              SelectorRemitoWidget(
                controlador: comprobantes,
                // #238: el rótulo dice lo que el archivo ES. En transferencia
                // (el caso típico) acá se adjunta la FACTURA del proveedor —
                // el comprobante de la transferencia va donde el pago ocurre:
                // "Registrar pago". Solo el efectivo asienta un pago acá.
                titulo: ctrl.pagadoEnEfectivo
                    ? 'Factura o comprobante de pago (archivo)'
                    : 'Factura del proveedor (archivo)',
                textoVacio: 'Sin archivos adjuntos.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: ctrl.comentario,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(fontSize: 13, color: Colors.black87),
                decoration: const InputDecoration(
                  labelText: 'Comentario (opcional)',
                  isDense: true,
                ),
                onChanged: ctrl.cambiarComentario,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
