// Lógica pura para repetir un pedido (HU-012), separada del controlador para
// poder testearla sin tocar la BBDD.

/// Cambio de precio de un ítem respecto al pedido anterior.
class CambioPrecio {
  final String nombre;
  final double anterior;
  final double actual;
  const CambioPrecio(this.nombre, this.anterior, this.actual);
}

/// Resultado de construir un pedido repetido.
class RepetirResultado {
  /// Ítems del nuevo borrador (con precio actual).
  final List<Map<String, dynamic>> items;

  /// Nombres de insumos NO copiados por estar desactivados/inexistentes.
  final List<String> omitidos;

  /// Ítems cuyo precio cambió respecto al pedido original.
  final List<CambioPrecio> cambios;

  const RepetirResultado(this.items, this.omitidos, this.cambios);
}

class RepetirPedido {
  RepetirPedido._();

  /// Construye los ítems del pedido repetido a partir de [itemsOriginales] y el
  /// catálogo actual. Para cada ítem: si el insumo sigue activo ([insumosActivos]),
  /// lo copia con la misma cantidad y el **precio vigente** ([preciosActuales]); si
  /// no, lo omite. Registra los cambios de precio vs el pedido anterior.
  static RepetirResultado construir({
    required List<Map<String, dynamic>> itemsOriginales,
    required Set<String> insumosActivos,
    required Map<String, double> preciosActuales,
  }) {
    final items = <Map<String, dynamic>>[];
    final omitidos = <String>[];
    final cambios = <CambioPrecio>[];

    for (final it in itemsOriginales) {
      final id = it['insumoId'] as String;
      final nombre = (it['nombre'] ?? id).toString();

      if (!insumosActivos.contains(id)) {
        omitidos.add(nombre);
        continue;
      }

      final precioActual = preciosActuales[id] ?? 0.0;
      final precioAnterior =
          ((it['precioUnitario'] ?? it['costoUnitario'] ?? 0) as num)
              .toDouble();

      items.add({
        'insumoId': id,
        'nombre': nombre,
        'unidad': (it['unidad'] ?? '').toString(),
        'cantidadPedida': it['cantidadPedida'] ?? it['cantidad'] ?? 0,
        'precioUnitario': precioActual,
      });

      if (precioActual != precioAnterior) {
        cambios.add(CambioPrecio(nombre, precioAnterior, precioActual));
      }
    }

    return RepetirResultado(items, omitidos, cambios);
  }
}
