/// Validación pura de los ítems de un pedido de compra (HU-010), extraída del
/// `ControladorRecibir` para poder testearla aislada, sin construir todo el
/// ChangeNotifier (testabilidad — HU-052).
///
/// Cada ítem es un mapa con al menos las claves `cantidad` y `costoUnitario`
/// (ambas `double`), tal como las maneja el controlador.
class ValidadorPedido {
  ValidadorPedido._();

  /// Devuelve `null` si los ítems son válidos, o un mensaje claro para mostrar al
  /// usuario. Reglas (criterios de HU-010):
  /// - debe haber al menos un ítem con cantidad > 0;
  /// - el precio es estimativo y opcional (puede quedar en 0 = "a confirmar con
  ///   la factura"), pero nunca negativo.
  ///
  /// ⚠ La regla del precio negativo quedó INALCANZABLE desde la UI a partir de
  /// #213, que volvió el campo de sólo lectura. Se conserva a propósito: este
  /// validador también corre sobre ítems que llegan de un borrador guardado y de
  /// la sincronización, y ninguno de esos dos caminos pasa por el formulario.
  static String? validarItems(List<Map<String, dynamic>> items) {
    final hayCantidad = items.any((it) => (it['cantidad'] as double) > 0);
    if (!hayCantidad) {
      return 'Agregá al menos un ítem con una cantidad mayor a 0.';
    }
    if (items.any((it) => (it['costoUnitario'] as double) < 0)) {
      return 'El precio no puede ser negativo.';
    }
    return null;
  }
}
