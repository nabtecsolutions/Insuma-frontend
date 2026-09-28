import 'package:collection/collection.dart' show mergeSort;

import '../database/database.dart';
import '../models/recepcion_facturable.dart';
import 'filtros_insumos.dart' show normalizarBusqueda;

/// Filtros de la pantalla de Pagos (#237).
///
/// Módulo PURO, sin Flutter ni base de datos: trabaja sobre las listas que
/// `ControladorPagos` ya tiene en memoria (patrón de `filtros_historial_pedidos`
/// e `filtros_insumos`). Es a propósito — ese controlador es reactivo
/// (`watch()` de Drift, HU-128, con guarda anti-ráfagas HU-136) y meter una
/// consulta nueva para filtrar rompería esa reactividad. Por lo mismo, acá no
/// se toca el controlador: los datos llegan como tear-offs (`saldoDe`,
/// `proveedorDe`).
///
/// Todos los criterios tienen un valor NEUTRO que no filtra y se combinan
/// entre sí (Y lógico). La "deuda" del orden es el SALDO DE CUENTA CORRIENTE
/// (`ControladorPagos.saldo`, el "Debe $X" de las cards): facturas menos TODOS
/// los pagos, imputados o no — decisión del PO (2026-08-30) frente a la
/// alternativa de sumar solo facturas abiertas (el criterio de la card #228).

/// Se queda con los dígitos: la búsqueda por CUIT es insensible a
/// guiones/espacios en los DOS lados (tipear "30712345678" encuentra el
/// "30-71234567-8" guardado, y al revés).
String soloDigitos(String texto) => texto.replaceAll(RegExp(r'\D'), '');

/// Lo elegido en el panel de filtros. Inmutable; la pantalla guarda la foto y
/// el panel emite copias.
class CriteriosFiltroPagos {
  const CriteriosFiltroPagos({
    this.texto = '',
    this.categoria,
    this.proveedorIds = const {},
    this.deudaMayorPrimero,
  });

  /// Búsqueda por nombre (sin tildes) o CUIT (solo dígitos). CRUDO, sin trim:
  /// [hayAlguno] tiene que mirar el TEXTO VISIBLE — un espacio suelto con el
  /// botón Limpiar escondido es el callejón sin salida de #170.
  final String texto;

  /// Categoría del proveedor; null = no filtra (la opción 'Todos').
  final String? categoria;

  /// Multi-selección de proveedores; vacío = no filtra.
  final Set<String> proveedorIds;

  /// Orden por deuda, tri-estado: null = orden natural (el de carga);
  /// true = mayor saldo primero; false = menor primero.
  final bool? deudaMayorPrimero;

  static const vacio = CriteriosFiltroPagos();

  bool get hayAlguno =>
      texto.isNotEmpty ||
      categoria != null ||
      proveedorIds.isNotEmpty ||
      deudaMayorPrimero != null;

  static const _sinCambio = Object();

  CriteriosFiltroPagos copyWith({
    String? texto,
    Object? categoria = _sinCambio,
    Set<String>? proveedorIds,
    Object? deudaMayorPrimero = _sinCambio,
  }) => CriteriosFiltroPagos(
    texto: texto ?? this.texto,
    categoria: identical(categoria, _sinCambio)
        ? this.categoria
        : categoria as String?,
    proveedorIds: proveedorIds ?? this.proveedorIds,
    deudaMayorPrimero: identical(deudaMayorPrimero, _sinCambio)
        ? this.deudaMayorPrimero
        : deudaMayorPrimero as bool?,
  );
}

/// La sección "Proveedores y saldos", filtrada y ordenada.
///
/// [saldoDe] llega como tear-off de `ControladorPagos.saldo`: la deuda que
/// ordena es la de cuenta corriente, ya calculada en memoria.
List<Proveedore> filtrarProveedoresPagos(
  List<Proveedore> proveedores, {
  required CriteriosFiltroPagos criterios,
  required double Function(String proveedorId) saldoDe,
}) {
  final buscado = normalizarBusqueda(criterios.texto);
  final digitosBuscados = soloDigitos(criterios.texto);

  final visibles = proveedores.where((p) {
    if (buscado.isNotEmpty &&
        !_matcheaTexto(p.nombre, p.cuit, buscado, digitosBuscados)) {
      return false;
    }
    // Igualdad exacta, como la pestaña Proveedores: un proveedor sin categoría
    // queda fuera al filtrar una específica.
    if (criterios.categoria != null && p.categoria != criterios.categoria) {
      return false;
    }
    if (criterios.proveedorIds.isNotEmpty &&
        !criterios.proveedorIds.contains(p.id)) {
      return false;
    }
    return true;
  }).toList();

  return _ordenarPorSaldo(
    visibles,
    criterios.deudaMayorPrimero,
    (p) => saldoDe(p.id),
  );
}

/// La sección "Recepciones por procesar", filtrada, más la cuenta de lo que
/// quedó AFUERA por no tener proveedor identificado.
class ResultadoFiltroRecepciones {
  const ResultadoFiltroRecepciones({
    required this.visibles,
    required this.ocultasSinProveedor,
  });

  final List<RecepcionFacturable> visibles;

  /// Recepciones ocultadas por un filtro de categoría/multi-selección cuyo
  /// proveedor no se pudo resolver (pedidos legacy con `proveedorId` null, o
  /// proveedor inactivo). La pantalla lo AVISA: es plata pendiente de
  /// procesar, y desaparecer en silencio es peor que una fila de más.
  final int ocultasSinProveedor;
}

ResultadoFiltroRecepciones filtrarRecepcionesPagos(
  List<RecepcionFacturable> recepciones, {
  required CriteriosFiltroPagos criterios,
  required Proveedore? Function(String? proveedorId) proveedorDe,
  required double Function(String proveedorId) saldoDe,
}) {
  final buscado = normalizarBusqueda(criterios.texto);
  final digitosBuscados = soloDigitos(criterios.texto);
  // Categoría y multi-selección hablan del PROVEEDOR: sin proveedor resuelto
  // no se puede afirmar ni negar la coincidencia. La búsqueda por texto NO
  // exige resolverlo: el nombre viaja en la propia recepción, legacy incluido.
  final exigeProveedorResuelto =
      criterios.categoria != null || criterios.proveedorIds.isNotEmpty;

  var ocultas = 0;
  final visibles = <RecepcionFacturable>[];
  for (final r in recepciones) {
    final proveedor = proveedorDe(r.proveedorId);

    if (buscado.isNotEmpty &&
        !_matcheaTexto(
          r.proveedorNombre,
          proveedor?.cuit,
          buscado,
          digitosBuscados,
        )) {
      continue;
    }
    if (exigeProveedorResuelto && proveedor == null) {
      ocultas++;
      continue;
    }
    if (criterios.categoria != null &&
        proveedor!.categoria != criterios.categoria) {
      continue;
    }
    if (criterios.proveedorIds.isNotEmpty &&
        !criterios.proveedorIds.contains(proveedor!.id)) {
      continue;
    }
    visibles.add(r);
  }

  return ResultadoFiltroRecepciones(
    visibles: _ordenarPorSaldo(
      visibles,
      criterios.deudaMayorPrimero,
      (r) => r.proveedorId == null ? 0.0 : saldoDe(r.proveedorId!),
    ),
    ocultasSinProveedor: ocultas,
  );
}

/// ¿[nombre] o [cuit] coinciden con lo tipeado? El nombre compara sin tildes;
/// el CUIT, solo si la búsqueda trae dígitos, comparando dígitos contra
/// dígitos.
bool _matcheaTexto(
  String nombre,
  String? cuit,
  String buscado,
  String digitosBuscados,
) {
  if (normalizarBusqueda(nombre).contains(buscado)) return true;
  if (digitosBuscados.isEmpty) return false;
  return soloDigitos(cuit ?? '').contains(digitosBuscados);
}

/// Orden tri-estado por saldo. `mergeSort` y no `List.sort`: sort() NO es
/// estable, y los proveedores con el mismo saldo (típicamente $0) bailarían
/// de lugar entre rebuilds.
List<T> _ordenarPorSaldo<T>(
  List<T> lista,
  bool? mayorPrimero,
  double Function(T) saldoDe,
) {
  if (mayorPrimero == null) return lista;
  final copia = [...lista];
  mergeSort<T>(
    copia,
    compare: (a, b) => mayorPrimero
        ? saldoDe(b).compareTo(saldoDe(a))
        : saldoDe(a).compareTo(saldoDe(b)),
  );
  return copia;
}
