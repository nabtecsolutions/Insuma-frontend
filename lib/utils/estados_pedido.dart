/// Estados del ciclo de vida de un Pedido y su agrupación por pantalla.
///
/// Centraliza los strings de estado y las reglas de "qué pantalla muestra qué"
/// para que las vistas (Pedidos / Recepciones / Historial) filtren con una única
/// fuente de verdad, en vez de repetir literales sueltos. Es un módulo PURO
/// (sin Flutter ni IO), fácil de testear.
class EstadosPedido {
  EstadosPedido._();

  /// En preparación, editable.
  static const borrador = 'borrador';

  /// Enviado al proveedor; falta SU confirmación (WhatsApp saliente). Pantalla Pedidos › Activos.
  ///
  /// Al usuario se le muestra como **"Sin confirmar"**: el valor interno se
  /// conserva porque está persistido y sincronizado, pero la etiqueta cambió
  /// (HU-009) para que diga qué es lo que falta.
  static const enviado = 'enviado';

  /// Confirmado por el proveedor: listo para recibir. Pantalla Recepciones.
  ///
  /// Al usuario se le muestra como **"A recibir"**. Ojo con el nombre interno:
  /// `en_espera` se lee como "esperando confirmación" y es justo lo contrario
  /// —la confirmación YA está— así que la etiqueta manda sobre la intuición.
  static const enEspera = 'en_espera';

  /// Recibido en parte; queda faltante por resolver. Pantalla Pedidos › Parciales.
  static const recibidoParcial = 'recibido_parcial';

  /// Parcial cuyo faltante ya fue re-pedido (queda resuelto → Historial).
  static const parcialCerrado = 'parcial_cerrado';

  static const recibidoCompleto = 'recibido_completo';
  static const recepcionado = 'recepcionado';
  static const facturado = 'facturado';
  static const pagado = 'pagado';
  static const cancelado = 'cancelado';

  /// Estados "cerrados" que van al Historial (RN-012).
  static const historial = <String>{
    recibidoCompleto,
    facturado,
    pagado,
    recepcionado,
    cancelado,
    parcialCerrado,
  };

  /// ¿El pedido está en el Historial (cerrado)?
  static bool esHistorial(String estado) => historial.contains(estado);

  /// Etiqueta NEUTRA de los filtros por estado: "no filtres por esto".
  ///
  /// Vive con las demás etiquetas y no suelta en cada pantalla porque hay tres
  /// piezas que tienen que coincidir en el MISMO literal —el valor por defecto
  /// de `filtrarHistorialPedidos`, la opción que `etiquetasDeEstado` antepone y
  /// el desplegable de la barra de filtros— y ninguna se entera si otra cambia:
  /// el filtro dejaría de ser neutro y la lista saldría VACÍA mostrando "Todos".
  ///
  /// No es un estado del pedido: [etiqueta] nunca lo devuelve, y por eso no
  /// puede chocar con la etiqueta de ningún estado real.
  static const String etiquetaTodos = 'Todos';

  /// Cómo se le nombra el estado al usuario (HU-151).
  ///
  /// Varios estados internos comparten etiqueta a propósito: al usuario no le
  /// dice nada la diferencia entre `recibido_completo` y `recepcionado`. Vive
  /// acá —y no en la tarjeta— para que el filtro del historial y el chip de la
  /// tarjeta usen LA MISMA, sin que el módulo puro dependa de Flutter.
  static String etiqueta(String estado) {
    switch (estado) {
      case borrador:
        return 'Borrador';
      // HU-009: se renombraron los dos estados del medio porque decían lo
      // contrario de lo que pasaba. "Enviado" no aclaraba que faltaba la
      // respuesta del proveedor, y "En espera" —que es el paso SIGUIENTE, ya
      // confirmado— sonaba menos avanzado que "Enviado" y no decía esperando
      // qué. Ahora cada etiqueta nombra lo que falta:
      case enviado:
        return 'Sin confirmar'; // se lo mandaste, falta que responda
      case enEspera:
        return 'A recibir'; // ya confirmó, falta que llegue
      case recibidoParcial:
        return 'Parcial';
      case parcialCerrado:
        return 'Parcial re-pedido';
      case recibidoCompleto:
      case recepcionado:
        return 'Recibido';
      case facturado:
      case pagado:
        return 'Facturado';
      case cancelado:
        return 'Cancelado';
      default:
        return estado;
    }
  }

  /// El estado que muestra cada solapa del ciclo EN CURSO (pantalla Pedidos).
  /// Fuente única para el filtro de la lista y para el contador por pestaña
  /// (#252), así ambos no pueden divergir. `en_espera` (A recibir) va a
  /// Recepciones y los cerrados al Historial: ninguno figura acá.
  static const Map<PestanaPedido, String> estadoDePestana = {
    PestanaPedido.activos: enviado,
    PestanaPedido.borradores: borrador,
    PestanaPedido.parciales: recibidoParcial,
  };

  /// A qué solapa de Pedidos pertenece un estado, o `null` si no va a ninguna
  /// de las tres (historial, `en_espera`, etc.).
  static PestanaPedido? pestanaDe(String estado) {
    for (final e in estadoDePestana.entries) {
      if (e.value == estado) return e.key;
    }
    return null;
  }

  /// Cuenta, en UN solo recorrido, cuántos pedidos caen en cada solapa. Recibe
  /// los estados (no las entidades) para no depender de Flutter ni del modelo.
  /// Los estados que no pertenecen a ninguna solapa (historial, `en_espera`) no
  /// se cuentan.
  static Map<PestanaPedido, int> contarPorPestana(Iterable<String> estados) {
    final conteo = {for (final p in PestanaPedido.values) p: 0};
    for (final estado in estados) {
      final p = pestanaDe(estado);
      if (p != null) conteo[p] = conteo[p]! + 1;
    }
    return conteo;
  }
}

/// Las tres solapas del ciclo del pedido EN CURSO (pantalla Pedidos): activos
/// (enviados, esperando confirmación), borradores (en preparación) y parciales
/// (recibidos en parte). Es la fuente de verdad compartida entre la vista y el
/// contador (#252); reemplaza al enum privado que tenía la pantalla.
enum PestanaPedido { activos, borradores, parciales }
