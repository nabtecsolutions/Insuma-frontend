import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/servicio_sesion.dart';
import '../../../theme/insuma_colors.dart';
import '../../configuracion/motivos_recepcion_screen.dart';
import '../../configuracion/categorias_screen.dart';
import '../../configuracion/pantalla_configuracion.dart';
import '../../historial_pedidos_screen.dart';
import '../../insumos/insumos_screen.dart';
import '../../pagos/pagos_screen.dart';
import '../navegacion_dashboard.dart';

/// Menú lateral de administración (HU-048).
///
/// Esta clase NO decide qué se ve —eso lo resuelve [entradasVisibles], que es
/// una regla pura con tests—, sólo traduce cada entrada a su ícono y su
/// pantalla.
///
/// Sumar una entrada (Configuración, Auditoría, Reportes…) es agregar un valor
/// a [ItemMenu], con su título, su sección y su permiso; los dos `switch` de
/// abajo son EXHAUSTIVOS, así que el compilador exige completar ícono y
/// destino. No se puede agregar una entrada a medias.
///
/// Lo que NO hay que hacer es escribir un `ListTile` a mano en el `ListView`:
/// saltearía [entradasVisibles] y la entrada quedaría visible para todos los
/// roles. Todo lo que se dibuja acá sale de `entradas`.
///
/// Vivía dentro de `dashboard_screen.dart`, que ya pasaba las 600 líneas: cada
/// sección nueva lo engordaba y el menú no se podía testear por separado.
class MenuLateral extends StatelessWidget {
  const MenuLateral({super.key});

  @override
  Widget build(BuildContext context) {
    // `watch` y no `read`: el rol de la sesión puede cambiar sin salir de la
    // pantalla (un pull que reconcilia la identidad, un cambio de negocio del
    // SuperAdmin), y el menú tiene que seguirlo.
    final rol = context.watch<ServicioSesion>().usuarioRol;
    final entradas = entradasVisiblesDeRol(rol);

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Menú',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
            // Se recorren TODAS las secciones, no dos listas escritas a mano:
            // con `.where` hardcodeados, una sección nueva compilaba, pasaba los
            // tests y no se renderizaba nunca — justo el criterio de la HU que
            // esto viene a cumplir.
            for (final seccion in SeccionMenu.values)
              ..._bloqueDe(
                context,
                seccion,
                entradas.where((e) => e.seccion == seccion).toList(),
              ),
          ],
        ),
      ),
    );
  }

  /// Un bloque del menú: separador, encabezado (si lo tiene) y sus entradas.
  ///
  /// Sin entradas devuelve vacío: la sección no existe para ese usuario, ni
  /// siquiera su encabezado (HU-077).
  List<Widget> _bloqueDe(
    BuildContext context,
    SeccionMenu seccion,
    List<ItemMenu> entradas,
  ) {
    if (entradas.isEmpty) return const [];
    return [
      const Divider(height: 1),
      if (seccion.encabezado.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Text(
            seccion.encabezado,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
        ),
      ...entradas.map((e) => _tile(context, e)),
    ];
  }

  Widget _tile(BuildContext context, ItemMenu item) => ListTile(
    leading: Icon(_iconoDe(item), color: InsumaColors.primaryBlue),
    title: Text(item.titulo),
    onTap: () {
      // Se cierra el menú ANTES de navegar: si se hace después, el Drawer
      // queda abierto atrás y aparece al volver.
      Navigator.pop(context);
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => _pantallaDe(item)));
    },
  );

  /// Ícono de cada entrada. `switch` exhaustivo a propósito: agregar un valor al
  /// enum sin ícono es un error de compilación, no una entrada muda en la app.
  IconData _iconoDe(ItemMenu item) => switch (item) {
    ItemMenu.historialPedidos => Icons.history,
    ItemMenu.insumos => Icons.inventory_2_outlined,
    ItemMenu.pagos => Icons.receipt_long_outlined,
    ItemMenu.motivos => Icons.rule_outlined,
    ItemMenu.categorias => Icons.category_outlined,
    ItemMenu.configuracion => Icons.settings_outlined,
  };

  /// Pantalla destino de cada entrada. Exhaustivo por el mismo motivo.
  Widget _pantallaDe(ItemMenu item) => switch (item) {
    ItemMenu.historialPedidos => const PantallaHistorialPedidos(),
    ItemMenu.insumos => const PantallaInsumos(),
    ItemMenu.pagos => const PantallaPagos(),
    ItemMenu.motivos => const PantallaMotivosRecepcion(),
    ItemMenu.categorias => const PantallaCategorias(),
    ItemMenu.configuracion => const PantallaConfiguracion(),
  };
}
