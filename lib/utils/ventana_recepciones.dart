/// Ventana móvil de la pantalla de Recepciones (HU-013).
///
/// El PO la pidió así: "que aparezcan los próximos 7 días de recepciones y
/// tengan la opción de mostrar más, y cargar los próximos 7 días".
///
/// Módulo PURO —sin Flutter y sin base de datos— y con el día de referencia
/// SIEMPRE inyectado: leer el reloj acá adentro haría que dos filas de la misma
/// lista se evalúen contra días distintos si el refresco cruza la medianoche.
///
/// **NO es un simple rango de fechas**, y ésa es toda la gracia. Hay dos clases
/// de entrega que se muestran pase lo que pase:
///  • las que NO tienen fecha, que el PO puso primeras en el orden justamente
///    porque son las que hay que resolver ya;
///  • las VENCIDAS, que son un compromiso con el proveedor que quedó abierto.
/// Esconder cualquiera de las dos sería una regresión: hoy se ven y no hay otro
/// lugar donde mirarlas.
///
/// ⚠ NO se reusa `filtros_historial_pedidos.dart`, y no es por descuido: aquel
/// filtro DESCARTA a propósito los pedidos sin fecha cuando hay un rango activo
/// ("no se puede afirmar que caigan dentro"), que es exactamente la regresión
/// prohibida acá. Son dos reglas distintas para dos pantallas distintas y no se
/// unifican.
library;

import '../database/database.dart';
import 'fecha_recepcion.dart';

/// Resultado de aplicar la ventana: qué se muestra y cuánto quedó afuera.
class RecepcionesEnVentana {
  /// Las entregas visibles, en el mismo orden en que entraron.
  final List<Pedido> visibles;

  /// Cuántas quedaron fuera de la ventana. Alimenta el pie de la lista, que
  /// SIEMPRE dice si hay algo más adelante: un botón que aparece y desaparece
  /// sin explicación se reporta como bug.
  final int ocultas;

  /// Último día que entra en la ventana, para poder decirlo con todas las
  /// letras ("hasta el 20/08").
  final DateTime hasta;

  const RecepcionesEnVentana({
    required this.visibles,
    required this.ocultas,
    required this.hasta,
  });

  bool get hayMasAdelante => ocultas > 0;
}

/// Días que abarca cada tramo de la ventana.
const int diasPorTramo = 7;

/// Último día incluido con [semanas] tramos abiertos. INCLUSIVO: con una
/// semana, una entrega para hoy + 7 días entra.
DateTime finDeVentana({required DateTime hoy, int semanas = 1}) {
  final dia = FechaRecepcion.soloDia(hoy);
  final tramos = semanas < 1 ? 1 : semanas;
  // Con el constructor y nunca con Duration: al cruzar un cambio de horario,
  // `Duration` deja la fecha en 23:00 o 01:00 y rompe la comparación por día.
  return DateTime(dia.year, dia.month, dia.day + diasPorTramo * tramos);
}

/// ¿Esta entrega se muestra con la ventana abierta hasta [hasta]?
///
/// Se expone aparte de [aplicarVentana] para poder testear la regla fila por
/// fila, que es donde están los casos que importan.
bool entraEnVentana(
  Pedido pedido, {
  required DateTime hoy,
  required DateTime hasta,
}) {
  final entrega = pedido.fechaRecepcionSolicitada;
  if (entrega == null) return true; // sin fecha: siempre visible
  final dia = FechaRecepcion.soloDia(entrega);
  if (dia.isBefore(FechaRecepcion.soloDia(hoy))) {
    return true; // vencida: siempre visible
  }
  return !dia.isAfter(FechaRecepcion.soloDia(hasta));
}

/// Aplica la ventana sobre [pedidos], que ya vienen ORDENADOS.
///
/// No reordena nada: el orden lo fijó el PO y vive en `orden_recepciones.dart`.
/// Acá sólo se decide qué se ve.
RecepcionesEnVentana aplicarVentana(
  List<Pedido> pedidos, {
  required DateTime hoy,
  int semanas = 1,
}) {
  final hasta = finDeVentana(hoy: hoy, semanas: semanas);
  final visibles = <Pedido>[];
  var ocultas = 0;
  for (final p in pedidos) {
    if (entraEnVentana(p, hoy: hoy, hasta: hasta)) {
      visibles.add(p);
    } else {
      ocultas++;
    }
  }
  return RecepcionesEnVentana(
    visibles: visibles,
    ocultas: ocultas,
    hasta: hasta,
  );
}

/// ¿Hay que mostrarle a esta entrega el aviso de "la serie está esperando"?
///
/// Es la mitigación del riesgo que el PO aceptó al elegir la regla dura sin
/// gracia: si nadie recepciona, la serie se congela para siempre, así que el
/// freno TIENE que verse.
///
/// ⚠ Vive acá y NO adentro de `TarjetaPedido`, que es compartida por Pedidos,
/// Recepciones e Historial. Si la tarjeta lo decidiera sola con "es de agenda y
/// la fecha ya pasó", TODA entrega recurrente ya recibida del Historial se
/// pintaría con el aviso — porque por definición tiene fecha pasada. Por eso la
/// regla mira también el ESTADO, y sólo Recepciones se la pasa.
bool serieFrenada(
  Pedido pedido, {
  required DateTime hoy,
  required String estadoPendiente,
}) {
  if (pedido.agendaId == null) return false;
  if (pedido.estado != estadoPendiente) return false;
  final entrega = pedido.fechaRecepcionSolicitada;
  if (entrega == null) return false;
  return FechaRecepcion.soloDia(entrega).isBefore(FechaRecepcion.soloDia(hoy));
}

/// Texto que resume el estado de la ventana: cuánto abarca, hasta qué día llega
/// y cuántas entregas entraron.
///
/// Vive acá, en el módulo puro, y no en la pantalla, porque se muestra en DOS
/// lugares: el encabezado de la lista y el pie, debajo del botón que estira la
/// ventana (#202). El botón está abajo y el dato que ese botón cambia estaba
/// sólo arriba, así que había que scrollear al principio para saber hasta
/// cuándo se estaba viendo. Dos copias del mismo formato se desincronizan al
/// primer retoque; una función compartida no puede.
///
/// [semanas] se recorta igual que en [finDeVentana]: si no, con un valor menor
/// a uno el texto anunciaría "Próximos 0 días" mientras la ventana real muestra
/// siete.
String resumenDeVentana(RecepcionesEnVentana v, {int semanas = 1}) {
  final dias = diasPorTramo * (semanas < 1 ? 1 : semanas);
  final n = v.visibles.length;
  return 'Próximos $dias días (hasta el ${FechaRecepcion.formatear(v.hasta)})'
      ' · $n entrega${n == 1 ? '' : 's'}';
}
