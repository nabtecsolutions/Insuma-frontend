import 'package:flutter/material.dart';
import '../../../database/database.dart';
import '../../../theme/insuma_colors.dart';
import '../../../utils/estados_pedido.dart';
import '../../../utils/fecha_recepcion.dart';
import '../../../utils/semaforo_entrega.dart';

/// Tarjeta reutilizable de un Pedido (HU-051 / split Pedidos-Recepciones).
///
/// Es SOLO presentación: encabezado (proveedor + badge de estado), resumen
/// (fecha, total si corresponde, quién recibió) y un slot de [acciones] que cada
/// pantalla (Pedidos / Recepciones / Historial) inyecta según el contexto. Así
/// las tres vistas comparten el mismo look sin duplicar el layout (DRY).
/// Llave de la botonera inferior. Pública a propósito: el test de #180 la mide
/// por separado, y desde #268 la tarjeta tiene dos `Wrap`.
const Key claveAcciones = Key('tarjeta-pedido-acciones');

/// Llave de la línea de fecha + semáforo (#268).
const Key claveLineaFecha = Key('tarjeta-pedido-linea-fecha');

class TarjetaPedido extends StatelessWidget {
  final Pedido pedido;
  final bool puedeVerFinanzas;

  /// Botonera inferior específica de cada pantalla. Se alinea a la derecha.
  ///
  /// ⚠ Se renderiza en un `Wrap` (#180): las acciones BAJAN de renglón cuando no
  /// entran. No metas separadores `SizedBox(width: ...)` entre ellas — son un
  /// hijo más del `Wrap`, ocupan lugar y pueden quedar al principio de una
  /// corrida dejando el renglón desalineado. La separación la pone el `spacing`.
  final List<Widget> acciones;

  /// HU-013: muestra la franja de "la serie está esperando esta entrega".
  ///
  /// ⚠ Llega ya DECIDIDO y esta tarjeta no lo calcula, aunque tenga todos los
  /// datos para hacerlo. Si lo dedujera sola con "es de agenda y la fecha ya
  /// pasó", TODA entrega recurrente ya recibida del Historial se pintaría con el
  /// aviso — porque por definición tiene fecha pasada. La regla mira también el
  /// estado y vive en `utils/ventana_recepciones.dart`; sólo Recepciones la pasa
  /// en `true`.
  final bool serieFrenada;

  /// #269: menú de tres puntos del encabezado, o `null` si esta pantalla no
  /// ofrece ninguna acción sobre la tarjeta.
  ///
  /// Va en el ENCABEZADO y no en la botonera de abajo por dos motivos. El
  /// primero es que la botonera ya desbordaba a 360 dp (#180) y sumarle un
  /// botón más sería volver al mismo problema; sacar "Cancelar" de ahí, de
  /// hecho, le devuelve lugar. El segundo es que la línea de la fecha está
  /// tomada por el semáforo de #268.
  ///
  /// Lo arma la PANTALLA, igual que [acciones]: cada una sabe qué puede hacer
  /// con sus pedidos. La tarjeta no decide nada.
  final Widget? menu;

  /// #268: cómo está la entrega (vencida / hoy / próxima / sin fecha).
  ///
  /// ⚠ Llega ya DECIDIDO, por el mismo motivo que [serieFrenada]: la regla mira
  /// el ESTADO del pedido, y esta tarjeta la comparten cuatro pantallas. Si la
  /// tarjeta la calculara sola, el Historial pintaría "Atrasada 40 días" sobre
  /// entregas que se recibieron sin problema hace un mes —porque por definición
  /// tienen fecha pasada—. Sólo Recepciones lo pasa; las otras tres lo dejan en
  /// `null` y no cambian en nada.
  final SemaforoEntrega? semaforo;

  const TarjetaPedido({
    super.key,
    required this.pedido,
    required this.puedeVerFinanzas,
    required this.acciones,
    this.serieFrenada = false,
    this.semaforo,
    this.menu,
  });

  /// Color + texto del badge según el estado del pedido.
  /// Color y texto del chip de estado.
  ///
  /// HU-151: el TEXTO sale de `EstadosPedido.etiqueta`, que es puro y lo comparte
  /// con el filtro del historial. Acá queda sólo el color, que sí es de UI.
  static ({Color color, String texto}) badgeDe(String estado) {
    late final Color color;
    switch (estado) {
      case EstadosPedido.borrador:
      case EstadosPedido.parcialCerrado:
        color = Colors.blueGrey;
      case EstadosPedido.recibidoParcial:
        color = Colors.amber.shade800;
      case EstadosPedido.recibidoCompleto:
      case EstadosPedido.recepcionado:
        color = Colors.green;
      case EstadosPedido.facturado:
      case EstadosPedido.pagado:
        color = Colors.teal;
      case EstadosPedido.cancelado:
        color = Colors.redAccent;
      // #268: hasta acá caía en el `default: Colors.orange`, el MISMO que
      // `enviado` ("Sin confirmar"). Los dos conviven en la ficha del
      // proveedor, que lista todos los estados a propósito, así que los dos
      // chips que más falta hacía distinguir eran iguales.
      case EstadosPedido.enEspera:
        color = InsumaColors.estadoARecibir;
      default:
        color = Colors.orange;
    }
    return (color: color, texto: EstadosPedido.etiqueta(estado));
  }

  /// Par fondo/texto de cada categoría del semáforo (#268).
  ///
  /// Los pares viven en el tema y no acá: el aviso de serie frenada de esta
  /// misma tarjeta eligió su color de texto a ojo sobre `alertYellow`, y eso es
  /// exactamente lo que no conviene repetir cuatro veces.
  static ({Color bg, Color fg}) _coloresDe(CategoriaEntrega c) {
    switch (c) {
      case CategoriaEntrega.vencido:
        return (
          bg: InsumaColors.entregaVencidaBg,
          fg: InsumaColors.entregaVencidaFg,
        );
      case CategoriaEntrega.hoy:
        return (bg: InsumaColors.entregaHoyBg, fg: InsumaColors.entregaHoyFg);
      case CategoriaEntrega.proximo:
        return (
          bg: InsumaColors.entregaProximaBg,
          fg: InsumaColors.entregaProximaFg,
        );
      case CategoriaEntrega.sinFecha:
        return (
          bg: InsumaColors.entregaSinFechaBg,
          fg: InsumaColors.entregaSinFechaFg,
        );
    }
  }

  /// El chip del semáforo. El TEXTO sale del módulo puro `etiquetaSemaforo`
  /// —que es donde se puede probar sin levantar Flutter, y donde lo van a reusar
  /// los encabezados de las secciones de #277—; acá queda sólo el color.
  Widget _chipSemaforo(SemaforoEntrega s) {
    final c = _coloresDe(s.categoria);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        etiquetaSemaforo(s),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: c.fg,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = pedido.total ?? 0.0;
    final fecha = pedido.fechaCreacion.toLocal();
    final badge = badgeDe(pedido.estado);

    return Card(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: InsumaColors.cardBorderLight),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      // HU-013: distingue de un vistazo la entrega que nació de
                      // un pedido recurrente. Va pegado al nombre del proveedor
                      // y no como un badge aparte, para no competir con el chip
                      // de estado que ya ocupa la derecha.
                      if (pedido.agendaId != null) ...[
                        Tooltip(
                          message: 'Entrega de un pedido recurrente',
                          child: Icon(
                            Icons.autorenew,
                            size: 15,
                            color: InsumaColors.primaryBlue,
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Expanded(
                        child: Text(
                          pedido.proveedorNombre,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: badge.color.withAlpha(25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    badge.texto,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: badge.color,
                    ),
                  ),
                ),
                // #269: a la derecha del chip de estado. El `menu` que llega ya
                // trae su propio alto tocable de 48 dp; acá sólo se le saca el
                // aire de más para que el encabezado no crezca.
                if (menu != null) ...[const SizedBox(width: 2), menu!],
              ],
            ),
            const SizedBox(height: 6),
            Text(
              puedeVerFinanzas
                  ? 'Creado: ${fecha.day}/${fecha.month}/${fecha.year} · Total: \$${total.toStringAsFixed(2)}'
                  : 'Creado: ${fecha.day}/${fecha.month}/${fecha.year}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            // HU-142: el día pedido de recepción, sólo si se cargó. Va en una
            // línea propia y con ícono para que se lea de un vistazo en la lista.
            // #268: el semáforo va ACÁ, en la línea de la fecha, y no en el
            // encabezado de la tarjeta: ese lugar queda libre a propósito para
            // el menú de tres puntos de #269.
            //
            // La condición mira las DOS cosas porque un pedido sin fecha sí
            // tiene semáforo ("Sin fecha"), y hasta #268 esta línea entera no
            // se dibujaba en ese caso.
            if (pedido.fechaRecepcionSolicitada != null ||
                semaforo != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(
                    Icons.event_outlined,
                    size: 12,
                    color: Colors.grey,
                  ),
                  const SizedBox(width: 4),
                  // #180: `Expanded`, no un `Text` suelto. Es el mismo defecto
                  // que la fila de acciones y estaba en la misma tarjeta: sin
                  // él, "Se pidió para el 21/08/2026" desbordaba 12 px a 360 dp.
                  // Con `Expanded` el texto se acomoda solo —y baja de renglón
                  // si hace falta— en vez de recortarse contra el borde.
                  Expanded(
                    // #268: `Wrap` y no un `Row`, por lo MISMO que la botonera
                    // de abajo (#180). Sumarle el chip a esta línea la vuelve a
                    // poner al límite: el texto de la fecha ya desbordaba solo
                    // a 360 dp, y la app compone su propio factor de tipografía
                    // hasta 1.3x (HU-054). Con `Wrap` el chip baja de renglón;
                    // en un `Row` se recortaría.
                    child: Wrap(
                      // #268: con llave, y la botonera de abajo también. Desde
                      // que esta línea es un `Wrap`, la tarjeta tiene DOS, y un
                      // `find.byType(Wrap)` —que es como el test de #180 medía
                      // la botonera— encuentra los dos y falla por ambigüedad.
                      key: claveLineaFecha,
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (pedido.fechaRecepcionSolicitada != null)
                          Text(
                            'Se pidió para el ${FechaRecepcion.formatear(pedido.fechaRecepcionSolicitada)}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                        if (semaforo != null) _chipSemaforo(semaforo!),
                      ],
                    ),
                  ),
                ],
              ),
            ],
            if (pedido.recepcionadoPorNombre != null ||
                pedido.recepcionadoPor != null) ...[
              const SizedBox(height: 4),
              Text(
                'Recibido por: ${pedido.recepcionadoPorNombre ?? pedido.recepcionadoPor}',
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            // HU-013: el freno de la serie TIENE que verse. El PO eligió la
            // regla dura sin gracia sabiendo el riesgo: si nadie recepciona,
            // la serie se congela para siempre y nadie se entera.
            if (serieFrenada) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: InsumaColors.alertYellow,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.hourglass_bottom,
                      size: 14,
                      color: Colors.orange.shade900,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Esperando recibir desde el '
                        '${FechaRecepcion.formatear(pedido.fechaRecepcionSolicitada)}. '
                        'La próxima se agenda recién cuando recibas ésta.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Divider(height: 16),
            // #180: `Wrap`, NO `Row`. Un `Row` no tiene a dónde achicar sus
            // hijos, y estas botoneras no entran en un telefono: Recepciones
            // —icono + "Verificar y Recibir" + "Cancelar"— desbordaba a 360 dp,
            // recortando el borde derecho del boton MAS importante de esa
            // pantalla. Y el ancho no es fijo: la app compone su propio factor
            // de tipografia (hasta 1.3x, HU-054) con el del sistema, asi que
            // cualquier fila que hoy entre justo revienta al agrandar el texto.
            // Al bajar de renglon cada accion conserva sus 48 dp de alto, que
            // es lo que se toca con el pulgar; achicarlas con `Flexible` +
            // ellipsis dejaria "Verificar y Rec..." y un blanco mas chico.
            Wrap(
              key: claveAcciones,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              // 8 y no 4: al bajar de renglón, "Cancelar" queda justo debajo de
              // la acción principal y con el mismo borde derecho. Los
              // separadores viejos usaban 8 antes de la acción destructiva
              // —distinción que el `spacing` uniforme borra—, así que el aire
              // entre corridas es lo que queda para que el pulgar no se
              // equivoque de botón.
              runSpacing: 8,
              children: acciones,
            ),
          ],
        ),
      ),
    );
  }
}
