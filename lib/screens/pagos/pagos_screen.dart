import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../database/database.dart';
import '../../controllers/controlador_pagos.dart';
import '../../controllers/controlador_adjuntos.dart';
import '../../models/recepcion_facturable.dart';
import '../../services/servicio_adjuntos.dart';
import '../../services/servicio_permisos.dart';
import '../../services/servicio_sesion.dart';
import '../../theme/insuma_colors.dart';
import '../../utils/desenlace_recepcion.dart';
import '../../utils/filtros_pagos.dart';
import '../../utils/resumen_monto_pedido.dart';
import '../../utils/adjuntos/selector_archivos_file_picker.dart';
import '../widgets/campo_numerico.dart';
import '../widgets/guardia_permiso.dart';
import '../recibir/widgets/selector_remito_widget.dart';
import 'cuenta_corriente_screen.dart';
import 'widgets/formulario_pago_proveedor.dart';
import 'widgets/panel_filtros_pagos.dart';
import 'procesar_recepcion/pantalla_procesar_recepcion.dart';
import 'widgets/visor_remito.dart';

/// Pantalla del módulo Pagos (HU-023 facturas / HU-024 pagos), accesible desde el
/// menú de administración. Protegida con [GuardiaPermiso] (información financiera).
class PantallaPagos extends StatefulWidget {
  const PantallaPagos({super.key});

  @override
  State<PantallaPagos> createState() => _PantallaPagosState();
}

class _PantallaPagosState extends State<PantallaPagos> {
  /// #237: lo elegido en el panel de filtros. Vive en la SCREEN y no en el
  /// controlador a propósito: `ControladorPagos` tiene cuota exacta en el
  /// trinquete de arquitectura y una reactividad delicada (HU-128/136); el
  /// filtrado es un módulo puro de `utils/` invocado desde acá.
  CriteriosFiltroPagos _criterios = CriteriosFiltroPagos.vacio;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ControladorPagos>().cargar();
    });
  }

  String _money(double v) => '\$${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    // #237: el AppBar está FUERA de la GuardiaPermiso, así que el ícono y el
    // panel se condicionan acá — y LOS DOS JUNTOS: con `endDrawer` seteado y
    // sin action, Flutter agrega solo el ícono hamburguesa, y el cocinero
    // vería un panel de filtros de información financiera.
    final rol = context.watch<ServicioSesion>().usuarioRol;
    final puedeVerFinanzas = Permisos.puede(rol, Permiso.verFinanzas);
    final ctrl = context.watch<ControladorPagos>();
    // Se filtra UNA vez por build y el resultado alimenta las dos secciones y
    // los contadores del panel.
    final resultadoRec = filtrarRecepcionesPagos(
      ctrl.recepcionesFacturables,
      criterios: _criterios,
      proveedorDe: ctrl.proveedorPorId,
      saldoDe: ctrl.saldo,
    );
    final provsFiltrados = filtrarProveedoresPagos(
      ctrl.proveedores,
      criterios: _criterios,
      saldoDe: ctrl.saldo,
    );

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      appBar: AppBar(
        title: const Text('Pagos'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 1,
        actions: [
          if (puedeVerFinanzas)
            Builder(
              builder: (ctx) => IconButton(
                tooltip: 'Filtros',
                icon: Badge(
                  isLabelVisible: _criterios.hayAlguno,
                  child: const Icon(Icons.filter_list),
                ),
                onPressed: () => Scaffold.of(ctx).openEndDrawer(),
              ),
            ),
        ],
      ),
      endDrawer: puedeVerFinanzas
          ? PanelFiltrosPagos(
              criterios: _criterios,
              proveedores: ctrl.proveedores,
              cantidadProveedores: provsFiltrados.length,
              cantidadRecepciones: resultadoRec.visibles.length,
              alCambiar: (c) => setState(() => _criterios = c),
            )
          : null,
      body: GuardiaPermiso(
        permiso: Permiso.verFinanzas,
        mensaje:
            'La gestión de facturas y pagos es información de administrador.',
        child: _buildContenido(ctrl, resultadoRec, provsFiltrados),
      ),
    );
  }

  Widget _buildContenido(
    ControladorPagos ctrl,
    ResultadoFiltroRecepciones resultadoRec,
    List<Proveedore> provsFiltrados,
  ) {
    if (ctrl.cargando) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        _cardPendienteDePago(ctrl),
        const SizedBox(height: 16),
        _tituloSeccion('Recepciones por procesar'),
        const SizedBox(height: 8),
        if (ctrl.recepcionesFacturables.isEmpty)
          _vacio('No hay recepciones pendientes de procesar.')
        else if (resultadoRec.visibles.isEmpty &&
            resultadoRec.ocultasSinProveedor == 0)
          _sinCoincidencias('Ninguna recepción coincide con los filtros.')
        else
          ...resultadoRec.visibles.map((r) => _cardRecepcion(ctrl, r)),
        // #237: la plata pendiente no desaparece en silencio. El aviso va en el
        // BODY (no en el drawer, que se cierra): es donde se está mirando la
        // lista incompleta.
        if (resultadoRec.ocultasSinProveedor > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '${resultadoRec.ocultasSinProveedor} recepción(es) sin proveedor '
              'identificado quedaron fuera de los filtros.',
              style: TextStyle(fontSize: 11, color: Colors.orange[800]),
            ),
          ),
        const SizedBox(height: 24),
        _tituloSeccion('Proveedores y saldos'),
        const SizedBox(height: 8),
        if (ctrl.proveedores.isEmpty)
          _vacio('No hay proveedores cargados.')
        else if (provsFiltrados.isEmpty)
          _sinCoincidencias('Ningún proveedor coincide con los filtros.')
        else
          ...provsFiltrados.map((pr) => _cardProveedor(ctrl, pr)),
      ],
    );
  }

  /// Hay datos pero ninguno pasa los filtros: se ofrece la salida acá mismo,
  /// sin obligar a reabrir el panel para encontrar "Limpiar".
  Widget _sinCoincidencias(String texto) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            texto,
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ),
        TextButton(
          onPressed: () =>
              setState(() => _criterios = CriteriosFiltroPagos.vacio),
          child: const Text('Limpiar filtros', style: TextStyle(fontSize: 12)),
        ),
      ],
    ),
  );

  /// Cuánta plata hay que juntar para pagarles a los proveedores (#228).
  ///
  /// Arriba de todo y sin contador: un pedido recibido en tres entregas
  /// parciales genera TRES facturas, así que "N pedidos impagos" sería un número
  /// ambiguo. Lo que sirve para preparar la plata es el monto.
  ///
  /// Con todo pagado dice que no hay nada pendiente, en vez de un "$0.00" que se
  /// lee como un dato que no cargó.
  Widget _cardPendienteDePago(ControladorPagos ctrl) {
    final total = ctrl.totalPendienteDePago;
    final hayDeuda = total > 0;
    return _card(
      child: Row(
        children: [
          Icon(
            hayDeuda
                ? Icons.account_balance_wallet
                : Icons.check_circle_outline,
            size: 28,
            color: hayDeuda ? InsumaColors.primaryBlue : Colors.green,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PENDIENTE DE PAGO',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey[500],
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hayDeuda ? _money(total) : 'Sin facturas pendientes',
                  style: TextStyle(
                    fontSize: hayDeuda ? 22 : 14,
                    fontWeight: FontWeight.bold,
                    color: hayDeuda ? Colors.black87 : Colors.grey,
                  ),
                ),
                if (hayDeuda)
                  // Dice QUÉ suma, y no es decoración: este total no coincide
                  // con la suma de los "Debe" de abajo cuando hay pagos sin
                  // imputar. Ver `ControladorPagos.totalPendienteDePago`.
                  Text(
                    'Suma de las facturas sin cancelar',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tituloSeccion(String t) => Text(
    t,
    style: const TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.bold,
      color: Colors.black87,
    ),
  );

  Widget _vacio(String t) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(t, style: const TextStyle(color: Colors.grey, fontSize: 13)),
  );

  Widget _card({required Widget child}) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: InsumaColors.cardBorderLight),
    ),
    child: child,
  );

  /// Líneas del total del pedido de origen y su diferencia con lo recibido (#80).
  ///
  /// Se compara contra `montoRecibido` —lo que efectivamente entró y se va a
  /// facturar— y no contra el total del pedido consigo mismo: la pregunta que se
  /// hace el admin antes de pagar es "¿me facturan lo que pedí?".
  List<Widget> _lineasMontoPedido(RecepcionFacturable r) {
    final resumen = resumenMontoPedido(
      totalPedido: r.pedido.total,
      totalFacturado: r.montoRecibido,
      formatearMonto: _money,
    );
    return [
      const SizedBox(height: 2),
      Text(
        'Pedido: ${resumen.textoTotalPedido}',
        style: TextStyle(
          fontSize: 12,
          // Sin monto cargado se pinta en gris y en cursiva: es la ausencia de
          // un dato, no una cifra que se pueda tomar como buena.
          color: resumen.hayTotalPedido ? Colors.black87 : Colors.grey,
          fontStyle: resumen.hayTotalPedido
              ? FontStyle.normal
              : FontStyle.italic,
        ),
      ),
      if (resumen.textoDiferencia != null) ...[
        const SizedBox(height: 2),
        Text(
          resumen.textoDiferencia!,
          style: const TextStyle(
            fontSize: 11,
            color: Colors.orange,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ];
  }

  Widget _cardRecepcion(ControladorPagos ctrl, RecepcionFacturable r) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.proveedorNombre,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Recibido ${_money(r.montoRecibido)} · Recepción N°${r.numeroRecepcion}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    // HU-150: el total del PEDIDO que originó la deuda, para
                    // poder comparar lo pedido contra lo recibido antes de
                    // facturar. La regla de qué mostrar cuando no hay monto
                    // cargado vive en `resumen_monto_pedido.dart`.
                    ..._lineasMontoPedido(r),
                    // HU-143: trazabilidad del total escrito a mano.
                    if (r.totalEditadoAMano) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Total editado por ${r.totalEditadoPorNombre ?? 'admin'}'
                        '${r.fechaTotalEditado != null ? ' · ${_fechaCorta(r.fechaTotalEditado!)}' : ''}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.orange,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (r.esParcial) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Parcial · Pedido del ${_fechaCorta(r.pedido.fechaCreacion)}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _chipDesenlace(r.desenlace),
                  // #229: la marca de efectivo, al lado del desenlace como
                  // pidió el PO. En COLUMNA y no en el Row del encabezado:
                  // esa card ya desbordó una vez (#204) y dos chips en línea
                  // le comen el ancho al nombre del proveedor.
                  if (r.esEfectivo) ...[
                    const SizedBox(height: 4),
                    _chip('Pago en efectivo', Colors.teal),
                  ],
                ],
              ),
            ],
          ),
          // #212: lo que hace falta para decidir el monto y no estaba en esta
          // pantalla. Va DESPUÉS del encabezado y ANTES de la botonera: es
          // contexto para leer los números de arriba, no una acción.
          ..._contextoDeLaRecepcion(r),
          const SizedBox(height: 8),
          // #204: `Wrap`, NO `Row`. Misma lección que #180 en `TarjetaPedido`:
          // un `Row` no tiene a dónde achicar sus hijos, y estos CUATRO botones
          // —"Editar total", "Ver remito", "Cargar factura" y "Procesar
          // recepción"— no entran ni de casualidad en un teléfono. Medido con
          // un widget test montando esta pantalla: desbordaba 498 px a 360 dp
          // ANTES de renombrar el botón, y 639 px después. En pantalla eso
          // recorta el borde derecho de la tarjeta y deja parcialmente
          // inaccesible el botón con el que se procesa la recepción.
          //
          // Al bajar de renglón cada acción conserva sus 48 dp de alto, que es
          // lo que se toca con el pulgar. Y el ancho no es fijo: la app compone
          // su propio factor de tipografía (hasta 1.3x, HU-054) con el del
          // sistema, así que una fila que hoy entre justo revienta al agrandar
          // el texto.
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              // HU-143: total recibido escrito a mano (según remito/factura).
              TextButton.icon(
                onPressed: () => _abrirEditarTotal(ctrl, r),
                icon: const Icon(
                  Icons.edit_outlined,
                  size: 16,
                  color: InsumaColors.primaryBlue,
                ),
                label: const Text(
                  'Editar total',
                  style: TextStyle(color: InsumaColors.primaryBlue),
                ),
              ),
              // HU-148: acceso al documento SIN salir de la pantalla donde se
              // definen los montos, para poder cotejar antes de facturar.
              // Deshabilitado —y no oculto— cuando no hay: que el botón no esté
              // se lee como "esta pantalla no tiene esa función"; deshabilitado
              // con tooltip dice que el documento falta, que es el dato útil.
              Tooltip(
                message: r.tieneRemito
                    ? 'Ver el remito de la recepción'
                    : 'Esta recepción no tiene remito adjunto',
                child: TextButton.icon(
                  onPressed: r.tieneRemito ? () => _verRemito(r) : null,
                  icon: const Icon(Icons.receipt_long, size: 16),
                  label: const Text('Ver remito'),
                ),
              ),
              // HU-147: la factura suele llegar días después de la mercadería.
              TextButton.icon(
                onPressed: () => _adjuntarFactura(ctrl, r),
                icon: const Icon(
                  Icons.upload_file,
                  size: 16,
                  color: InsumaColors.primaryBlue,
                ),
                label: const Text(
                  'Cargar factura',
                  style: TextStyle(color: InsumaColors.primaryBlue),
                ),
              ),
              TextButton(
                // #229: la pantalla de tres pasos reemplaza al modal que
                // vivia aca (numero + un solo total sin IVA ni renglones).
                onPressed: () =>
                    PantallaProcesarRecepcion.mostrar(context, recepcion: r),
                child: const Text(
                  'Procesar recepción',
                  style: TextStyle(color: InsumaColors.primaryBlue),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Chip de color con el desenlace agregado de la recepción (HU-064/067).
  /// Lo que administración necesita saber de una recepción para decidir cuánto
  /// facturar, y que hasta #212 sólo se veía en la pantalla de Recepciones.
  ///
  /// DOS cosas, las dos condicionales: una tarjeta sin nota y sin observaciones
  /// no crece ni un píxel. Esa tarjeta ya desbordó una vez (#204) y el test la
  /// monta a 360 dp, así que cada renglón nuevo tiene que ganarse el lugar.
  ///
  /// Eran tres: había un aviso de "Sin remito adjunto". Se sacó en #226, cuando
  /// el comprobante volvió a ser obligatorio al recibir y el cartel pasó a
  /// sobrar en el caso normal.
  ///
  /// ⚠ Queda un caso sin cubrir: un adjunto que falla al persistirse se descarta
  /// en silencio y la recepción llega acá sin respaldo (#227). Ese aviso era la
  /// única forma de detectarlo a posteriori.
  ///
  /// NINGUNA de las dos cuesta una consulta: `RecepcionFacturable` ya trae la
  /// fila `recepcion` completa en memoria, incluidos la nota y el JSON de ítems.
  List<Widget> _contextoDeLaRecepcion(RecepcionFacturable r) {
    final nota = (r.recepcion.nota ?? '').trim();
    final observaciones = itemsConObservaciones(_lineasDe(r));
    if (nota.isEmpty && observaciones == 0) return const [];

    return [
      const SizedBox(height: 6),
      // El desenlace agregado ya decía "Diferencias", pero no cuántos renglones
      // la provocaron. Sin ese número hay que abrir el detalle para saber si es
      // un ítem o siete.
      if (observaciones > 0)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '$observaciones ${observaciones == 1 ? "ítem" : "ítems"} con observaciones',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
      // Misma presentación que en Recepciones (HU-146): entrecomillada y en
      // cursiva, para que se lea como la voz de quien recibió y no como un
      // campo más del sistema.
      if (nota.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '“$nota”',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: Colors.black87,
            ),
          ),
        ),
    ];
  }

  Widget _chipDesenlace(String desenlace) {
    late final String texto;
    late final Color color;
    switch (desenlace) {
      case DesenlaceRecepcion.rechazado:
        texto = 'Con rechazos';
        color = Colors.redAccent;
        break;
      case DesenlaceRecepcion.diferencia:
        texto = 'Diferencias';
        color = Colors.orange;
        break;
      default:
        texto = 'Correcto';
        color = Colors.green;
    }
    return _chip(texto, color);
  }

  Widget _chip(String texto, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        texto,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  void _verRemito(RecepcionFacturable r) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PantallaVisorRemito.deRecepcion(
          recepcionId: r.recepcionId,
          titulo: 'Remito · ${r.proveedorNombre}',
        ),
      ),
    );
  }

  /// Todos los papeles de la recepción, en una sola pasada (#209).
  ///
  /// Remito y factura juntos y no en dos botones: al procesar hay que cotejar
  /// qué llegó contra qué cobran, y separarlos obligaba a entrar y salir dos
  /// veces del mismo modal.

  /// HU-143: diálogo para escribir el total recibido a mano (o volver al
  /// calculado). La persistencia y la auditoría las hace el controlador/servicio.
  Future<void> _abrirEditarTotal(
    ControladorPagos ctrl,
    RecepcionFacturable r,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    double? nuevoTotal = r.totalEditadoAMano ? r.recepcion.totalRecibido : null;
    // Sentinel: distingue "Guardar" (true/valor) de "Volver al calculado" (false).
    final accion = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(
          'Total recibido (según remito)',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Calculado por líneas: ${_money(totalRecibidoDeLineas(_lineasDe(r)))}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            CampoNumerico(
              etiqueta: 'Total recibido',
              prefijo: r'$',
              valorInicial: nuevoTotal,
              obligatorio: false,
              permitirCero: true,
              autofocus: true,
              ayuda: 'Manda sobre el calculado y queda registrado a tu nombre.',
              alCambiar: (v) => nuevoTotal = v,
            ),
          ],
        ),
        actions: [
          if (r.totalEditadoAMano)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Volver al calculado'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (!mounted || accion == null) return;
    final totalAGuardar = accion
        ? nuevoTotal
        : null; // false ⇒ restaurar derivado
    // Sin cambios reales no se muta nada: evitaría reasignar la autoría del
    // total (y un push/auditoría) por un "Guardar" sin tocar el campo.
    if (totalAGuardar == r.recepcion.totalRecibido) return;
    final error = await ctrl.editarTotalRecibido(r, nuevoTotal: totalAGuardar);
    if (!mounted || error == null) return;
    messenger.showSnackBar(
      SnackBar(content: Text(error), backgroundColor: Colors.redAccent),
    );
  }

  /// Líneas del JSON de la recepción (para mostrar el total derivado en el diálogo).
  List<Map<String, dynamic>> _lineasDe(RecepcionFacturable r) {
    try {
      return (jsonDecode(r.recepcion.items) as List)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  String _fechaCorta(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  Widget _cardProveedor(ControladorPagos ctrl, Proveedore pr) {
    final saldo = ctrl.saldo(pr.id);
    final pendientes = ctrl.facturasPendientesDe(pr.id).length;
    final colorSaldo = saldo > 0.001
        ? Colors.redAccent
        : (saldo < -0.001 ? Colors.green : Colors.grey);
    final etiquetaSaldo = saldo > 0.001
        ? 'Debe ${_money(saldo)}'
        : (saldo < -0.001 ? 'A favor ${_money(-saldo)}' : 'Sin saldo');
    return InkWell(
      onTap: () => _abrirCuentaCorriente(pr),
      borderRadius: BorderRadius.circular(14),
      child: _card(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pr.nombre,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$etiquetaSaldo · $pendientes factura(s) pendiente(s)',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorSaldo,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Ver cuenta corriente',
                    style: TextStyle(
                      fontSize: 11,
                      color: InsumaColors.primaryBlue,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => _abrirModalPago(pr),
              child: const Text(
                'Registrar pago',
                style: TextStyle(color: InsumaColors.primaryBlue),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _abrirCuentaCorriente(Proveedore proveedor) {
    // ControladorPagos vive en el MultiProvider raíz, así que la ruta pusheada
    // lo resuelve con context.read sin necesidad de re-proveerlo.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PantallaCuentaCorriente(proveedor: proveedor),
      ),
    );
  }

  /// Acceso al documento de una factura desde la card de pago (HU-148).
  ///
  /// La factura puede no tener recepción asociada (facturas cargadas a mano):
  /// en ese caso el acceso se ve DESHABILITADO y el tooltip dice por qué, en vez
  /// de desaparecer. Un icono ausente se lee como "acá no se puede ver el
  /// papel"; deshabilitado dice que el papel no está, que es el dato útil.

  // ─── Cargar la factura del proveedor (HU-147) ──────────────────────────────

  /// Adjunta la FACTURA a una recepción ya cerrada.
  ///
  /// Reutiliza el mismo selector que el remito y el comprobante: la HU es
  /// plomería sobre la infraestructura de adjuntos que ya existe, no un camino
  /// nuevo de archivos.
  Future<void> _adjuntarFactura(
    ControladorPagos ctrl,
    RecepcionFacturable recepcion,
  ) async {
    final staging = ControladorAdjuntos(
      const SelectorArchivosFilePicker(),
      context.read<ServicioAdjuntos>(),
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setModalState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
              top: 16,
              left: 20,
              right: 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Cargar factura — ${recepcion.proveedorNombre}',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Recepción N°${recepcion.numeroRecepcion}. Cargar una factura '
                  'nueva no borra la anterior: quedan las dos.',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                SelectorRemitoWidget(
                  controlador: staging,
                  titulo: 'Factura del proveedor',
                  textoVacio: 'Sin factura adjunta.',
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: InsumaColors.primaryBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final res = await ctrl.adjuntarFactura(
                      recepcion: recepcion,
                      facturas: staging,
                    );
                    if (!sheetContext.mounted) return;
                    if (!res.ok) {
                      setModalState(() {});
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(res.error!),
                          backgroundColor: Colors.orange.shade800,
                        ),
                      );
                      return;
                    }
                    Navigator.pop(sheetContext);
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Factura cargada.')),
                    );
                  },
                  child: const Text('Guardar factura'),
                ),
              ],
            ),
          );
        },
      ),
    );
    staging.dispose();
  }

  /// El formulario de pago vive aparte, en
  /// `widgets/formulario_pago_proveedor.dart`, para que la ficha del proveedor
  /// (HU-009) monte EL MISMO y no una copia. HU-149 —que reescribe el desglose
  /// del pago— toca ese archivo y las dos pantallas heredan el cambio.
  void _abrirModalPago(Proveedore proveedor) => abrirFormularioPagoProveedor(
    context,
    proveedorId: proveedor.id,
    proveedorNombre: proveedor.nombre,
  );
}
