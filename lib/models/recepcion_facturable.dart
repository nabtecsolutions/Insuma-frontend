import '../database/database.dart';

/// Una recepción vista desde el módulo de Pagos (HU-067): el evento de recepción con
/// todo lo necesario para facturarlo "contra remito" (por lo recibido, no por el
/// pedido). Value object de sólo lectura que arma [ServicioRecepcionesAdmin]; la UI
/// no calcula nada, sólo muestra.
class RecepcionFacturable {
  final Recepcion recepcion;
  final Pedido pedido;
  final String proveedorNombre;

  /// Id del proveedor a usar al facturar (y para la cuenta corriente): el del pedido
  /// si es válido, o el resuelto por nombre cuando el pedido no lo tiene (pedidos
  /// legacy/sincronizados sin `proveedorId`). Puede ser null si no se pudo resolver.
  final String? proveedorId;

  /// Desenlace AGREGADO de la recepción: 'correcto' | 'diferencia' | 'rechazado'.
  final String desenlace;

  /// Total recibido (facturable) de esta recepción: Σ (cantidad aceptada × precio).
  final double montoRecibido;

  /// ¿Tiene al menos un remito adjunto? Habilita "Ver remito".
  final bool tieneRemito;

  /// ¿El pedido se recibió en varios eventos? Si es parcial, la UI muestra a qué
  /// pedido pertenece esta recepción (criterio HU-067).
  final bool esParcial;

  const RecepcionFacturable({
    required this.recepcion,
    required this.pedido,
    required this.proveedorNombre,
    required this.proveedorId,
    required this.desenlace,
    required this.montoRecibido,
    required this.tieneRemito,
    required this.esParcial,
  });

  String get recepcionId => recepcion.id;
  String get pedidoId => pedido.id;

  /// #229: ¿el pedido quedó marcado como pagado en efectivo al recibir? Pinta
  /// el chip de la card y precarga el switch de la pantalla de procesar.
  bool get esEfectivo => pedido.tieneEfectivo;
  int get numeroRecepcion => recepcion.numeroRecepcion;
  DateTime get fechaRecepcion => recepcion.fechaRecepcion;

  /// HU-143: ¿el monto mostrado es un total escrito a mano? (`total_recibido`
  /// presente ⇒ manda sobre el derivado de las líneas).
  bool get totalEditadoAMano => recepcion.totalRecibido != null;
  String? get totalEditadoPorNombre => recepcion.totalEditadoPorNombre;
  DateTime? get fechaTotalEditado => recepcion.fechaTotalEditado;
}
