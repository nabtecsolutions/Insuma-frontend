import '../database/database.dart';
import 'fecha_recepcion.dart';

/// Orden del listado de **Recepciones** (HU-013).
///
/// Módulo PURO, sin Flutter ni base de datos: ordena la lista que la pantalla ya
/// tiene en memoria. Es a propósito — `_queryPorNegocio` ordena por
/// `fechaActualizacion DESC` y lo comparten Pedidos, Recepciones e Historial, así
/// que cambiar ese `ORDER BY` reordenaría las tres pantallas; además el listado
/// es reactivo (`watch()` de Drift, HU-089).
///
/// Regla del PO, en este orden:
///  1. primero los pedidos SIN fecha estipulada;
///  2. después por fecha ASCENDENTE (lo más próximo a recibir, arriba);
///  3. a igual fecha, primero los normales y después los recurrentes.
///
/// ⚠ La política de nulos es la OPUESTA a la de `ordenarPorEntregaSolicitada`
/// (filtros_historial_pedidos.dart), donde los sin fecha van al FINAL. Las dos
/// son deliberadas: en el Historial un pedido sin entrega comprometida no debe
/// encabezar la lista, mientras que acá "sin fecha" significa "hay que resolverlo
/// ya" y por eso va arriba. NO unificar los dos módulos.

/// Marca de procedencia: `true` si el pedido lo generó una agenda recurrente.
///
/// Definición ÚNICA, para que `pedido.agendaId != null` no quede suelto y
/// repetido en el comparador, el filtro y la tarjeta (mismo criterio con el que
/// `EstadosPedido.etiqueta` centraliza la etiqueta del estado).
bool esDeAgenda(Pedido pedido) => pedido.agendaId != null;

/// Devuelve [pedidos] ordenados según [compararRecepciones].
///
/// Devuelve una lista NUEVA: la de entrada viene de un `watch()` de Drift y
/// mutarla en el `build` sería reordenar el cache del stream por debajo.
List<Pedido> ordenarRecepciones(List<Pedido> pedidos) {
  final copia = [...pedidos];
  copia.sort(compararRecepciones);
  return copia;
}

/// Comparador con los criterios del PO más un desempate determinista.
///
/// El desempate final no es cosmético: `List.sort` de Dart NO garantiza
/// estabilidad ("distinct objects that compare as equal may occur in any
/// order"), y la lista se reconstruye en cada emisión del stream. Sin un orden
/// TOTAL, dos filas empatadas se intercambiarían de lugar en cada refresco y el
/// listado "temblaría" solo. Como `id` es la PK, `fechaCreacion` + `id` no puede
/// empatar nunca: el resultado no depende del orden en que la base devolvió las
/// filas.
int compararRecepciones(Pedido a, Pedido b) {
  // La fecha pedida es un DÍA de calendario (HU-142), no un instante. Se
  // normaliza antes de comparar para que una hora colada por un sync viejo no
  // rompa el empate y saltee el criterio 3 (normal antes que recurrente).
  final fa = FechaRecepcion.soloDiaNullable(a.fechaRecepcionSolicitada);
  final fb = FechaRecepcion.soloDiaNullable(b.fechaRecepcionSolicitada);

  // 1) SIN fecha estipulada, PRIMERO. Sólo decide cuando UNO de los dos es nulo:
  //    si lo son los dos, se sigue de largo a los criterios 3 y 4, que también
  //    tienen que ordenar dentro del balde de "sin fecha".
  if (fa == null && fb != null) return -1;
  if (fb == null && fa != null) return 1;

  // 2) Criterio DOMINANTE: fecha ascendente.
  if (fa != null && fb != null) {
    final porFecha = fa.compareTo(fb);
    if (porFecha != 0) return porFecha;
  }

  // 3) Misma fecha ⇒ primero los NORMALES, después los recurrentes: lo que se
  //    pidió a mano para ese día es lo que alguien está esperando.
  //    Se aplica también dentro del balde "sin fecha"; ahí es defensivo, porque
  //    la agenda siempre materializa la entrega CON su fecha.
  final ra = esDeAgenda(a) ? 1 : 0;
  final rb = esDeAgenda(b) ? 1 : 0;
  if (ra != rb) return ra - rb;

  // 4) Desempate determinista: primero el pedido más viejo, y ante dos creados
  //    en el mismo instante (los genera la agenda dentro de una transacción), el
  //    id, que es único.
  final porCreacion = a.fechaCreacion.compareTo(b.fechaCreacion);
  if (porCreacion != 0) return porCreacion;
  return a.id.compareTo(b.id);
}
