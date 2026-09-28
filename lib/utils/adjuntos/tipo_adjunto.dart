/// Tipo de un archivo adjunto (HU-069). Un adjunto cuelga de una recepción y puede
/// ser el REMITO de la mercadería (HU-066) o el COMPROBANTE de pago de su factura
/// (HU-069). Como en el flujo de facturación la recepción y su factura son 1:1
/// (HU-067, sin doble factura), el comprobante se guarda contra la misma recepción,
/// discriminado por este tipo — reutilizando toda la infraestructura de adjuntos.
class TipoAdjunto {
  TipoAdjunto._();

  static const String remito = 'remito';
  static const String comprobante = 'comprobante';

  /// FACTURA del proveedor (HU-147). Es un tipo propio y no un `comprobante`:
  /// el comprobante prueba que YO pagué, la factura es el documento de la
  /// COMPRA. Sirve para el caso corriente de que el proveedor entregue la
  /// mercadería y mande la factura días después.
  static const String factura = 'factura';

  /// Tipos que son información FINANCIERA: sólo admin, para leerlos y para
  /// cargarlos (HU-110 / HU-114, extendido en HU-147).
  ///
  /// Existe como conjunto y no como comparaciones sueltas contra literales
  /// porque las policies del backend hacen exactamente lo mismo: sumar un tipo
  /// financiero nuevo tiene que ser tocar UN lugar de cada lado, no cazar
  /// `!= 'comprobante'` repartidos por el código.
  static const Set<String> financieros = {comprobante, factura};

  /// ¿[tipo] exige rol admin para verlo o cargarlo?
  static bool esFinanciero(String tipo) => financieros.contains(tipo);
}
