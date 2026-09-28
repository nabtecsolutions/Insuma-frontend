import 'estados_pedido.dart';

/// Matriz de transiciones VÁLIDAS del ciclo de vida de un Pedido (HU-141).
///
/// Única fuente de verdad de "desde qué estado se puede pasar a cuál". Antes de
/// esta HU cada servicio escribía `pedidos.estado` por su cuenta (pedidos,
/// recepciones, facturación) sin validar el estado de partida; el server ya no
/// deriva nada (HU-121 eliminó el trigger): la app es autoritativa, así que la
/// validación tiene que vivir acá, en un módulo PURO (sin Flutter ni IO).
///
/// Los servicios que escriben estado dentro de sus propias transacciones
/// ([ServicioRecepciones], [ServicioFacturacion]) VALIDAN con [puede] antes de
/// escribir; los cambios "solo estado" (cancelar, confirmar, cerrar parcial,
/// descartar) pasan por `ServicioTransicionesPedido`, que además audita.
class TransicionesPedido {
  TransicionesPedido._();

  /// Desde cada estado, a qué estados se puede pasar.
  ///
  /// La transición identidad (p. ej. `enviado → enviado`) sólo figura donde un
  /// re-guardado legítimo la necesita: re-editar un enviado (HU-141) o registrar
  /// otra recepción sobre un parcial (HU-064). `pagado` y `cancelado` son
  /// terminales; `recepcionado` es legacy y sólo puede avanzar a facturado.
  static const Map<String, Set<String>> permitidas = {
    EstadosPedido.borrador: {EstadosPedido.enviado},
    EstadosPedido.enviado: {
      EstadosPedido.enviado,
      EstadosPedido.enEspera,
      EstadosPedido.cancelado,
    },
    EstadosPedido.enEspera: {
      EstadosPedido.recibidoParcial,
      EstadosPedido.recibidoCompleto,
      // Cierre sin parcial ante diferencias (HU-145): en_espera → parcial_cerrado
      // en la misma recepción, sin pasar por recibido_parcial.
      EstadosPedido.parcialCerrado,
      // Recepción con pago en efectivo (RN-014): saltea la cuenta corriente.
      EstadosPedido.facturado,
      // Cancelable SOLO si aún no tiene recepciones; esa regla necesita datos y
      // la aplica ServicioTransicionesPedido.cancelar, no la matriz.
      EstadosPedido.cancelado,
    },
    EstadosPedido.recibidoParcial: {
      EstadosPedido.recibidoParcial,
      EstadosPedido.recibidoCompleto,
      EstadosPedido.parcialCerrado,
      EstadosPedido.facturado,
    },
    EstadosPedido.recibidoCompleto: {EstadosPedido.facturado},
    EstadosPedido.parcialCerrado: {EstadosPedido.facturado},
    EstadosPedido.recepcionado: {EstadosPedido.facturado},
    EstadosPedido.facturado: {EstadosPedido.pagado},
    EstadosPedido.pagado: {},
    EstadosPedido.cancelado: {},
  };

  /// ¿Es válido pasar de [desde] a [hacia]?
  /// Un estado desconocido no tiene transiciones (falla cerrado).
  static bool puede(String desde, String hacia) =>
      permitidas[desde]?.contains(hacia) ?? false;

  /// ¿El contenido del pedido se puede editar? Borrador siempre; enviado sólo
  /// re-enviándose (el proveedor todavía no lo confirmó). Desde en_espera la
  /// mercadería ya está comprometida: no se edita, se recibe o se cancela.
  static bool esEditable(String estado) =>
      estado == EstadosPedido.borrador || estado == EstadosPedido.enviado;

  /// ¿Se puede cancelar? La regla extra de en_espera (sin recepciones) la
  /// aplica el servicio, que es quien puede consultarlas.
  static bool esCancelable(String estado) =>
      estado == EstadosPedido.enviado || estado == EstadosPedido.enEspera;

  /// ¿Se puede eliminar físicamente? SÓLO borradores: un pedido que ya viajó
  /// al proveedor se cancela (queda la traza), no desaparece.
  static bool esEliminable(String estado) => estado == EstadosPedido.borrador;

  /// ¿Se le puede mover la fecha de entrega? (#269)
  ///
  /// Los mismos estados que [esCancelable], y no es por comodidad: son los dos
  /// estados en los que la entrega TODAVÍA NO PASÓ. Un pedido recibido, pagado
  /// o cancelado tiene una fecha que ya es historia, y cambiarla reescribiría
  /// el pasado: los reportes y el historial de precios quedarían contando la
  /// compra en un día en el que no ocurrió.
  ///
  /// Un borrador queda afuera aunque nada se haya comprometido: su fecha se
  /// edita en el formulario del pedido, que es donde se edita todo lo demás.
  static bool esReprogramable(String estado) =>
      estado == EstadosPedido.enviado || estado == EstadosPedido.enEspera;
}
