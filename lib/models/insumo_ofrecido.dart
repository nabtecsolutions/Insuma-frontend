import '../database/database.dart';

/// De dónde salió el precio que se le muestra a quien arma un pedido (HU-138).
///
/// Existe para que la UI no mienta: un precio heredado del historial es sólo
/// orientativo. Desde #262 el "precio de lista pactado por proveedor" se
/// abandonó (los insumos ya no cuelgan de un proveedor), así que sólo quedan
/// referencia y sin-precio.
///
/// OJO — no confundir con `utils/origen_precio.dart`, que son los valores de
/// `historial_precios.origen` (`compra_manual`, `compra_ocr`, `ajuste_manual`)
/// de HU-144: eso describe CÓMO ingresó un precio pagado; esto describe qué tan
/// confiable es un precio OFRECIDO.
enum OrigenPrecioOfrecido {
  /// Se muestra el último precio conocido del historial o el caché del insumo.
  /// Es orientativo.
  referencia,

  /// No hay ningún precio conocido: se cargará al recibir la mercadería.
  sinPrecio,
}

/// Un insumo tal como se le ofrece a quien está armando un pedido (HU-138).
///
/// Es el DTO que reemplaza al `List<Insumo>` pelado: además del insumo lleva el
/// precio de referencia y de dónde salió.
class InsumoOfrecido {
  const InsumoOfrecido({
    required this.insumo,
    required this.precio,
    required this.origen,
  });

  final Insumo insumo;

  /// Precio a precargar en el ítem del pedido. `0` cuando [origen] es
  /// [OrigenPrecioOfrecido.sinPrecio].
  final double precio;

  final OrigenPrecioOfrecido origen;

  /// Texto corto para la UI, honesto sobre la confianza del número.
  String etiquetaPrecio(String Function(double) formatearMoneda) {
    switch (origen) {
      case OrigenPrecioOfrecido.referencia:
        return 'Precio de referencia ${formatearMoneda(precio)}';
      case OrigenPrecioOfrecido.sinPrecio:
        return 'Sin precio: se carga al recibir';
    }
  }
}

/// Un grupo del selector de pedido (#262): una categoría que suministra el
/// proveedor, con los insumos que le pertenecen. El selector arma un desplegable
/// por cada uno de estos grupos.
class GrupoCategoriaOfrecida {
  const GrupoCategoriaOfrecida({
    required this.categoria,
    required this.insumos,
  });

  final Categoria categoria;
  final List<InsumoOfrecido> insumos;
}
