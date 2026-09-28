/// Filtros del catálogo de Insumos (HU-006).
///
/// Módulo PURO, sin Flutter ni base de datos: trabaja sobre la lista que la
/// pantalla ya tiene en memoria. Es a propósito, igual que en el Historial de
/// pedidos (HU-151): el listado se refresca solo y meter una consulta nueva para
/// filtrar rompería esa reactividad. También hace que la búsqueda funcione
/// OFFLINE sin ningún camino especial — nunca sale de lo local.
///
/// Todos los criterios tienen un valor NEUTRO que no filtra, y se combinan entre
/// sí con Y lógico.
library;

import '../database/database.dart';

/// Qué insumos entran según su baja lógica.
enum EstadoInsumo {
  /// Los que están en uso. Es el default: los dados de baja no estorban el
  /// trabajo diario salvo que se los pida.
  activos,

  /// Sólo los dados de baja (para revisarlos o reactivarlos).
  inactivos,

  /// Activos e inactivos.
  todos,
}

/// Pasa un texto a minúsculas y sin acentos, para comparar búsquedas.
///
/// Tipear "carbon" tiene que encontrar "Carbón": en un teclado de teléfono, y
/// más con las manos ocupadas en una cocina, nadie pone las tildes. Sin esto la
/// pantalla dice "ningún insumo coincide" de algo que existe, y el usuario
/// termina dándolo de alta de nuevo — un duplicado que además no dispara la
/// advertencia, porque ésa sí compara con tilde.
String normalizarBusqueda(String texto) {
  const conAcento = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const sinAcento = 'aaaaaeeeeiiiiooooouuuunc';
  final buffer = StringBuffer();
  for (final rune in texto.trim().toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final indice = conAcento.indexOf(char);
    buffer.write(indice >= 0 ? sinAcento[indice] : char);
  }
  return buffer.toString();
}

/// Filtra [insumos] por los criterios indicados.
///
/// #262: el filtro por proveedor se retiró junto con el eje insumo↔proveedor.
/// Los insumos pertenecen a una Categoría, no a un proveedor, y la pantalla
/// busca por [categoria].
///
/// - [texto] vacío → no filtra. Busca por nombre, sin distinguir mayúsculas.
/// - [categoria] / [tipo] nulos → no filtran.
List<Insumo> filtrarInsumos(
  List<Insumo> insumos, {
  String texto = '',
  String? categoria,
  String? tipo,
  EstadoInsumo estado = EstadoInsumo.activos,
}) {
  final buscado = normalizarBusqueda(texto);

  return insumos.where((insumo) {
    switch (estado) {
      case EstadoInsumo.activos:
        if (!insumo.activo) return false;
      case EstadoInsumo.inactivos:
        if (insumo.activo) return false;
      case EstadoInsumo.todos:
        break;
    }

    if (buscado.isNotEmpty &&
        !normalizarBusqueda(insumo.nombre).contains(buscado)) {
      return false;
    }

    if (categoria != null && insumo.categoria != categoria) return false;
    if (tipo != null && insumo.tipo != tipo) return false;

    return true;
  }).toList();
}
