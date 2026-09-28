// Datos de DEMOSTRACIÓN 100% SINTÉTICOS (HU-080 / M09).
//
// NO contienen datos reales de ningún negocio ni PII: se usan sólo para la
// precarga de demo / revisión de tiendas (bypass APP_STORE_REVIEW). La data real
// del negocio vive en la base de datos (Supabase), no en el binario.
//
// Antes esta lista replicaba el catálogo y los proveedores reales de un cliente
// (con teléfono/email/contacto reales), que además viajaban en el binario.

/// Insumos de demo. Claves: `nombre`, `categoria`, `unidad`, `tipo`.
final List<Map<String, String>> seedInsumos = [
  // Bebidas
  {
    'nombre': 'Vino Tinto Demo',
    'categoria': 'Bebidas',
    'unidad': 'u',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Vino Blanco Demo',
    'categoria': 'Bebidas',
    'unidad': 'u',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Agua Mineral Demo',
    'categoria': 'Bebidas',
    'unidad': 'u',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Gaseosa Demo',
    'categoria': 'Bebidas',
    'unidad': 'u',
    'tipo': 'ingrediente',
  },
  // Carnes
  {
    'nombre': 'Bife Demo',
    'categoria': 'Carnes',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Pollo Demo',
    'categoria': 'Carnes',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Cerdo Demo',
    'categoria': 'Carnes',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
  // Verduras
  {
    'nombre': 'Tomate Demo',
    'categoria': 'Verduras',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Lechuga Demo',
    'categoria': 'Verduras',
    'unidad': 'u',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Papa Demo',
    'categoria': 'Verduras',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
  // Lácteos
  {
    'nombre': 'Queso Demo',
    'categoria': 'Lácteos',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Manteca Demo',
    'categoria': 'Lácteos',
    'unidad': 'u',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Huevos Demo',
    'categoria': 'Lácteos',
    'unidad': 'u',
    'tipo': 'ingrediente',
  },
  // Almacén
  {
    'nombre': 'Harina Demo',
    'categoria': 'Almacén',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Arroz Demo',
    'categoria': 'Almacén',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Aceite Demo',
    'categoria': 'Almacén',
    'unidad': 'u',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Sal Demo',
    'categoria': 'Almacén',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
  // Pescados
  {
    'nombre': 'Merluza Demo',
    'categoria': 'Pescados',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Salmón Demo',
    'categoria': 'Pescados',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
  // Otros
  {
    'nombre': 'Servilletas Demo',
    'categoria': 'Otros',
    'unidad': 'u',
    'tipo': 'ingrediente',
  },
  {
    'nombre': 'Carbón Demo',
    'categoria': 'Otros',
    'unidad': 'kg',
    'tipo': 'ingrediente',
  },
];

/// Proveedores de demo. Claves: `id`, `nombre`, `categoria`, `telefono`,
/// `contacto`, `email` (todos sintéticos; dominio `.test`, reservado, nunca real).
/// Los ids `e8ccfe93` (Bebidas) y `prov13` (Carnes) los referencia
/// `ServicioInicializacion` para asociar insumos por rubro — se conservan.
final List<Map<String, String>> seedProveedores = [
  {
    'id': 'e8ccfe93',
    'nombre': 'Proveedor Bebidas Demo',
    'categoria': 'Bebidas',
    'telefono': '+541100000001',
    'contacto': 'Contacto Demo 01',
    'email': 'proveedor01@demo.insuma.test',
  },
  {
    'id': 'prov1',
    'nombre': 'Proveedor Carnes Demo',
    'categoria': 'Carnes',
    'telefono': '+541100000002',
    'contacto': 'Contacto Demo 02',
    'email': 'proveedor02@demo.insuma.test',
  },
  {
    'id': 'prov13',
    'nombre': 'Proveedor Carnes Demo 2',
    'categoria': 'Carnes',
    'telefono': '+541100000003',
    'contacto': 'Contacto Demo 03',
    'email': 'proveedor03@demo.insuma.test',
  },
  {
    'id': 'prov4',
    'nombre': 'Proveedor Verduras Demo',
    'categoria': 'Verduras',
    'telefono': '+541100000004',
    'contacto': 'Contacto Demo 04',
    'email': 'proveedor04@demo.insuma.test',
  },
  {
    'id': 'prov9',
    'nombre': 'Proveedor Lácteos Demo',
    'categoria': 'Lácteos',
    'telefono': '+541100000005',
    'contacto': 'Contacto Demo 05',
    'email': 'proveedor05@demo.insuma.test',
  },
  {
    'id': 'prov11',
    'nombre': 'Proveedor Almacén Demo',
    'categoria': 'Almacén',
    'telefono': '+541100000006',
    'contacto': 'Contacto Demo 06',
    'email': 'proveedor06@demo.insuma.test',
  },
  {
    'id': 'prov26',
    'nombre': 'Proveedor Pescados Demo',
    'categoria': 'Pescados',
    'telefono': '+541100000007',
    'contacto': 'Contacto Demo 07',
    'email': 'proveedor07@demo.insuma.test',
  },
  {
    'id': 'prov14',
    'nombre': 'Proveedor Otros Demo',
    'categoria': 'Otros',
    'telefono': '+541100000008',
    'contacto': 'Contacto Demo 08',
    'email': 'proveedor08@demo.insuma.test',
  },
];
