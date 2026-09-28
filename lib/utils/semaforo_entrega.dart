/// Semáforo de entrega de una recepción (#268).
///
/// Responde de un vistazo "¿esta entrega está vencida, es de hoy o viene en
/// camino?", y con cuántos días de diferencia, que es lo que se le reclama al
/// proveedor.
///
/// Módulo PURO —sin Flutter y sin base de datos propia— y con el día de
/// referencia SIEMPRE inyectado, igual que `ventana_recepciones.dart`: leer el
/// reloj acá adentro haría que dos filas de la misma lista se evalúen contra
/// días distintos si el refresco cruza la medianoche.
///
/// **El signo de [SemaforoEntrega.dias] es un contrato, no una preferencia.**
/// Es `b - a` sobre `FechaRecepcion.diasEntre(hoy, entrega)`: futuro POSITIVO,
/// hoy CERO, vencido NEGATIVO. La HU hermana de las secciones deriva su
/// "Mañana" de `dias == 1` en vez de agregar una quinta categoría, así que
/// invertir el signo la rompe en silencio — daría "Mañana" para lo vencido de
/// ayer. Quien muestre la demora al usuario la pasa por [diasDeDemora].
///
/// ⚠ NO se le agrega una categoría `manana`. El enum tiene cuatro valores y los
/// días son el dato fino: cualquier corte más ("esta semana", "pasado mañana")
/// se deriva de [SemaforoEntrega.dias] sin tocar este archivo.
library;

import '../database/database.dart';
import 'fecha_recepcion.dart';

/// Las cuatro situaciones en que puede estar una entrega.
enum CategoriaEntrega {
  /// La fecha pedida ya pasó: hay un compromiso abierto con el proveedor.
  vencido,

  /// Llega hoy.
  hoy,

  /// Todavía no llegó su día.
  proximo,

  /// Nunca se cargó una fecha. No es un caso de borde: el campo es OPCIONAL
  /// por decisión del PO, y son justo las entregas que hay que resolver ya.
  sinFecha,
}

/// Cómo está una entrega y con cuántos días de diferencia.
class SemaforoEntrega {
  final CategoriaEntrega categoria;

  /// Días de calendario de hoy a la entrega, con SIGNO (ver la nota de la
  /// librería). `null` sólo cuando la categoría es [CategoriaEntrega.sinFecha]:
  /// sin fecha no hay distancia que calcular, y un 0 ahí se confundiría con
  /// "llega hoy".
  final int? dias;

  const SemaforoEntrega({required this.categoria, required this.dias});

  /// Clasifica una fecha de entrega contra [hoy].
  ///
  /// Se expone aparte de [semaforoDePedido] porque la HU de las secciones
  /// agrupa por categoría sin volver a mirar el estado del pedido, y porque es
  /// la forma de testear la regla de fechas sola.
  factory SemaforoEntrega.deFecha(DateTime? entrega, {required DateTime hoy}) {
    if (entrega == null) {
      return const SemaforoEntrega(
        categoria: CategoriaEntrega.sinFecha,
        dias: null,
      );
    }
    final dias = FechaRecepcion.diasEntre(hoy, entrega);
    // El orden de los cortes importa: `hoy` es EXACTAMENTE 0, no "menos de un
    // día". Con `dias <= 0` una entrega de ayer se mostraría como si llegara
    // hoy y nadie la reclamaría.
    final categoria = dias < 0
        ? CategoriaEntrega.vencido
        : dias == 0
        ? CategoriaEntrega.hoy
        : CategoriaEntrega.proximo;
    return SemaforoEntrega(categoria: categoria, dias: dias);
  }

  /// Días de DEMORA, siempre positivos, para mostrarle al usuario.
  ///
  /// Existe para que ninguna pantalla escriba el `-dias` a mano: es la clase de
  /// cuenta que alguien copia con el signo al revés y termina anunciando "-3
  /// días de demora".
  int get diasDeDemora => dias == null ? 0 : (dias! < 0 ? -dias! : dias!);

  bool get estaVencida => categoria == CategoriaEntrega.vencido;
}

/// El semáforo de [pedido], o `null` si a este pedido no le corresponde.
///
/// ⚠ El filtro por estado vive ACÁ y no en la pantalla, aunque la pantalla de
/// Recepciones ya liste sólo pedidos en [estadoPendiente]. Si se apoyara en ese
/// filtro, la regla no tendría dónde ser probada: un test contra la pantalla
/// pasaría con la regla y sin ella, porque el listado nunca le da un pedido de
/// otro estado. Mismo motivo por el que `serieFrenada` mira el estado.
///
/// Y el motivo de producto (decisión del PO del 2026-09-26): un pedido `enviado`
/// que el proveedor TODAVÍA no confirmó no lleva semáforo. Mostrar "llega en 2
/// días" afirmaría una entrega que nadie prometió.
SemaforoEntrega? semaforoDePedido(
  Pedido pedido, {
  required DateTime hoy,
  required String estadoPendiente,
}) {
  if (pedido.estado != estadoPendiente) return null;
  return SemaforoEntrega.deFecha(pedido.fechaRecepcionSolicitada, hoy: hoy);
}

/// Texto corto del semáforo, tal como se lee en la tarjeta.
///
/// Vive en el módulo puro y no en el widget porque es la parte que se puede
/// probar sin levantar Flutter, y porque la HU de las secciones necesita los
/// mismos rótulos en sus encabezados.
String etiquetaSemaforo(SemaforoEntrega s) {
  switch (s.categoria) {
    case CategoriaEntrega.sinFecha:
      return 'Sin fecha';
    case CategoriaEntrega.hoy:
      return 'Llega hoy';
    case CategoriaEntrega.vencido:
      final d = s.diasDeDemora;
      return d == 1 ? 'Atrasada 1 día' : 'Atrasada $d días';
    case CategoriaEntrega.proximo:
      final d = s.diasDeDemora;
      return d == 1 ? 'Llega mañana' : 'Llega en $d días';
  }
}
