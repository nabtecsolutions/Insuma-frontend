/// Qué está vencido en la cuenta de un proveedor (HU-009).
///
/// Módulo PURO —sin Flutter y sin base de datos— y con `hoy` inyectable, para
/// que la regla se pueda testear sola y no dependa del día en que corra la
/// suite.
///
/// **Decisión del PO (2026-08-13):** alcanza con que UNA factura esté vencida
/// para destacar el saldo COMPLETO. Es más alarmista que separar "vencido" de
/// "en término", y a propósito: lo que el dueño necesita saber de un vistazo al
/// abrir la ficha es si tiene un problema con ese proveedor, no cuánto de la
/// deuda es reciente.
library;

import '../database/database.dart';
import 'fecha_recepcion.dart';

/// Estados de factura que todavía deben plata.
///
/// `pagada` ya no debe nada y `anulada` nunca debió: ninguna de las dos puede
/// vencer. Se listan los que SÍ cuentan en vez de excluir los que no, para que
/// un estado nuevo no entre por descuido a contarse como deuda.
const Set<String> estadosConDeuda = {'pendiente', 'parcial'};

/// Resumen de vencimientos de un proveedor.
class VencimientosProveedor {
  /// `true` si hay al menos una factura pasada de fecha y sin saldar.
  final bool hayVencidas;

  /// Cuántas están vencidas. Alimenta el "2 facturas" del panel.
  final int cantidadVencidas;

  /// La fecha de vencimiento más VIEJA entre las vencidas, para poder decir
  /// "la más vieja del 28/07". `null` si no hay ninguna vencida.
  final DateTime? masVieja;

  /// El próximo vencimiento que todavía NO pasó. `null` si no hay ninguno,
  /// que es el caso de un proveedor sin deuda o con todo vencido.
  final DateTime? proximo;

  const VencimientosProveedor({
    required this.hayVencidas,
    required this.cantidadVencidas,
    required this.masVieja,
    required this.proximo,
  });

  static const VencimientosProveedor vacio = VencimientosProveedor(
    hayVencidas: false,
    cantidadVencidas: 0,
    masVieja: null,
    proximo: null,
  );
}

/// ¿Esta factura está vencida al día [hoy]?
///
/// Vencida = pasó su fecha de vencimiento Y todavía debe plata. El día del
/// vencimiento NO cuenta como vencido: se vence cuando pasa, no cuando llega.
bool facturaVencida(Factura f, {required DateTime hoy}) =>
    estadosConDeuda.contains(f.estado) &&
    FechaRecepcion.soloDia(
      f.fechaVencimiento,
    ).isBefore(FechaRecepcion.soloDia(hoy));

/// Arma el resumen a partir de TODAS las facturas del proveedor.
VencimientosProveedor resumirVencimientos(
  List<Factura> facturas, {
  required DateTime hoy,
}) {
  final dia = FechaRecepcion.soloDia(hoy);
  DateTime? masVieja;
  DateTime? proximo;
  var vencidas = 0;

  for (final f in facturas) {
    if (!estadosConDeuda.contains(f.estado)) continue;
    final vence = FechaRecepcion.soloDia(f.fechaVencimiento);

    if (vence.isBefore(dia)) {
      vencidas++;
      if (masVieja == null || vence.isBefore(masVieja)) masVieja = vence;
    } else {
      // Incluye el vencimiento de HOY: todavía está en término.
      if (proximo == null || vence.isBefore(proximo)) proximo = vence;
    }
  }

  return VencimientosProveedor(
    hayVencidas: vencidas > 0,
    cantidadVencidas: vencidas,
    masVieja: masVieja,
    proximo: proximo,
  );
}
