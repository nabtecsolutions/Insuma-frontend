import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../database/database.dart';
import '../theme/insuma_colors.dart';
import '../controllers/controlador_recibir.dart';
import '../utils/estados_pedido.dart';
import '../utils/filtros_historial_pedidos.dart';
import 'widgets/barra_filtros_pedidos.dart';
import 'recibir/acciones_pedido_mixin.dart';
import 'recibir/widgets/tarjeta_pedido.dart';
import 'pagos/widgets/visor_remito.dart';

/// Historial de pedidos CERRADOS (recibidos, facturados, pagados, cancelados y
/// parciales ya re-pedidos). Se abre desde el menú lateral derecho; se movió fuera
/// de la pantalla de Pedidos para que ésta solo muestre trabajo en curso.
class PantallaHistorialPedidos extends StatefulWidget {
  const PantallaHistorialPedidos({super.key});

  @override
  State<PantallaHistorialPedidos> createState() =>
      _PantallaHistorialPedidosState();
}

class _PantallaHistorialPedidosState extends State<PantallaHistorialPedidos>
    with AccionesPedidoMixin {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ctrlRecibir.cargarSesionYPedidos(),
    );
  }

  // ── Estado de los filtros (HU-151) ────────────────────────────────────────
  //
  // La barra en sí es [BarraFiltrosPedidos], compartida con el historial de la
  // ficha del proveedor (HU-009): dueña de los controllers, del saneo del estado
  // y del botón "Limpiar". Acá sólo queda lo ELEGIDO, porque es esta pantalla la
  // que sabe sobre qué lista filtrar.
  CriteriosFiltroPedidos _criterios = CriteriosFiltroPedidos.vacio;

  /// La barra vive dentro del árbol, pero el atajo "Limpiar filtros" del estado
  /// "ningún resultado" es de esta pantalla: la key es el único modo de que ese
  /// botón vacíe también el TEXTO VISIBLE de los campos (#170).
  ///
  /// Va como campo del State y NO se crea en `build`: una key nueva por build
  /// destruiría y recrearía la barra —y con ella los controllers— en cada tecla.
  final _barraFiltros = GlobalKey<BarraFiltrosPedidosState>();

  void _limpiarFiltros() => _barraFiltros.currentState?.limpiar();

  /// Aplica TODOS los criterios activos y, si corresponde, el orden por entrega.
  ///
  /// Existe un único lugar donde se arman los argumentos a propósito: antes esto
  /// estaba duplicado entre `build` y el contador de resultados, y cada filtro
  /// nuevo había que acordarse de sumarlo en los dos —si no, el contador decía
  /// un número y la lista mostraba otro.
  ///
  /// El estado se sanea ACÁ contra las opciones vigentes: la barra avisa la
  /// elección CRUDA para no perderla si la etiqueta reaparece, así que filtrar
  /// por ella sin sanear dejaría la lista vacía justo cuando el desplegable
  /// muestra "Todos" (#170).
  List<Pedido> _aplicarFiltros(List<Pedido> historial, List<String> opciones) {
    final c = _criterios.vigenteEntre(opciones);
    final filtrados = filtrarHistorialPedidos(
      historial,
      proveedor: c.proveedor,
      articulo: c.articulo,
      desde: c.rangoFechas?.start,
      hasta: c.rangoFechas?.end,
      etiquetaEstado: c.etiquetaEstado,
      montoMin: c.montoMin,
      montoMax: c.montoMax,
      entregaDesde: c.rangoEntrega?.start,
      entregaHasta: c.rangoEntrega?.end,
    );
    if (c.ordenEntregaAscendente == null) return filtrados;
    return ordenarPorEntregaSolicitada(
      filtrados,
      ascendente: c.ordenEntregaAscendente!,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<ControladorRecibir>();
    final historial = ctrl.pedidos
        .where((p) => EstadosPedido.esHistorial(p.estado))
        .toList();

    // #170: las opciones del dropdown salen de la lista REACTIVA de pedidos, así
    // que la etiqueta elegida puede desaparecer sola. Se calculan UNA vez y se
    // pasan hacia abajo: el dropdown, el filtrado, el contador y el botón
    // "Limpiar" tienen que estar de acuerdo sobre qué estado está vigente.
    final opcionesEstado = etiquetasDeEstado(historial);

    // El filtrado es una transformación PURA sobre lo que ya está en memoria:
    // ninguna consulta nueva, para no romper la reactividad de HU-089. Se hace
    // UNA sola vez por build y el resultado se reusa para la lista y para el
    // contador; antes se calculaba dos veces, y con el filtro de artículo cada
    // pasada hace un jsonDecode por pedido.
    final filtrados = _aplicarFiltros(historial, opcionesEstado);

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        foregroundColor: Colors.black87,
        title: const Text(
          'Historial de Pedidos',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
      ),
      body: ctrl.cargando
          ? const Center(child: CircularProgressIndicator())
          : historial.isEmpty
          // Sin historial NO se muestran filtros: no hay nada que filtrar.
          ? _vacio()
          : Column(
              children: [
                // El contador de resultados sale de la pasada que ya hizo
                // este `build`: repetirla adentro de la barra costaría un
                // `jsonDecode` por pedido y por tecla, y podría discrepar
                // con lo que se está listando.
                BarraFiltrosPedidos(
                  key: _barraFiltros,
                  opcionesEstado: opcionesEstado,
                  cantidadResultados: filtrados.length,
                  puedeVerFinanzas: puedeVerFinanzas,
                  // Sin historial la barra sale del árbol (rama de arriba)
                  // y vuelve con los controllers en blanco. Sembrándola con
                  // lo que esta pantalla tiene guardado, ese ida y vuelta no
                  // borra los filtros —que es lo que pasaba cuando vivían
                  // en el State de la pantalla—.
                  criteriosIniciales: _criterios,
                  alCambiar: (c) => setState(() => _criterios = c),
                ),
                Expanded(
                  child: filtrados.isEmpty
                      ? _sinResultados()
                      : _listado(filtrados),
                ),
              ],
            ),
    );
  }

  /// Distinto del historial vacío: acá SÍ hay pedidos, no coinciden con lo pedido.
  Widget _sinResultados() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 48, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text(
            'Ningún pedido coincide con los filtros',
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

  /// Abre el visor con los adjuntos del pedido (#234), reutilizando el mismo
  /// visor que Pagos. Para el admin junta remitos + facturas + comprobantes;
  /// para el cocinero la degradación a solo-remitos la aplica el SERVICE
  /// (gating por rol) — el bool de acá es transporte, no la defensa.
  void _verAdjuntos(Pedido ped) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PantallaVisorRemito.deAdjuntosDePedido(
          pedidoId: ped.id,
          puedeVerFinanzas: puedeVerFinanzas,
          titulo: puedeVerFinanzas
              ? 'Adjuntos · ${ped.proveedorNombre}'
              : 'Remito · ${ped.proveedorNombre}',
        ),
      ),
    );
  }

  Widget _vacio() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history, size: 48, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text(
            'No hay pedidos en el historial',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _listado(List<Pedido> historial) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: historial.length,
      itemBuilder: (context, index) {
        final ped = historial[index];
        return TarjetaPedido(
          pedido: ped,
          puedeVerFinanzas: puedeVerFinanzas,
          acciones: [
            // Los pedidos cancelados nunca se recibieron: no tienen adjuntos.
            if (ped.estado != EstadosPedido.cancelado) ...[
              TextButton.icon(
                icon: const Icon(Icons.receipt_long, size: 14),
                // #234: el admin ve TODOS los papeles del pedido en un solo
                // lugar; para el cocinero sigue siendo (y diciendo) "Remito".
                label: Text(
                  puedeVerFinanzas ? 'Adjuntos' : 'Remito',
                  style: const TextStyle(fontSize: 11),
                ),
                onPressed: () => _verAdjuntos(ped),
              ),
            ],
            TextButton.icon(
              icon: const Icon(Icons.replay, size: 14),
              label: const Text('Repetir', style: TextStyle(fontSize: 11)),
              onPressed: () => repetirPedido(ped),
            ),
            TextButton.icon(
              icon: const Icon(Icons.assignment_outlined, size: 14),
              label: const Text('Detalle', style: TextStyle(fontSize: 11)),
              onPressed: () => verDetallePedido(ped),
            ),
          ],
        );
      },
    );
  }
}
