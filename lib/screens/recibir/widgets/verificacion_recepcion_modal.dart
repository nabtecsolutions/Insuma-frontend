import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../controllers/controlador_adjuntos.dart';
import '../../../constants/unidades.dart';
import '../../../utils/validador_datos.dart';
import '../../../database/database.dart';
import '../../../utils/desenlace_recepcion.dart';
import '../../../utils/formatos_entrada.dart';
import '../../../utils/sanitizador_texto.dart';
import '../../widgets/campo_numerico.dart';
import 'selector_remito_widget.dart';

/// Modal de verificación de recepción con DESENLACE por ítem (HU-064).
///
/// Por cada ítem el usuario elige Correcto / Diferencias / Rechazado, ajusta la
/// cantidad recibida, y agrega un comentario opcional (#251) o el motivo
/// (obligatorio en Rechazado). Abajo permite adjuntar el/los remito(s) (HU-066).
/// Es SOLO presentación + estado local: la validación de negocio y la persistencia
/// las hace el controlador a través de [onConfirmar].
///
/// #229: la recepción maneja SOLO cantidades. Acá ya no se editan precios ni se
/// escanea el comprobante — el costo por ítem (y el OCR que lo sugiere) viven en
/// la pantalla de PROCESAR, en Pagos, contra la factura de verdad. Lo único de
/// plata que queda es el total manual de HU-143, que es control de recepción
/// ("el remito dice tanto"), no costeo.
class VerificacionRecepcionModal extends StatefulWidget {
  final Pedido pedido;
  final List<MotivosRecepcionData> motivos;
  final ControladorAdjuntos controladorAdjuntos;
  final bool puedeVerFinanzas;

  /// Persiste la recepción. Devuelve `null` si salió bien (el modal se cierra) o un
  /// mensaje de error para mostrar. [totalManual] (HU-143): total escrito a mano
  /// según el remito, null si el usuario dejó valer el calculado. [nota] (HU-146):
  /// comentario libre de la recepción, null si quedó vacío. [pagarEfectivo]
  /// (#229): lo que quedó decidido EN LA ENTREGA — arranca en lo que marcó quien
  /// creó el pedido y quien recibe puede destildarlo si al final no se pagó en
  /// mano.
  final Future<String?> Function(
    List<Map<String, dynamic>> items,
    double totalFinal, {
    double? totalManual,
    String? nota,
    required bool pagarEfectivo,
  })
  onConfirmar;

  const VerificacionRecepcionModal({
    super.key,
    required this.pedido,
    required this.motivos,
    required this.controladorAdjuntos,
    required this.puedeVerFinanzas,
    required this.onConfirmar,
  });

  @override
  State<VerificacionRecepcionModal> createState() =>
      _VerificacionRecepcionModalState();
}

class _VerificacionRecepcionModalState
    extends State<VerificacionRecepcionModal> {
  late final List<Map<String, dynamic>> _items;

  /// Controller por ítem del campo "Recibido": necesario para que los resets de
  /// cantidad disparados desde el selector de desenlace (Correcto → pedida,
  /// Rechazado → 0) se reflejen en el texto visible del campo (HU-125).
  late final List<TextEditingController> _controllersCantidad;

  /// HU-143: total recibido escrito a mano (null = vale el calculado).
  double? _totalManual;

  /// HU-143/144: controller del total manual, para que el escaneo pueda
  /// precargarlo (y el usuario editarlo).
  final TextEditingController _controllerTotal = TextEditingController();

  /// HU-146: comentario libre de la recepción (además de los motivos por ítem).
  String _nota = '';

  /// #229: lo decidido sobre el efectivo EN ESTA entrega. Arranca en lo que
  /// marcó quien creó el pedido (un aviso: "llevá plata") y quien recibe lo
  /// puede destildar si al final no se pagó en mano. Es lo que viaja por
  /// [VerificacionRecepcionModal.onConfirmar] y lo que el servicio persiste.
  late bool _pagarEfectivo = widget.pedido.tieneEfectivo;

  bool _guardando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final lista = (jsonDecode(widget.pedido.items) as List)
        .cast<Map<String, dynamic>>();
    _items = lista.map((it) {
      final pedida = (it['cantidadPedida'] as num).toDouble();
      return <String, dynamic>{
        'insumoId': it['insumoId'],
        'nombre': it['nombre'],
        'unidad': it['unidad'],
        'cantidadPedida': pedida,
        // #263: arranca en 0 (double, NO null: aguas abajo se hace `as double`)
        // y en estado 'pendiente'. El usuario resuelve cada ítem tipeando la
        // cantidad o marcando "Correcto" (por ítem o con el botón global).
        'cantidadRecibida': 0.0,
        'precioUnitario': (it['precioUnitario'] as num).toDouble(),
        'estado': DesenlaceRecepcion.pendiente,
        'motivoId': null,
        'comentario': '',
      };
    }).toList();
    // #263: el campo "Recibido" arranca VACÍO (no "0.0"): así se distingue "no
    // tocado" de "recibí 0". Setear .text no dispara onChanged.
    _controllersCantidad = _items.map((_) => TextEditingController()).toList();
  }

  /// #263: marca el ítem [idx] como Correcto y autocompleta su cantidad pedida.
  /// Fija TAMBIÉN el estado (no sólo la cantidad): sin esto el ítem quedaría en
  /// 'pendiente' y no desbloquearía Confirmar. NO llama a setState — el llamador
  /// envuelve (el selector por ítem, o [_marcarTodoCorrecto] en lote).
  void _marcarCorrecto(int idx) {
    final item = _items[idx];
    final pedida = item['cantidadPedida'] as double;
    item['estado'] = DesenlaceRecepcion.correcto;
    item['cantidadRecibida'] = pedida;
    _controllersCantidad[idx].text = pedida.toString();
  }

  /// #263: marca TODOS los ítems como Correcto de una (autocompleta cada
  /// cantidad pedida). Atajo del header para la recepción que llegó completa.
  void _marcarTodoCorrecto() {
    setState(() {
      for (var i = 0; i < _items.length; i++) {
        _marcarCorrecto(i);
      }
    });
  }

  @override
  void dispose() {
    for (final c in _controllersCantidad) {
      c.dispose();
    }
    _controllerTotal.dispose();
    super.dispose();
  }

  double get _totalAceptado {
    double t = 0;
    for (final it in _items) {
      t +=
          DesenlaceRecepcion.aceptadaDeLinea(it) *
          (it['precioUnitario'] as double);
    }
    return t;
  }

  Future<void> _confirmar() async {
    setState(() {
      _guardando = true;
      _error = null;
    });
    // limpiarMultilinea conserva los saltos que el usuario ve en el campo.
    final nota = SanitizadorTexto.limpiarMultilinea(_nota);
    final error = await widget.onConfirmar(
      _items,
      _totalAceptado,
      totalManual: _totalManual,
      nota: nota.isEmpty ? null : nota,
      pagarEfectivo: _pagarEfectivo,
    );
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _guardando = false;
        _error = error;
      });
    }
    // Si error == null, el padre cierra el modal.
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
            top: 16,
            left: 20,
            right: 20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Verificación: ${widget.pedido.proveedorNombre}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const Text(
                'Indicá el desenlace de cada ítem y adjuntá el remito.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              // #263: los ítems ya no vienen pre-marcados. Este atajo marca todo
              // como Correcto (autocompleta las cantidades pedidas) para la
              // recepción que llegó completa; el resto se ajusta por ítem.
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _marcarTodoCorrecto,
                  icon: const Icon(Icons.done_all, size: 16),
                  label: const Text(
                    'Marcar todo correcto',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [
                    for (int i = 0; i < _items.length; i++) _tarjetaItem(i),
                    const SizedBox(height: 8),
                    // Comprobante (HU-066): OBLIGATORIO cuando entró mercadería.
                    // La regla cambió dos veces: #212 la sacó, #226 la repuso
                    // por decisión del cliente. La valida `validarRecepcion`.
                    SelectorRemitoWidget(
                      controlador: widget.controladorAdjuntos,
                    ),
                    // #229: el pedido vino marcado "en efectivo" (el aviso de
                    // llevar plata). Quien recibe confirma o DESTILDA según lo
                    // que pasó de verdad en la puerta. Sin gate de finanzas a
                    // propósito: es información operativa, no un precio.
                    //
                    // Sólo se muestra si el pedido traía la marca: ofrecerle
                    // "¿pagaste en efectivo?" a quien recibe un pedido normal
                    // sería invitar a marcarlo por error; si el aviso faltó y
                    // SÍ se pagó en mano, lo corrige el admin al procesar.
                    if (widget.pedido.tieneEfectivo) ...[
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Se pagó en efectivo al recibir',
                          style: TextStyle(fontSize: 13, color: Colors.black87),
                        ),
                        subtitle: const Text(
                          'Destildalo si al final no se pagó en mano.',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        value: _pagarEfectivo,
                        onChanged: (v) => setState(() => _pagarEfectivo = v),
                      ),
                    ],
                    // Comentario libre de la recepción (HU-146): queda asociado
                    // al evento y se ve en el detalle del pedido y el historial.
                    const SizedBox(height: 12),
                    TextFormField(
                      // El campo vive en un ListView lazy: si sale de vista sin
                      // foco, su estado se destruye. initialValue lo restaura
                      // desde _nota al reconstruirse (si no, el usuario vería
                      // el campo vacío pero la nota se persistiría igual).
                      initialValue: _nota,
                      maxLines: 2,
                      inputFormatters: FormatosEntrada.texto(
                        maxLongitud: SanitizadorTexto.maxLongitudNota,
                      ),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.black87,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Comentario de la recepción (opcional)',
                        hintText:
                            'Ej.: el proveedor avisó que repone el faltante el lunes',
                        isDense: true,
                      ),
                      onChanged: (v) => _nota = v,
                    ),
                    // Total manual (HU-143): sólo quien ve finanzas. Vacío ⇒
                    // vale el total calculado por líneas.
                    if (widget.puedeVerFinanzas) ...[
                      const SizedBox(height: 12),
                      CampoNumerico(
                        controlador: _controllerTotal,
                        etiqueta: 'Total recibido (según remito, opcional)',
                        prefijo: r'$',
                        decimales: FormatosEntrada.decimalesDinero,
                        obligatorio: false,
                        permitirCero: true,
                        denso: true,
                        estilo: const TextStyle(
                          fontSize: 13,
                          color: Colors.black87,
                        ),
                        ayuda:
                            'Si lo escribís, manda sobre el calculado y queda registrado a tu nombre.',
                        alCambiar: (v) => setState(() => _totalManual = v),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 20),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              // #215: `Wrap` y NO `Row`. Medido: desbordaba 287 px a 360 dp y
              // 236 px a 411 dp — o sea que en el teléfono de la cocina el
              // borde derecho se recortaba y el botón de confirmar quedaba
              // parcialmente fuera de alcance. Preexistente; nadie lo veía
              // porque las pruebas se hacen en Chrome con la ventana ancha.
              //
              // Wrap y no `Expanded` + elipsis (el otro patrón de la casa,
              // #209): acá el texto de la izquierda es un TOTAL, y un total
              // recortado con "…" pierde justo el dato que se está mirando.
              // Bajar el botón de renglón no pierde nada: conserva sus 48 dp
              // de alto y sigue siendo la acción principal.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (widget.puedeVerFinanzas)
                    // HU-143: si hay total manual, es el que se va a facturar.
                    Text(
                      _totalManual != null
                          ? 'Total (manual): \$${_totalManual!.toStringAsFixed(2)}'
                          : 'Total recibido: \$${_totalAceptado.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    )
                  else
                    const SizedBox.shrink(),
                  ElevatedButton(
                    onPressed: _guardando ? null : _confirmar,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: _guardando
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Confirmar Recepción'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tarjetaItem(int idx) {
    final item = _items[idx];
    final estado = item['estado'] as String;
    final pedida = item['cantidadPedida'] as double;
    final unidad = (item['unidad'] ?? '').toString();

    return Card(
      color: Colors.grey[50],
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              (item['nombre'] as String?) ?? 'Insumo',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Colors.black87,
              ),
            ),
            // #229: sin precio, ni siquiera para quien ve finanzas. El que
            // había acá era el INFORMATIVO del pedido, y mostrarlo en plena
            // verificación invitaba a leerlo como el costo real — que ahora se
            // carga en Pagos, contra la factura.
            Text(
              'Pedido: $pedida $unidad',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            // Selector de desenlace.
            SegmentedButton<String>(
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStateProperty.all(
                  const TextStyle(fontSize: 11),
                ),
              ),
              segments: const [
                ButtonSegment(
                  value: DesenlaceRecepcion.correcto,
                  label: Text('Correcto'),
                  icon: Icon(Icons.check, size: 14),
                ),
                ButtonSegment(
                  value: DesenlaceRecepcion.diferencia,
                  label: Text('Diferencias'),
                  icon: Icon(Icons.warning_amber, size: 14),
                ),
                ButtonSegment(
                  value: DesenlaceRecepcion.rechazado,
                  label: Text('Rechazado'),
                  icon: Icon(Icons.block, size: 14),
                ),
              ],
              // #263: en 'pendiente' no hay segmento resaltado. `emptySelectionAllowed`
              // permite además DESELECCIONAR (re-tocar el activo) para volver a
              // pendiente; sin él, `s.first` reventaría con el set vacío.
              emptySelectionAllowed: true,
              selected: estado == DesenlaceRecepcion.pendiente
                  ? const <String>{}
                  : {estado},
              onSelectionChanged: (s) => setState(() {
                if (s.isEmpty) {
                  // Re-tocar el segmento activo lo apaga: vuelve a 'pendiente'.
                  item['estado'] = DesenlaceRecepcion.pendiente;
                  item['cantidadRecibida'] = 0.0;
                  _controllersCantidad[idx].text = '';
                  return;
                }
                final nuevo = s.first;
                // Coherencia cantidad↔estado del override manual (HU-125): al
                // rechazar no entra nada; al marcar Correcto se asume lo pedido.
                // Setear .text NO dispara onChanged, así que no hay loop con la
                // derivación automática.
                if (nuevo == DesenlaceRecepcion.correcto) {
                  _marcarCorrecto(idx);
                } else {
                  item['estado'] = nuevo;
                  if (nuevo == DesenlaceRecepcion.rechazado) {
                    item['cantidadRecibida'] = 0.0;
                    _controllersCantidad[idx].text = '0.0';
                  }
                }
              }),
            ),
            const SizedBox(height: 6),
            // Cantidad recibida. SIEMPRE visible (HU-125): si se ocultara en
            // Rechazado, desaparecería a mitad de tipeo al pasar por 0 (p. ej.
            // escribiendo "0.5"), porque el estado se deriva de lo ingresado.
            SizedBox(
              // #214: 140 -> 210 por LEGIBILIDAD, no por desborde. A 140 no
              // revienta —el campo se comprime— pero los dos botones se comen 64
              // px y al número con su sufijo le quedan menos de 80. Medido.
              width: 210,
              // HU-137: el campo ya no admite letras. Vaciarlo sigue valiendo 0,
              // que acá es información real ("no llegó nada de este ítem") y es
              // lo que el desenlace de HU-125 interpreta como rechazado.
              child: CampoNumerico(
                controlador: _controllersCantidad[idx],
                etiqueta: 'Recibido',
                sufijo: unidad,
                // #214: los decimales dependen de la UNIDAD y del valor ya
                // cargado: un ítem histórico con 2,5 u se respeta en vez de
                // redondearse. Redondear cambia una cantidad que alguien cargó.
                decimales: decimalesDeCantidad(
                  unidad,
                  ValidadorDatos.parsearNumero(_controllersCantidad[idx].text),
                ),
                paso: 1,
                obligatorio: false,
                permitirCero: true,
                denso: true,
                estilo: const TextStyle(fontSize: 13, color: Colors.black87),
                alCambiar: (v) => setState(() {
                  final recibida = v ?? 0.0;
                  item['cantidadRecibida'] = recibida;
                  // HU-125: el desenlace se deriva automáticamente de lo ingresado;
                  // el usuario puede sobreescribirlo con el selector (HU-064).
                  item['estado'] = DesenlaceRecepcion.derivarEstadoItem(
                    pedida,
                    recibida,
                  );
                }),
              ),
            ),
            // Motivo: opcional tanto en Rechazado como en Diferencias (#265).
            if ((estado == DesenlaceRecepcion.rechazado ||
                    estado == DesenlaceRecepcion.diferencia) &&
                widget.motivos.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'No hay motivos cargados. Pedí al admin que los configure en «Motivos de recepción».',
                  style: TextStyle(fontSize: 11, color: Colors.orange),
                ),
              )
            else if (estado == DesenlaceRecepcion.rechazado ||
                estado == DesenlaceRecepcion.diferencia)
              DropdownButtonFormField<String>(
                initialValue: item['motivoId'] as String?,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Motivo (opcional)',
                  isDense: true,
                ),
                items: widget.motivos
                    .map(
                      (m) => DropdownMenuItem(
                        value: m.id,
                        child: Text(
                          m.nombre,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => item['motivoId'] = v),
              ),
            // Comentario opcional, tanto en Diferencias como en Rechazado (#251).
            if (estado == DesenlaceRecepcion.diferencia ||
                estado == DesenlaceRecepcion.rechazado)
              TextFormField(
                initialValue: item['comentario'] as String? ?? '',
                inputFormatters: FormatosEntrada.texto(
                  maxLongitud: SanitizadorTexto.maxLongitudNota,
                ),
                style: const TextStyle(fontSize: 13, color: Colors.black87),
                decoration: const InputDecoration(
                  labelText: 'Comentario (opcional)',
                  isDense: true,
                ),
                // HU-137: se guarda saneado (sin espacios de más) para que la
                // evidencia de la recepción quede legible en el historial.
                onChanged: (v) =>
                    item['comentario'] = SanitizadorTexto.limpiar(v),
              ),
          ],
        ),
      ),
    );
  }
}
