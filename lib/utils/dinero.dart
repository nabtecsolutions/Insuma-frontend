/// Utilidades de DINERO (HU-081 / C3).
///
/// El dinero se guarda como `numeric(14,2)` en Postgres (exacto en base-10) y como
/// `double` en Drift (local). Este helper mantiene la coherencia en el borde:
///  - [redondear] al persistir/pushear, para no arrastrar más de 2 decimales;
///  - [parsear] al bajar del backend, porque PostgREST serializa `numeric` como
///    STRING (no como número) para no perder precisión en el JSON.
class Dinero {
  const Dinero._();

  /// Redondea [valor] a 2 decimales (centavos). Usa `toStringAsFixed` para un
  /// redondeo decimal correcto (evita el sesgo binario de `valor * 100`).
  static double redondear(double valor) =>
      double.parse(valor.toStringAsFixed(2));

  /// Parsea un monto que puede venir como número (`num`) o como `String` (así lo
  /// devuelve PostgREST para las columnas `numeric`). Devuelve [orDefault] si es
  /// null o no se puede interpretar.
  static double parsear(dynamic valor, {double orDefault = 0.0}) {
    if (valor == null) return orDefault;
    if (valor is num) return valor.toDouble();
    return double.tryParse(valor.toString()) ?? orDefault;
  }

  /// Igual que [parsear] pero devuelve `null` cuando el valor es null (para columnas
  /// de dinero anulables, p. ej. `recetas.precio_venta_carta`).
  static double? parsearNullable(dynamic valor) {
    if (valor == null) return null;
    if (valor is num) return valor.toDouble();
    return double.tryParse(valor.toString());
  }
}
