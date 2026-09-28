import '../database/database.dart';

/// Filtro puro para el buscador de proveedores al armar un pedido (HU-058).
///
/// Trabaja sobre la lista ya cargada en memoria (sin round-trips a la BBDD): filtra
/// por texto en el NOMBRE y por CATEGORÍA, mostrando ÚNICAMENTE proveedores activos.
/// Lógica de negocio liviana y sin dependencias de UI/BBDD → fácil de testear.
///
/// - [query] vacío → no filtra por nombre.
/// - [categoria] == 'Todos' (o vacío) → no filtra por categoría.
List<Proveedore> buscarProveedoresActivos(
  List<Proveedore> proveedores, {
  String query = '',
  String categoria = 'Todos',
}) {
  final q = query.trim().toLowerCase();
  final cat = categoria.trim();
  return proveedores.where((p) {
    if (!p.activo) return false;
    final coincideNombre = q.isEmpty || p.nombre.toLowerCase().contains(q);
    final coincideCategoria =
        cat.isEmpty || cat == 'Todos' || p.categoria == cat;
    return coincideNombre && coincideCategoria;
  }).toList();
}

/// Categorías disponibles para el filtro, derivadas de los proveedores activos
/// (más 'Todos' al frente). Evita depender de un catálogo aparte.
List<String> categoriasDeProveedores(List<Proveedore> proveedores) {
  final cats =
      proveedores
          .where((p) => p.activo && (p.categoria ?? '').trim().isNotEmpty)
          .map((p) => p.categoria!.trim())
          .toSet()
          .toList()
        ..sort();
  return ['Todos', ...cats];
}
