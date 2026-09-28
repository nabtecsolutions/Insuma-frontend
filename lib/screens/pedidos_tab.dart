import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../database/database.dart';
import '../theme/insuma_colors.dart';
import '../controllers/controlador_recibir.dart';
import '../utils/estados_pedido.dart';
import 'recibir/acciones_pedido_mixin.dart';
import 'recibir/widgets/tarjeta_pedido.dart';

/// Pantalla de PEDIDOS: crear pedidos/borradores y hacerles seguimiento hasta que
/// el proveedor confirma. La RECEPCIÓN física vive en su propia pantalla; el
/// Historial (cerrados) se abre desde el menú lateral derecho.
class PestanaPedidos extends StatefulWidget {
  const PestanaPedidos({super.key});

  @override
  State<PestanaPedidos> createState() => _PestanaPedidosState();
}

class _PestanaPedidosState extends State<PestanaPedidos>
    with AccionesPedidoMixin {
  PestanaPedido _vista = PestanaPedido.activos;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ctrlRecibir.cargarSesionYPedidos(),
    );
  }

  /// Filtra los pedidos según la solapa activa. Comparte con el contador (#252)
  /// la MISMA regla estado→solapa ([EstadosPedido.pestanaDe]), así lista y badge
  /// nunca pueden discrepar.
  List<Pedido> _filtrar(List<Pedido> pedidos) => pedidos
      .where((p) => EstadosPedido.pestanaDe(p.estado) == _vista)
      .toList();

  String get _mensajeVacio {
    switch (_vista) {
      case PestanaPedido.activos:
        return 'No hay pedidos esperando confirmación';
      case PestanaPedido.borradores:
        return 'No hay borradores en preparación';
      case PestanaPedido.parciales:
        return 'No hay pedidos parciales';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<ControladorRecibir>();
    if (ctrl.cargando) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // #252: los tres conteos salen de la MISMA foto (ctrl.pedidos) que alimenta
    // el listado, en un solo recorrido, para que badge y lista no discrepen.
    final conteos = EstadosPedido.contarPorPestana(
      ctrl.pedidos.map((p) => p.estado),
    );

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      body: Column(
        children: [
          _buildSelectorVista(conteos),
          Expanded(child: _buildListado(_filtrar(ctrl.pedidos))),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => abrirFormularioPedido(),
        backgroundColor: InsumaColors.primaryBlue,
        foregroundColor: Colors.white,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: const Icon(Icons.shopping_cart_outlined),
        label: const Text(
          'Crear Pedido / Borrador',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        ),
      ),
    );
  }

  Widget _buildSelectorVista(Map<PestanaPedido, int> conteos) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          _buildTab(
            'Activos',
            PestanaPedido.activos,
            conteos[PestanaPedido.activos] ?? 0,
          ),
          _buildTab(
            'Borradores',
            PestanaPedido.borradores,
            conteos[PestanaPedido.borradores] ?? 0,
          ),
          _buildTab(
            'Parciales',
            PestanaPedido.parciales,
            conteos[PestanaPedido.parciales] ?? 0,
          ),
        ],
      ),
    );
  }

  Widget _buildTab(String label, PestanaPedido vista, int conteo) {
    final seleccionada = _vista == vista;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _vista = vista),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: seleccionada
                    ? InsumaColors.primaryBlue
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          alignment: Alignment.center,
          // #252: el contador va pegado al nombre ("Activos (2)"). FittedBox lo
          // achica si no entra, para que no desborde en pantallas angostas.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '$label ($conteo)',
              style: TextStyle(
                fontWeight: seleccionada ? FontWeight.bold : FontWeight.normal,
                color: seleccionada
                    ? InsumaColors.primaryBlue
                    : Colors.grey[600],
                fontSize: 13,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildListado(List<Pedido> filtrados) {
    if (filtrados.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inventory_2_outlined, size: 48, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text(
              _mensajeVacio,
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: filtrados.length,
      itemBuilder: (context, index) {
        final ped = filtrados[index];
        return TarjetaPedido(
          pedido: ped,
          puedeVerFinanzas: puedeVerFinanzas,
          // #269: el menú decide solo qué ofrecer según el estado, así que las
          // tres solapas lo pasan igual. Un borrador no es cancelable ni
          // reprogramable, así que ahí `menuDePedido` devuelve null y los tres
          // puntos no se dibujan.
          menu: menuDePedido(ped),
          acciones: _accionesDe(ped),
        );
      },
    );
  }

  /// Botonera específica de cada solapa de Pedidos.
  List<Widget> _accionesDe(Pedido ped) {
    switch (_vista) {
      case PestanaPedido.activos:
        // Enviado: falta la confirmación del proveedor (HU-064). Mientras no
        // confirme, el contenido todavía se puede corregir y re-enviar (HU-141).
        return [
          IconButton(
            tooltip: 'Editar y re-enviar',
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () => editarPedidoEnviado(ped),
          ),
          IconButton(
            tooltip: 'Chatear por WhatsApp con el proveedor',
            icon: const Icon(
              Icons.chat_bubble_outline,
              color: Color(0xFF25D366),
              size: 18,
            ),
            onPressed: () => abrirChatWhatsApp(ped),
          ),
          TextButton.icon(
            icon: const Icon(Icons.handshake_outlined, size: 14),
            label: const Text(
              'Confirmar',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
            onPressed: () => confirmarPedido(ped),
          ),
        ];
      case PestanaPedido.borradores:
        return [
          TextButton.icon(
            icon: const Icon(Icons.edit, size: 14),
            label: const Text(
              'Editar Borrador',
              style: TextStyle(fontSize: 11),
            ),
            onPressed: () => abrirFormularioPedido(pedidoExistente: ped),
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline,
              color: Colors.redAccent,
              size: 18,
            ),
            onPressed: () => eliminarPedido(ped),
          ),
        ];
      case PestanaPedido.parciales:
        // Punto 4: se re-pide el faltante (editable) y vuelve al flujo de un pedido.
        // HU-145: o se DESCARTA (pasa al Historial sin reclamar; la evidencia queda).
        return [
          TextButton.icon(
            icon: const Icon(Icons.add_shopping_cart, size: 14),
            label: const Text(
              'Re-pedir faltante',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
            onPressed: () => repedirParcial(ped),
          ),
          TextButton.icon(
            icon: const Icon(Icons.assignment_outlined, size: 14),
            label: const Text('Detalle', style: TextStyle(fontSize: 11)),
            onPressed: () => verDetallePedido(ped),
          ),
          IconButton(
            tooltip: 'Descartar parcial',
            icon: const Icon(
              Icons.playlist_remove,
              color: Colors.redAccent,
              size: 18,
            ),
            onPressed: () => descartarParcial(ped),
          ),
        ];
    }
  }
}
