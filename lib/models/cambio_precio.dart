/// Un cambio de precio de un insumo listo para mostrar en el historial
/// (HU-017). Value object puro: la variación se DERIVA del encadenamiento con
/// el registro cronológicamente anterior del mismo insumo, no se persiste.
class CambioPrecio {
  final DateTime fecha;
  final double precioNuevo;

  /// Precio vigente ANTES de este cambio. Null en el precio inicial del insumo.
  final double? precioAnterior;

  /// `compra_manual`, `compra_ocr` o `ajuste_manual` (RN-005).
  final String origen;

  final String? proveedorId;

  const CambioPrecio({
    required this.fecha,
    required this.precioNuevo,
    required this.origen,
    this.precioAnterior,
    this.proveedorId,
  });

  /// Variación relativa vs. el precio anterior (0.10 = +10%). Null si es el
  /// precio inicial o el anterior era 0 (variación indefinida).
  double? get variacionPorcentaje {
    final anterior = precioAnterior;
    if (anterior == null || anterior == 0) return null;
    return (precioNuevo - anterior) / anterior;
  }

  bool get esAumento => (variacionPorcentaje ?? 0) > 0;
  bool get esBaja => (variacionPorcentaje ?? 0) < 0;

  /// Etiqueta humana del origen del cambio.
  String get origenEtiqueta => switch (origen) {
    'compra_manual' => 'Compra',
    'compra_ocr' => 'Compra (OCR)',
    'ajuste_manual' => 'Ajuste manual',
    _ => origen,
  };
}
