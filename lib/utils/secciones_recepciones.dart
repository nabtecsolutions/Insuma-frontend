/// Agrupamiento por urgencia de la pantalla de Recepciones (#277).
///
/// Módulo PURO —sin Flutter y sin base de datos propia— con el día de
/// referencia SIEMPRE inyectado, igual que `ventana_recepciones.dart` y
/// `semaforo_entrega.dart`.
///
/// ## Por qué aplana la lista en vez de armar los widgets
///
/// La pantalla de Recepciones tenía **cobertura cero** de tests cuando se
/// escribió esto. Si el agrupamiento viviera adentro del `ListView.builder`,
/// nacería sin red: habría que levantar Flutter, una base y un provider para
/// afirmar en qué sección cae una entrega.
///
/// Aplanando a [ItemLista] —separador, tarjeta o botón— la regla entera se
/// prueba con listas y fechas, y al builder le queda un `switch` que no decide
/// nada. Es el mismo reparto que ya usan `orden_recepciones` (decide el orden)
/// y `ventana_recepciones` (decide qué se ve).
///
/// ## Lo que este módulo NO hace
///
///  • **No ordena.** El orden lo fijó el PO y vive en `orden_recepciones.dart`.
///    Acá se recorre la lista UNA vez y cada pedido cae en su sección
///    conservando su posición relativa, así que el orden interno de cada
///    sección es exactamente el que traía.
///  • **No filtra por estado.** Eso ya lo hizo la pantalla, que lista sólo
///    pedidos confirmados. Acá se clasifica por FECHA y no se descarta ninguno:
///    un módulo que puede tragarse una entrega en silencio es peor que uno que
///    la pone en la sección equivocada, porque no hay forma de notarlo.
library;

import '../database/database.dart';
import 'fecha_recepcion.dart';
import 'semaforo_entrega.dart';

/// Una fila de la lista de Recepciones.
///
/// `sealed` a propósito: el `switch` del builder queda EXHAUSTIVO, así que el
/// día que alguien agregue una cuarta variante el código no compila hasta que
/// decida cómo se pinta. Con una jerarquía abierta, esa variante nueva caería
/// en un `default` y no se dibujaría nada.
sealed class ItemLista {
  const ItemLista();
}

/// El encabezado de una sección, con cuántas entregas trae.
class SeparadorSeccion extends ItemLista {
  final String titulo;
  final int cantidad;

  const SeparadorSeccion({required this.titulo, required this.cantidad});
}

/// Una entrega.
class TarjetaDeItem extends ItemLista {
  final Pedido pedido;

  const TarjetaDeItem(this.pedido);
}

/// El pie de "Vencidos" cuando hay más de las que entran (ver [topeVencidos]).
class BotonVerRestantes extends ItemLista {
  final int cuantos;

  const BotonVerRestantes(this.cuantos);
}

/// Cuántos vencidos se muestran antes de cortar.
///
/// El corte NO es estético. Un vencido es un compromiso abierto y no se puede
/// esconder, pero con treinta y cuatro atrasados esa sección se come la
/// pantalla y empuja "Hoy" y "Mañana" —lo único accionable en el día— varias
/// pantallas abajo. Cinco entran en un teléfono sin scrollear, y el resto queda
/// a un toque: el mismo trato que le da la ventana móvil a las entregas de más
/// adelante, que tampoco se esconden, se despliegan.
const int topeVencidos = 5;

/// Rótulo de cada sección.
///
/// ⚠ Ninguno lleva un número adentro, y no es casualidad: esta pantalla ya
/// muestra DOS conteos propios —el encabezado ("· 4 entregas") y el pie ("hay 3
/// más adelante")—. Un rótulo como "Próximos" o "Más adelante" repetiría esas
/// palabras con un número distinto al lado, y quedarían dos cifras que no
/// coinciden bajo el mismo nombre. La cantidad va aparte, en [SeparadorSeccion].
class TitulosSeccion {
  TitulosSeccion._();

  static const sinFecha = 'Sin fecha';
  static const vencidos = 'Vencidos';
  static const hoy = 'Hoy';
  static const manana = 'Mañana';

  /// La quinta sección se nombra por su borde: todo lo que cae después de
  /// mañana. Las otras cuatro son relativas ("Hoy", "Mañana"), así que sin la
  /// fecha ésta quedaría como un cajón vago de "lo demás".
  static String posteriores(DateTime hoyRef) =>
      'Posteriores al ${FechaRecepcion.formatearCorto(_manana(hoyRef))}';
}

DateTime _manana(DateTime hoy) {
  final d = FechaRecepcion.soloDia(hoy);
  // Con el constructor y nunca con `Duration`: al cruzar un cambio de horario,
  // `Duration` deja la fecha en 23:00 o 01:00. Misma razón que `finDeVentana`.
  return DateTime(d.year, d.month, d.day + 1);
}

/// A qué sección pertenece una entrega, en el orden en que salen en pantalla.
enum _Seccion { sinFecha, vencidos, hoy, manana, posteriores }

_Seccion _seccionDe(Pedido p, DateTime hoy) {
  final s = SemaforoEntrega.deFecha(p.fechaRecepcionSolicitada, hoy: hoy);
  switch (s.categoria) {
    case CategoriaEntrega.sinFecha:
      return _Seccion.sinFecha;
    case CategoriaEntrega.vencido:
      return _Seccion.vencidos;
    case CategoriaEntrega.hoy:
      return _Seccion.hoy;
    case CategoriaEntrega.proximo:
      // "Mañana" se DERIVA de los días y no es un quinto valor del enum: es el
      // contrato que declara `semaforo_entrega.dart`. Si alguien invierte el
      // signo de `dias` allá, acá empiezan a caer los vencidos de ayer.
      return s.dias == 1 ? _Seccion.manana : _Seccion.posteriores;
  }
}

String _tituloDe(_Seccion s, DateTime hoy) {
  switch (s) {
    case _Seccion.sinFecha:
      return TitulosSeccion.sinFecha;
    case _Seccion.vencidos:
      return TitulosSeccion.vencidos;
    case _Seccion.hoy:
      return TitulosSeccion.hoy;
    case _Seccion.manana:
      return TitulosSeccion.manana;
    case _Seccion.posteriores:
      return TitulosSeccion.posteriores(hoy);
  }
}

/// Aplana [pedidos] —que ya vienen ORDENADOS y filtrados por la ventana— a las
/// filas que dibuja la lista.
///
/// Las secciones VACÍAS no salen: un "Hoy (0)" en pantalla hace pensar que algo
/// no cargó.
///
/// [vencidosExpandidos] llega desde el controlador y no se guarda acá: este
/// módulo es puro y la misma lista se puede pedir dos veces con y sin expandir.
List<ItemLista> aplanarEnSecciones(
  List<Pedido> pedidos, {
  required DateTime hoy,
  bool vencidosExpandidos = false,
  int tope = topeVencidos,
}) {
  // Una sola pasada, conservando el orden de entrada dentro de cada grupo.
  final porSeccion = <_Seccion, List<Pedido>>{};
  for (final p in pedidos) {
    porSeccion.putIfAbsent(_seccionDe(p, hoy), () => <Pedido>[]).add(p);
  }

  final filas = <ItemLista>[];
  // Se recorre el enum y no las claves del mapa: el orden de las secciones lo
  // fija la declaración del enum, no el orden en que llegaron los pedidos.
  for (final seccion in _Seccion.values) {
    final delGrupo = porSeccion[seccion];
    if (delGrupo == null || delGrupo.isEmpty) continue;

    filas.add(
      SeparadorSeccion(
        titulo: _tituloDe(seccion, hoy),
        cantidad: delGrupo.length,
      ),
    );

    // El tope es SÓLO de vencidos. Las demás secciones están acotadas por la
    // ventana móvil de 7 días; ésta no, porque un vencido se muestra siempre
    // sin importar cuánto haga que venció.
    final recorta =
        seccion == _Seccion.vencidos &&
        !vencidosExpandidos &&
        tope > 0 &&
        delGrupo.length > tope;

    final visibles = recorta ? delGrupo.take(tope) : delGrupo;
    filas.addAll(visibles.map(TarjetaDeItem.new));
    if (recorta) filas.add(BotonVerRestantes(delGrupo.length - tope));
  }
  return filas;
}
