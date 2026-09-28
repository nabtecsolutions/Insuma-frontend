/// Orígenes canónicos de un registro de `historial_precios` (HU-144).
///
/// Hasta ahora el `origen` era un string libre (sólo se escribía
/// 'compra_manual'); con el OCR aparece el segundo valor real y las constantes
/// evitan typos silenciosos. Mismo patrón que [TipoAdjunto].
class OrigenPrecio {
  OrigenPrecio._();

  /// Precio confirmado a mano por la persona al recepcionar.
  static const String compraManual = 'compra_manual';

  /// Precio que llegó SUGERIDO por el reconocimiento del remito (HU-144) y la
  /// persona confirmó sin editar. Si lo edita, vuelve a ser [compraManual].
  static const String compraOcr = 'compra_ocr';

  /// Ajuste manual fuera de una compra (fallback histórico del pull).
  static const String ajusteManual = 'ajuste_manual';
}
