/// Saneamiento de TEXTO libre antes de persistir (HU-137).
///
/// Un nombre tipeado a las apuradas llega con espacios de sobra: `" Tomate  perita "`.
/// Guardado tal cual, es un registro distinto de `"Tomate perita"` para cualquier
/// indice, comparacion o busqueda. Este modulo es la unica fuente de verdad de
/// "como se normaliza un texto" en la app.
///
/// Modulo PURO (sin Flutter ni IO): se testea sin widgets y lo puede usar tanto la
/// UI como un servicio o una migracion de datos.
class SanitizadorTexto {
  const SanitizadorTexto._();

  /// Longitud maxima por defecto de un nombre/descripcion corta.
  static const int maxLongitudNombre = 120;

  /// Longitud maxima por defecto de una nota o comentario libre.
  static const int maxLongitudNota = 500;

  /// Normaliza un texto para GUARDARLO: recorta los extremos y colapsa las
  /// secuencias de espacios internos (incluidos tabs y saltos de linea) a uno solo.
  /// Opcionalmente lo trunca a [maxLongitud].
  static String limpiar(String? texto, {int? maxLongitud}) {
    if (texto == null) return '';
    final colapsado = texto.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (maxLongitud == null || colapsado.length <= maxLongitud) {
      return colapsado;
    }
    return colapsado.substring(0, maxLongitud).trim();
  }

  /// Igual que [limpiar] pero conservando los saltos de linea (para notas y
  /// comentarios multilinea): colapsa espacios y tabs, y reduce 3+ saltos a 2.
  static String limpiarMultilinea(
    String? texto, {
    int maxLongitud = maxLongitudNota,
  }) {
    if (texto == null) return '';
    final normalizado = texto
        .replaceAll('\r\n', '\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .split('\n')
        .map((linea) => linea.trim())
        .join('\n')
        .trim();
    if (normalizado.length <= maxLongitud) return normalizado;
    return normalizado.substring(0, maxLongitud).trim();
  }

  /// Clave de COMPARACION de un nombre: ademas de [limpiar], pasa a minusculas.
  /// Es la regla que decide si dos nombres son "el mismo" para el negocio.
  ///
  /// Se usa para detectar duplicados en el alta y es la MISMA regla que debe
  /// aplicar el saneo de datos de HU-138 antes de crear `UNIQUE(negocio_id,
  /// nombre)` sobre insumos: si la migracion consolida con un criterio y el alta
  /// valida con otro, el usuario vuelve a crear el duplicado recien eliminado.
  static String normalizarParaComparar(String? texto) =>
      limpiar(texto).toLowerCase();

  /// ¿Dos textos son el mismo nombre para el negocio? (`" Tomate "` == `"tomate"`)
  static bool sonEquivalentes(String? a, String? b) =>
      normalizarParaComparar(a) == normalizarParaComparar(b);

  /// ¿El texto tiene contenido real una vez saneado? (`"   "` no lo tiene).
  static bool tieneContenido(String? texto) => limpiar(texto).isNotEmpty;
}
