import 'package:flutter/material.dart';

import '../../../utils/acciones_tarjeta_pedido.dart';

/// Menú de tres puntos de una tarjeta de pedido (#269).
///
/// Estrena el patrón: antes de esta HU no había **ningún** `PopupMenuButton` ni
/// `showMenu` en toda la app. Vive en un widget propio —y no suelto en cada
/// pantalla— porque lo montan dos (Pedidos y Recepciones) y la lógica de qué
/// ofrece ya está compartida en `opcionesDeMenu`.
///
/// Las opciones deshabilitadas se MUESTRAN, con su motivo debajo, en vez de
/// desaparecer. Una acción que no está no se puede explicar, y la que hay que
/// explicar acá es la del superadministrador: puede leer todos los negocios y
/// no escribir en ninguno, así que si la acción estuviera viva guardaría un
/// cambio local que el servidor rechaza en silencio.
class MenuPedido extends StatelessWidget {
  final List<OpcionMenuPedido> opciones;
  final void Function(AccionTarjeta) alElegir;

  const MenuPedido({super.key, required this.opciones, required this.alElegir});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<AccionTarjeta>(
      tooltip: 'Acciones',
      icon: const Icon(Icons.more_vert, size: 20, color: Colors.black54),
      // El alto tocable mínimo, igual que las acciones de la botonera (#180).
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      onSelected: alElegir,
      itemBuilder: (context) => [
        for (final o in opciones)
          PopupMenuItem<AccionTarjeta>(
            value: o.accion,
            // `enabled: false` deja el ítem visible pero gris y sin respuesta,
            // que es exactamente lo que se busca: se ve que existe y se lee por
            // qué no se puede.
            enabled: o.habilitada,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(o.etiqueta, style: const TextStyle(fontSize: 13)),
                if (o.motivo != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      o.motivo!,
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
