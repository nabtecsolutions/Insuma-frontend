/// Paginación por rango para PostgREST (HU-089 / HU-093).
///
/// PostgREST corta cada request en `max_rows` (=1000, `supabase/config.toml`). Cualquier
/// `.select()` sin `.range()` se trunca EN SILENCIO al superar ese tope. Esta utilidad
/// concentra la lógica PURA de "pedir por rangos hasta agotar" para que la compartan tanto
/// el pull por-negocio ([ServicioDescargaNegocio], HU-089) como el listado global de
/// negocios del SuperAdmin ([ServicioSuperAdmin], HU-093), sin duplicar el bucle ni exponer
/// un helper `@visibleForTesting` fuera de su clase.
abstract final class PaginacionPostgrest {
  /// Tamaño de página. Igual a `max_rows` de PostgREST: cada `.range()` pide a lo sumo
  /// esta cantidad, que es el máximo que el backend devuelve por request. (Debe ser
  /// ≤ max_rows, o una página corta cortaría la paginación antes de tiempo.)
  static const int tamPagina = 1000;

  /// Corre [traerPagina] por rangos de [tam] filas hasta que una página vuelva INCOMPLETA
  /// (menos de [tam]) y devuelve todas las filas concatenadas. Sin paginar, PostgREST corta
  /// en `max_rows` y los conjuntos grandes (ledgers append-only, lista global de negocios…)
  /// se truncarían en silencio.
  ///
  /// [traerPagina] debe LANZAR ante un fallo de fetch, para que el llamador decida
  /// (p. ej. cortar y devolver false, o tolerar devolviendo vacío). El orden ESTABLE lo
  /// garantiza la query del llamador (p. ej. `.order('id')`): sin él, el rango podría
  /// saltear o duplicar filas entre requests.
  static Future<List<Map<String, dynamic>>> paginarTodo(
    Future<List<Map<String, dynamic>>> Function(int desde, int hasta)
    traerPagina, {
    int tam = tamPagina,
  }) async {
    final acc = <Map<String, dynamic>>[];
    var desde = 0;
    while (true) {
      final pagina = await traerPagina(desde, desde + tam - 1);
      acc.addAll(pagina);
      if (pagina.length < tam) break;
      desde += tam;
    }
    return acc;
  }
}
