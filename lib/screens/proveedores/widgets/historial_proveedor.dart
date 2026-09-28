import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../controllers/controlador_recibir.dart';
import '../../../database/database.dart';
import '../../../theme/insuma_colors.dart';
import '../../../utils/estados_pedido.dart';
import '../../../utils/filtros_historial_pedidos.dart';
import '../../pagos/widgets/visor_remito.dart';
import '../../recibir/widgets/tarjeta_pedido.dart';
import '../../widgets/barra_filtros_pedidos.dart';

/// Historial de pedidos de UN proveedor, dentro de su ficha (HU-041).
///
/// Es el mismo problema que `PantallaHistorialPedidos` acotado a un proveedor, y
/// reusa sus piezas: [BarraFiltrosPedidos] para los filtros,
/// `filtrarHistorialPedidos` para aplicarlos y `TarjetaPedido` para cada fila.
/// Sólo cambian dos cosas, las dos por decisión del PO:
///
///  1. **Lista TODOS los estados**, no sólo los cerrados. La pantalla general
///     filtra con `EstadosPedido.esHistorial`; acá NO, porque desde la ficha se
///     entra a ver qué pasó y qué está pasando con este proveedor: un borrador o
///     algo "A recibir" es justamente lo que se viene a buscar.
///  2. El proveedor ya viene FIJO por id, así que no hay filtro por proveedor y
///     tampoco se usa el parámetro `proveedor` de `filtrarHistorialPedidos`
///     (que compara por NOMBRE y no distingue dos proveedores homónimos).
///
/// ⚠ Este widget se mide ENTERO: la lista va con `shrinkWrap` +
/// `NeverScrollableScrollPhysics`, así que no scrollea por su cuenta. El scroll
/// lo tiene que poner la pantalla que lo monta (un `SingleChildScrollView`
/// alrededor de toda la ficha). Es a propósito: el PO prueba en Chrome y con dos
/// viewports anidados la rueda del mouse mueve el de adentro, y el panel
/// financiero de arriba deja de poder alcanzarse. Corolario: NO envolverlo en un
/// `Expanded` de una `Column` de alto acotado, porque ahí recortaría sin scroll.
///
/// Ese `shrinkWrap` construye TODAS las tarjetas de una, y por eso desde #236 el
/// listado se corta de a 20 con "Ver más": es lo que mantiene vivible una ficha
/// con años de pedidos. El corte es VISUAL — la query de pedidos sigue sin LIMIT
/// ni filtro de estado; el fix de fondo es #191, bloqueado por el índice de
/// #190 — así que esto NO cierra ese issue.
class HistorialProveedor extends StatefulWidget {
  const HistorialProveedor({
    super.key,
    required this.proveedorId,
    required this.puedeVerFinanzas,
    required this.alAbrirDetalle,
  });

  final String proveedorId;

  /// HU-060: el cocinero no ve importes. Se propaga a la tarjeta y además
  /// GOBIERNA el filtro por monto: la barra ni siquiera devuelve los montos
  /// cuando este permiso falta, así que no hay forma de deducir por tanteo el
  /// total que la tarjeta oculta.
  final bool puedeVerFinanzas;

  /// Abre el detalle del pedido. Lo resuelve la PANTALLA, que es la que tiene
  /// `AccionesPedidoMixin` (y con él `verDetallePedido`, que ya muestra las
  /// recepciones parciales con su comentario — HU-146). Delegar en un callback
  /// deja este widget testeable sin montar medio árbol de providers.
  final ValueChanged<Pedido> alAbrirDetalle;

  @override
  State<HistorialProveedor> createState() => _HistorialProveedorState();
}

class _HistorialProveedorState extends State<HistorialProveedor> {
  // ── Estado de los filtros ───────────────────────────────────────────────────
  //
  // La barra es [BarraFiltrosPedidos], la misma que el Historial general: dueña
  // de los controllers, del saneo del estado y del botón "Limpiar". Acá sólo
  // queda lo ELEGIDO, porque es este widget el que sabe sobre qué lista filtrar.
  CriteriosFiltroPedidos _criterios = CriteriosFiltroPedidos.vacio;

  /// El atajo "Limpiar filtros" del estado "ningún resultado" es de este widget
  /// y no de la barra: la key es el único modo de que ese botón vacíe también el
  /// TEXTO VISIBLE de los campos (#170). Va como campo del State y NO se crea en
  /// `build`; el porqué está explicado una sola vez, en el campo homónimo de
  /// `PantallaHistorialPedidos`.
  final _barraFiltros = GlobalKey<BarraFiltrosPedidosState>();

  void _limpiarFiltros() => _barraFiltros.currentState?.limpiar();

  // ── Corte del listado (#236) ────────────────────────────────────────────────

  /// De a cuántos crece el listado con cada "Ver más".
  static const int _tamanoPagina = 20;

  /// Cuántos pedidos (ya filtrados) se muestran. Vuelve al inicio cuando cambia
  /// un filtro: un "Ver más" viejo no debe arrastrarse a un criterio nuevo.
  int _visibles = _tamanoPagina;

  @override
  void initState() {
    super.initState();
    // Los pedidos salen de `ControladorRecibir`, que se puebla al entrar a
    // Pedidos o Recepciones. A la ficha se llega desde Proveedores, que puede
    // ser la PRIMERA pantalla que se abre: sin esta carga el historial saldría
    // vacío y mentiría diciendo que el proveedor no tiene pedidos. Repetir la
    // llamada es seguro: el controlador reasigna la subscription y cancela la
    // anterior.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ControladorRecibir>().cargarSesionYPedidos();
    });
  }

  /// Aplica todos los criterios activos delegando en el módulo puro de HU-151.
  ///
  /// Hermano del `_aplicarFiltros` de `PantallaHistorialPedidos` —ahí están
  /// explicados el saneo del estado y por qué la lista y el contador salen de
  /// UNA sola pasada—, con dos argumentos menos: los comentádos abajo.
  List<Pedido> _aplicarFiltros(
    List<Pedido> delProveedor,
    List<String> opciones,
  ) {
    final c = _criterios.vigenteEntre(opciones);
    return filtrarHistorialPedidos(
      delProveedor,
      // `proveedor` va sin pasar a propósito: filtra por NOMBRE y acá el
      // proveedor ya quedó acotado por id, que es el criterio exacto. Por eso la
      // barra va sin ese campo (`mostrarCampoProveedor: false`).
      articulo: c.articulo,
      desde: c.rangoFechas?.start,
      hasta: c.rangoFechas?.end,
      etiquetaEstado: c.etiquetaEstado,
      // HU-060: sin permiso de finanzas la barra devuelve los montos vacíos, así
      // que acá llegan en null y el rango no filtra.
      montoMin: c.montoMin,
      montoMax: c.montoMax,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<ControladorRecibir>();

    // Todos los estados (decisión del PO): desde la ficha se quiere ver el ciclo
    // completo del proveedor, no sólo lo cerrado.
    final delProveedor = ctrl.pedidos
        .where((p) => p.proveedorId == widget.proveedorId)
        .toList();

    // Si la carga falló, el spinner giraría para siempre y el usuario buscaría
    // pedidos que la app nunca va a mostrar. El panel financiero de arriba sí
    // sabe decirlo y ofrecer reintentar: acá tiene que pasar lo mismo.
    final error = ctrl.errorCarga;
    if (error != null && delProveedor.isEmpty) {
      return _bloque(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            children: [
              Icon(Icons.cloud_off_outlined, size: 32, color: Colors.grey[400]),
              const SizedBox(height: 8),
              Text(
                error,
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => ctrl.cargarSesionYPedidos(),
                child: const Text('Reintentar', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }

    if (ctrl.cargando && delProveedor.isEmpty) {
      return _bloque(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    // Sin pedidos NO se muestran los filtros: no hay nada que filtrar, y una
    // barra de filtros sobre la nada sugiere que algo quedó escondido.
    if (delProveedor.isEmpty) return _bloque(_vacio());

    // Opciones del desplegable y filtrado: mismo esquema que el Historial
    // general (una sola pasada, reusada por la lista y por el contador), y por
    // los mismos motivos —están escritos allá—.
    final opcionesEstado = etiquetasDeEstado(delProveedor);
    final filtrados = _aplicarFiltros(delProveedor, opcionesEstado);

    // #236: el corte va DESPUÉS del filtro — "Ver más" pagina el resultado
    // filtrado, y el contador de la barra sigue diciendo el total real.
    final recortados = filtrados.take(_visibles).toList();

    return _bloque(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Sin campo de proveedor (ya está fijo por id) y sin los filtros de
          // entrega de HU-142: desde la ficha se mira lo que pasó con ESTE
          // proveedor, no se planifican recepciones.
          //
          // La receta visual la pone la ficha: misma tarjeta blanca, radio 16 y
          // borde claro que el resto de sus bloques, porque la barra va metida
          // entre tarjetas redondeadas y un rectángulo a sangre completa se
          // leería como un pedazo de otra pantalla.
          BarraFiltrosPedidos(
            key: _barraFiltros,
            opcionesEstado: opcionesEstado,
            cantidadResultados: filtrados.length,
            mostrarCampoProveedor: false,
            mostrarFiltrosEntrega: false,
            puedeVerFinanzas: widget.puedeVerFinanzas,
            // Sin pedidos la barra sale del árbol (guard de arriba): sembrarla
            // con lo elegido evita que volver a entrar borre los filtros.
            criteriosIniciales: _criterios,
            margen: const EdgeInsets.only(top: 4),
            decoracion: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: InsumaColors.cardBorderLight),
            ),
            alCambiar: (c) => setState(() {
              _criterios = c;
              _visibles = _tamanoPagina;
            }),
          ),
          if (filtrados.isEmpty)
            _sinResultados()
          else ...[
            _listado(recortados),
            if (filtrados.length > _visibles)
              _verMas(restantes: filtrados.length - _visibles),
          ],
        ],
      ),
    );
  }

  /// El botón que agranda el corte de #236. Dice cuántos faltan para que quede
  /// claro que el historial no termina donde termina la pantalla.
  Widget _verMas({required int restantes}) {
    return Center(
      child: TextButton.icon(
        icon: const Icon(Icons.expand_more, size: 16),
        label: Text(
          'Ver más ($restantes restantes)',
          style: const TextStyle(fontSize: 12),
        ),
        onPressed: () => setState(() => _visibles += _tamanoPagina),
      ),
    );
  }

  /// Encabeza el bloque con su título, en LOS TRES estados (cargando, sin
  /// pedidos y con listado).
  ///
  /// El título vive acá y no en la ficha porque el bloque tiene que poder
  /// nombrarse solo: la ficha lo mete como un hijo más de su `ListView`, entre
  /// otras tarjetas ya rotuladas, y sin rótulo una barra de filtros suelta no
  /// dice de qué es. Si algún día la ficha agrega su propio encabezado, hay que
  /// sacar UNO de los dos: dos títulos seguidos se leen como un error.
  Widget _bloque(Widget contenido) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 10, 4, 2),
          child: Row(
            children: [
              Icon(Icons.history, size: 16, color: Colors.black54),
              SizedBox(width: 6),
              Text(
                'Historial de pedidos',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
        contenido,
      ],
    );
  }

  /// El proveedor no tiene NINGÚN pedido. Distinto de [_sinResultados]: acá no
  /// hay filtro que aflojar, y decir "no coincide con los filtros" mandaría al
  /// usuario a pelearse con una barra que ni siquiera está en pantalla.
  Widget _vacio() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(Icons.receipt_long_outlined, size: 48, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text(
            'Todavía no le hiciste pedidos a este proveedor',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// Sí hay pedidos, pero ninguno pasa los filtros. Lleva el atajo para
  /// aflojarlos: es el único camino de salida, y tenerlo acá evita volver a
  /// buscar el botón "Limpiar" arriba.
  Widget _sinResultados() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 48, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text(
            'Ningún pedido coincide con los filtros',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _limpiarFiltros,
            child: const Text('Limpiar filtros'),
          ),
        ],
      ),
    );
  }

  /// Abre el visor con TODOS los papeles del pedido (#234/#240), el mismo que
  /// usa el Historial general. El gating por rol lo aplica el SERVICE — el
  /// bool de acá es transporte, no la defensa. A diferencia del detalle, esto
  /// no pasa por callback: el visor lee sus providers de la ruta nueva (están
  /// en la raíz de la app), así que el widget sigue montable sin ellos.
  void _verAdjuntos(Pedido ped) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PantallaVisorRemito.deAdjuntosDePedido(
          pedidoId: ped.id,
          puedeVerFinanzas: widget.puedeVerFinanzas,
          titulo: widget.puedeVerFinanzas
              ? 'Adjuntos · ${ped.proveedorNombre}'
              : 'Remito · ${ped.proveedorNombre}',
        ),
      ),
    );
  }

  /// Listado sin scroll propio: ver la advertencia del docstring de la clase.
  ///
  /// Sin padding horizontal a propósito: el margen contra el borde ya lo pone la
  /// ficha en su `ListView`, y agregar otro acá dejaría las tarjetas metidas
  /// hacia adentro respecto de la barra de filtros, como si fueran de otra cosa.
  /// `TarjetaPedido` ya trae su propio margen vertical.
  Widget _listado(List<Pedido> pedidos) {
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: pedidos.length,
      itemBuilder: (context, index) {
        final ped = pedidos[index];
        return TarjetaPedido(
          pedido: ped,
          puedeVerFinanzas: widget.puedeVerFinanzas,
          acciones: [
            // #240: el mismo acceso a los papeles del pedido que el Historial
            // general (#234) — la ficha no lo tenía, y lo adjuntado quedaba
            // invisible justo desde donde se repasa a un proveedor. Un pedido
            // cancelado nunca se recibió: no tiene adjuntos ni botón.
            if (ped.estado != EstadosPedido.cancelado)
              TextButton.icon(
                icon: const Icon(Icons.receipt_long, size: 14),
                label: Text(
                  widget.puedeVerFinanzas ? 'Adjuntos' : 'Remito',
                  style: const TextStyle(fontSize: 11),
                ),
                onPressed: () => _verAdjuntos(ped),
              ),
            TextButton.icon(
              icon: const Icon(Icons.assignment_outlined, size: 14),
              label: const Text('Ver detalle', style: TextStyle(fontSize: 11)),
              onPressed: () => widget.alAbrirDetalle(ped),
            ),
          ],
        );
      },
    );
  }
}
