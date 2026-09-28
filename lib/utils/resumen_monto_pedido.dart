/// Cómo se muestra, en la sección de Pagos, el monto del pedido que originó la
/// deuda (HU-150).
///
/// Módulo PURO, sin Flutter: la regla que importa —qué hacer cuando el pedido no
/// tiene monto cargado— es de negocio y merece test propio, no quedar enterrada
/// en un `Text`.
library;

/// Umbral por debajo del cual una diferencia es ruido de punto flotante.
///
/// Los totales salen de sumar cantidad × precio, así que restarlos deja colas de
/// centésimas. Reportarlas como discrepancia manda al usuario a buscar un
/// problema que no existe.
const double _toleranciaCentavos = 0.01;

/// Lo que la card de Pagos necesita mostrar sobre el pedido de origen.
class ResumenMontoPedido {
  /// Texto listo para pintar: el importe formateado, o "sin monto cargado".
  final String textoTotalPedido;

  /// Si hay un total real con el que comparar.
  final bool hayTotalPedido;

  /// Facturado − pedido. `null` cuando no hay total del pedido: sin él no se
  /// puede afirmar ninguna diferencia.
  final double? diferencia;

  /// Aviso de la diferencia, o `null` si no hay nada que avisar.
  final String? textoDiferencia;

  const ResumenMontoPedido({
    required this.textoTotalPedido,
    required this.hayTotalPedido,
    required this.diferencia,
    required this.textoDiferencia,
  });
}

/// Arma el resumen del monto del pedido frente a [totalFacturado].
///
/// [totalPedido] nulo O CERO se trata igual: "sin monto cargado". La columna es
/// nullable pero los pedidos viejos y los que llegan del pull quedan en 0, y para
/// el usuario es lo mismo que no tenerlo. Mostrar "$0,00" se leería como
/// "gratis" —la razón de ser de este módulo—: alguien pagaría de menos o
/// aprobaría una factura contra un total inventado.
///
/// [formatearMonto] se inyecta para que el módulo no dependa de la pantalla ni
/// de una localización concreta.
ResumenMontoPedido resumenMontoPedido({
  required double? totalPedido,
  required double totalFacturado,
  required String Function(double) formatearMonto,
}) {
  final hayTotal = totalPedido != null && totalPedido > 0;

  if (!hayTotal) {
    return const ResumenMontoPedido(
      textoTotalPedido: 'sin monto cargado',
      hayTotalPedido: false,
      diferencia: null,
      textoDiferencia: null,
    );
  }

  final diferencia = totalFacturado - totalPedido;
  final esRuido = diferencia.abs() < _toleranciaCentavos;

  return ResumenMontoPedido(
    textoTotalPedido: formatearMonto(totalPedido),
    hayTotalPedido: true,
    diferencia: diferencia,
    // El signo lo dice la palabra y no un menos delante del importe: "menos
    // -$200" se lee dos veces y confunde.
    textoDiferencia: esRuido
        ? null
        : 'Se facturó ${formatearMonto(diferencia.abs())} '
              '${diferencia > 0 ? 'más' : 'menos'} que lo pedido',
  );
}
