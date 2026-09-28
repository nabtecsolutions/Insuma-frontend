import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../controllers/controlador_adjuntos.dart';
import '../../../controllers/controlador_pagos.dart';
import '../../../controllers/controlador_procesar_recepcion.dart';
import '../../../models/recepcion_facturable.dart';
import '../../../services/servicio_adjuntos.dart';
import '../../../services/servicio_ocr_remito.dart';
import '../../../services/servicio_precios.dart';
import '../../../services/servicio_procesar_recepcion.dart';
import '../../../services/servicio_sesion.dart';
import '../../../theme/insuma_colors.dart';
import '../../../services/servicio_permisos.dart';
import '../../../utils/adjuntos/selector_archivos_file_picker.dart';
import '../../widgets/guardia_permiso.dart';
import 'paso_confirmacion.dart';
import 'paso_datos_factura.dart';
import 'paso_detalle_items.dart';

/// La pantalla "Procesar recepción" en tres pasos (#229).
///
/// Reemplaza al modal de `pagos_screen`: acá es donde el admin le carga a la
/// recepción los costos POR INSUMO (con su IVA), el número de factura y el
/// vencimiento, y donde el efectivo queda asentado como pago.
///
/// Calcada del wizard de agendas (`wizard_pedido_recurrente.dart`), que es el
/// patrón probado de la casa para flujos de varios pasos: `mostrar()` estático
/// con el Provider EN la ruta, PageView sin swipe (un deslizamiento no puede
/// saltearse la validación del paso), barra "Paso N de 3" fija en la AppBar y
/// botonera con el motivo de bloqueo a la vista. El estado de TODOS los campos
/// vive en [ControladorProcesarRecepcion]: los slides se desmontan al navegar
/// y lo tipeado tiene que sobrevivir.
class PantallaProcesarRecepcion extends StatefulWidget {
  const PantallaProcesarRecepcion({super.key});

  /// Devuelve `true` si la recepción quedó procesada.
  static Future<bool?> mostrar(
    BuildContext context, {
    required RecepcionFacturable recepcion,
  }) async {
    // Todo se resuelve con el contexto de QUIEN ABRE y se captura: el `create`
    // corre después, ya dentro de la ruta nueva.
    final servicio = context.read<ServicioProcesarRecepcion>();
    final sesion = context.read<ServicioSesion>();
    final pagos = context.read<ControladorPagos>();
    final precios = context.read<ServicioPrecios>();
    // HU-144: motor de sugerencias OCR (null-safe: sin Provider no hay botón).
    ServicioOcrRemito? servicioOcr;
    try {
      servicioOcr = context.read<ServicioOcrRemito>();
    } catch (_) {
      servicioOcr = null;
    }
    // Última recepción del pedido por facturar si no queda OTRA en la lista
    // (misma regla que usaba el flujo viejo). Marcar el pedido 'facturado'
    // antes de tiempo escondería las parciales que faltan procesar.
    final esUltima =
        pagos.recepcionesFacturables
            .where((r) => r.pedidoId == recepcion.pedidoId)
            .length <=
        1;
    // #243: la siembra de costos y alícuotas se resuelve ANTES de abrir la
    // ruta — los campos nacen sembrados y no existe carrera posible con el
    // tipeo (la alternativa, precargar async con rebuild de keys, es
    // exactamente la clase de carrera que esto evita). Es una consulta local:
    // imperceptible.
    final ingresosPrevios =
        await ControladorProcesarRecepcion.ingresosPreviosDe(
          precios,
          recepcion,
        );
    if (!context.mounted) return null;
    return Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ChangeNotifierProvider<ControladorProcesarRecepcion>(
          create: (_) => ControladorProcesarRecepcion(
            servicio,
            recepcion: recepcion,
            negocioId: recepcion.pedido.negocioId,
            esUltimaRecepcionDelPedido: esUltima,
            facturasExistentes: pagos.facturasDelNegocio,
            usuarioId: sesion.usuarioId.isEmpty ? null : sesion.usuarioId,
            servicioOcr: servicioOcr,
            ingresosPrevios: ingresosPrevios,
          ),
          child: const PantallaProcesarRecepcion(),
        ),
      ),
    );
  }

  @override
  State<PantallaProcesarRecepcion> createState() =>
      _PantallaProcesarRecepcionState();
}

class _PantallaProcesarRecepcionState extends State<PantallaProcesarRecepcion> {
  static const int _totalPasos = 3;

  /// Tope de ancho del contenido, como en el wizard de agendas: sin él, en una
  /// ventana de escritorio los campos se estiran de borde a borde.
  static const double _anchoMaximo = 560;

  final PageController _pageController = PageController();

  /// Paso visible, 0..2. En el State y no en el controlador a propósito: es
  /// navegación de esta pantalla, no parte de la factura.
  int _paso = 0;

  /// Comprobante(s) que se adjuntan al procesar (además de los que ya trae la
  /// recepción). Vive en el State —no en un paso— para sobrevivir los slides.
  late final ControladorAdjuntos _comprobantes;

  String? _error;

  @override
  void initState() {
    super.initState();
    _comprobantes = ControladorAdjuntos(
      const SelectorArchivosFilePicker(),
      context.read<ServicioAdjuntos>(),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _comprobantes.dispose();
    super.dispose();
  }

  void _avanzar() {
    if (_paso >= _totalPasos - 1) return;
    setState(() {
      _paso++;
      _error = null;
    });
    _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _retroceder() {
    if (_paso == 0) return;
    setState(() {
      _paso--;
      _error = null;
    });
    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _finalizar(ControladorProcesarRecepcion ctrl) async {
    final navigator = Navigator.of(context);
    final error = await ctrl.finalizar(_comprobantes);
    if (!mounted) return;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<ControladorProcesarRecepcion>();
    // #255: el visor de "todos los adjuntos" degrada por rol en el Service; el
    // rol no cambia dentro del wizard, así que se lee una vez (no `watch`) desde
    // la misma fuente que la GuardiaPermiso.
    final puedeVerFinanzas = Permisos.puede(
      context.read<ServicioSesion>().usuarioRol,
      Permiso.verFinanzas,
    );

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        foregroundColor: Colors.black87,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Procesar recepción',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            Text(
              '${ctrl.recepcion.proveedorNombre} · '
              'Recepción N°${ctrl.recepcion.numeroRecepcion}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
        bottom: _barraProgreso(),
      ),
      body: GuardiaPermiso(
        permiso: Permiso.verFinanzas,
        mensaje:
            'Procesar recepciones y cargar costos es información de '
            'administrador.',
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                // Se avanza sólo con los botones: un swipe podría saltearse la
                // validación del paso.
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  PasoDatosFactura(
                    ctrl: ctrl,
                    comprobantes: _comprobantes,
                    anchoMaximo: _anchoMaximo,
                  ),
                  PasoDetalleItems(
                    ctrl: ctrl,
                    comprobantes: _comprobantes,
                    anchoMaximo: _anchoMaximo,
                    puedeVerFinanzas: puedeVerFinanzas,
                  ),
                  PasoConfirmacion(ctrl: ctrl, anchoMaximo: _anchoMaximo),
                ],
              ),
            ),
            _pieTotales(ctrl),
            _botonera(ctrl),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _barraProgreso() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(46),
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paso ${_paso + 1} de $_totalPasos',
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (var i = 0; i < _totalPasos; i++)
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: EdgeInsets.only(
                        right: i == _totalPasos - 1 ? 0 : 4,
                      ),
                      height: 4,
                      decoration: BoxDecoration(
                        color: i <= _paso
                            ? InsumaColors.primaryBlue
                            : Colors.grey[200],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Los tres números del pie, SIEMPRE visibles (pedido del PO): viven fuera
  /// del PageView para que ningún paso los tape ni los scrollee.
  Widget _pieTotales(ControladorProcesarRecepcion ctrl) {
    final r = ctrl.resumen;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _anchoMaximo),
          // Wrap y no Row: tres cifras largas a 360 dp no entran en una línea
          // (lección de #204/#215) y acá tienen que poder apilarse.
          child: Wrap(
            spacing: 16,
            runSpacing: 2,
            alignment: WrapAlignment.spaceBetween,
            children: [
              _cifra('Subtotal neto', r.subtotalNeto),
              _cifra('IVA', r.iva),
              _cifra(
                ctrl.totalManual != null ? 'Total (manual)' : 'Total c/IVA',
                ctrl.totalFactura,
                destacada: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cifra(String etiqueta, double valor, {bool destacada = false}) {
    return Text(
      '$etiqueta: \$${valor.toStringAsFixed(2)}',
      style: TextStyle(
        fontSize: destacada ? 13 : 12,
        fontWeight: destacada ? FontWeight.bold : FontWeight.normal,
        color: Colors.black87,
      ),
    );
  }

  Widget _botonera(ControladorProcesarRecepcion ctrl) {
    final bloqueo = _error ?? ctrl.motivoBloqueo(_paso);
    final esUltimo = _paso == _totalPasos - 1;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: InsumaColors.cardBorderLight)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _anchoMaximo),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (bloqueo != null) ...[
                  Text(
                    bloqueo,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.redAccent,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _paso == 0 || ctrl.procesando
                            ? null
                            : _retroceder,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.black54,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Atrás'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed:
                            (ctrl.motivoBloqueo(_paso) != null ||
                                ctrl.procesando)
                            ? null
                            : (esUltimo ? () => _finalizar(ctrl) : _avanzar),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: InsumaColors.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: ctrl.procesando
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                esUltimo ? 'Finalizar' : 'Siguiente',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
