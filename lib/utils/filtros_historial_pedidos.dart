import 'dart:convert';

import '../database/database.dart';
import 'estados_pedido.dart';

/// Filtros del Historial de pedidos (HU-151).
///
/// Módulo PURO, sin Flutter ni base de datos: trabaja sobre la lista que la
/// pantalla ya tiene en memoria. Es a propósito — el listado es reactivo
/// (`watch()` de Drift, HU-089) y meter una consulta nueva para filtrar
/// rompería esa reactividad.
///
/// Todos los criterios tienen un valor NEUTRO que no filtra, y se combinan
/// entre sí (Y lógico).

/// Filtra [pedidos] por los criterios indicados.
///
/// - [proveedor] / [articulo] vacíos → no filtran.
/// - [desde] / [hasta] nulos → sin límite. Se compara contra `fechaCreacion`,
///   que es la que la tarjeta MUESTRA; el listado se ordena por
///   `fechaActualizacion`, y filtrar por ésa haría parecer que el filtro está
///   roto.
/// - [etiquetaEstado] == [EstadosPedido.etiquetaTodos] → no filtra. Ver
///   [etiquetasDeEstado].
/// - [montoMin] / [montoMax] nulos → sin límite. Un pedido SIN total queda
///   fuera cuando hay rango activo: no se puede afirmar que caiga dentro.
/// - [entregaDesde] / [entregaHasta] (HU-142) nulos → sin límite. Se comparan
///   contra `fechaRecepcionSolicitada`. Un pedido SIN fecha pedida queda fuera
///   cuando hay rango activo, por el mismo criterio que el monto: no se puede
///   afirmar que caiga dentro.
List<Pedido> filtrarHistorialPedidos(
  List<Pedido> pedidos, {
  String proveedor = '',
  String articulo = '',
  DateTime? desde,
  DateTime? hasta,
  String etiquetaEstado = EstadosPedido.etiquetaTodos,
  double? montoMin,
  double? montoMax,
  DateTime? entregaDesde,
  DateTime? entregaHasta,
}) {
  final hayRangoEntrega = entregaDesde != null || entregaHasta != null;
  final prov = proveedor.trim().toLowerCase();
  final art = articulo.trim().toLowerCase();
  final etiqueta = etiquetaEstado.trim();
  final hayRangoMonto = montoMin != null || montoMax != null;

  return pedidos.where((p) {
    if (prov.isNotEmpty && !p.proveedorNombre.toLowerCase().contains(prov)) {
      return false;
    }

    if (art.isNotEmpty &&
        !articulosDe(p).any((n) => n.toLowerCase().contains(art))) {
      return false;
    }

    if (desde != null && p.fechaCreacion.isBefore(desde)) return false;
    if (hasta != null && p.fechaCreacion.isAfter(hasta)) return false;

    if (etiqueta.isNotEmpty &&
        etiqueta != EstadosPedido.etiquetaTodos &&
        EstadosPedido.etiqueta(p.estado) != etiqueta) {
      return false;
    }

    if (hayRangoMonto) {
      final total = p.total;
      if (total == null) return false;
      if (montoMin != null && total < montoMin) return false;
      if (montoMax != null && total > montoMax) return false;
    }

    // HU-142: rango por día pedido de entrega.
    if (hayRangoEntrega) {
      final entrega = p.fechaRecepcionSolicitada;
      if (entrega == null) return false;
      if (entregaDesde != null && entrega.isBefore(entregaDesde)) return false;
      if (entregaHasta != null && entrega.isAfter(entregaHasta)) return false;
    }

    return true;
  }).toList();
}

/// Ordena [pedidos] por la fecha de entrega solicitada (HU-142).
///
/// Los que NO tienen fecha van SIEMPRE al final, en los dos sentidos: son los
/// que no tienen entrega comprometida, así que no deberían encabezar la lista
/// ni siquiera al ordenar descendente. Entre ellos se conserva el orden de
/// entrada (la ordenación de Dart es estable).
///
/// Devuelve una lista NUEVA: la de entrada suele venir de un `watch()` de Drift
/// y no hay que mutarla.
List<Pedido> ordenarPorEntregaSolicitada(
  List<Pedido> pedidos, {
  bool ascendente = true,
}) {
  final copia = [...pedidos];
  copia.sort((a, b) {
    final fa = a.fechaRecepcionSolicitada;
    final fb = b.fechaRecepcionSolicitada;
    if (fa == null && fb == null) return 0;
    if (fa == null) return 1; // sin fecha, al fondo
    if (fb == null) return -1;
    return ascendente ? fa.compareTo(fb) : fb.compareTo(fa);
  });
  return copia;
}

/// Nombres de los artículos de un pedido.
///
/// `pedidos.items` es TEXT con JSON, así que puede venir corrupto o con otra
/// forma. Ante cualquier problema devuelve lista vacía: el pedido no coincidirá
/// con un filtro por artículo, pero TAMPOCO desaparece del listado cuando ese
/// filtro está vacío.
List<String> articulosDe(Pedido pedido) {
  try {
    final crudo = jsonDecode(pedido.items);
    if (crudo is! List) return const [];
    return crudo
        .whereType<Map<String, dynamic>>()
        .map((it) => (it['nombre'] ?? '').toString())
        .where((n) => n.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Etiquetas de estado presentes en [pedidos], sin repetir y con la opción
/// neutra ([EstadosPedido.etiquetaTodos]) al frente.
///
/// Se derivan de los propios datos y se agrupan por ETIQUETA, no por estado
/// crudo: `recibido_completo` y `recepcionado` se muestran los dos como
/// "Recibido", igual que `facturado` y `pagado` como "Facturado". Listar los
/// estados crudos mostraría opciones duplicadas y cada una filtraría la mitad
/// de las coincidencias.
List<String> etiquetasDeEstado(List<Pedido> pedidos) {
  final etiquetas =
      pedidos.map((p) => EstadosPedido.etiqueta(p.estado)).toSet().toList()
        ..sort();
  return [EstadosPedido.etiquetaTodos, ...etiquetas];
}
