/// Arma el subtítulo de un insumo en la lista del catálogo.
///
/// Regla de visibilidad (HU-060 / HU-077): el **costo por unidad** sólo se incluye
/// para quien tiene permiso financiero. Al cocinero se le muestra la lista completa
/// de insumos (los necesita para armar pedidos), pero **nunca el precio**.
///
/// Función PURA (sin Flutter ni IO) para poder testear la regla de forma aislada.
String subtituloInsumo({
  required String categoria,
  required String unidad,
  required double costoPorUnidad,
  required bool puedeVerCostos,
}) {
  final base = '$categoria · $unidad';
  if (!puedeVerCostos) return base;
  return '$base · \$${costoPorUnidad.toStringAsFixed(2)}/$unidad';
}
