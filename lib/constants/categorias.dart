class CategoriasApp {
  static const List<String> categoriasProveedor = [
    'Todos',
    'Carnes',
    'Verduras',
    'Pescados',
    'Almacén',
    'Lácteos',
    'Bebidas',
    'Limpieza',
    'Otros',
  ];

  static const List<String> categoriasReceta = [
    'Todos',
    'Entradas',
    'Principal',
    'Postres',
    'Bebidas',
    'Otros',
  ];

  /// Tipos de insumo. Vivían escritos a mano en el formulario de alta; se
  /// centralizan acá porque el filtro del catálogo (HU-006) necesita la misma
  /// lista y dos copias se desincronizan al primer tipo nuevo.
  static const List<String> tiposInsumo = [
    'ingrediente',
    'apoyo',
    'descartable',
  ];

  static const List<String> categoriasInsumo = [
    'Almacén',
    'Carnes',
    'Verdulería',
    'Pescados',
    'Bebidas',
    'Carbón y Leña',
    'Logística',
    'Otros',
  ];
}
