// Lógica pura de los desenlaces de recepción (HU-064), separada del Service y el
// controlador para poder testearla sin tocar la BBDD ni la UI.
//
// Cada ítem de una recepción lleva, en su JSON, un `estado` (desenlace):
//   • 'correcto'   → llegó lo pedido (Recibido).
//   • 'diferencia' → llegó con diferencias (Recibido). El comentario es opcional.
//   • 'rechazado'  → no se acepta; es TERMINAL. El motivo es opcional (#265). No suma cantidad
//                    aceptada ni genera precio/deuda.
// El estado del pedido se DERIVA de los ítems de todas sus recepciones.

/// Desenlaces posibles de un ítem al recepcionar.
class DesenlaceRecepcion {
  DesenlaceRecepcion._();

  static const String correcto = 'correcto';
  static const String diferencia = 'diferencia';
  static const String rechazado = 'rechazado';

  /// #263: estado NEUTRO inicial de un ítem en la verificación, ANTES de que el
  /// usuario lo resuelva (arranca sin marca y con el campo vacío). Queda
  /// DELIBERADAMENTE fuera de [todos]: no es un desenlace persistible, y
  /// [validarItemsRecepcion] bloquea la confirmación mientras algún ítem siga
  /// así. `derivarEstadoItem` nunca lo devuelve: sólo lo fija la inicialización.
  static const String pendiente = 'pendiente';

  static const List<String> todos = [correcto, diferencia, rechazado];

  /// Cantidad efectivamente ACEPTADA de una línea de recepción: 0 si fue rechazada,
  /// la cantidad recibida en cualquier otro caso.
  static double aceptadaDeLinea(Map<String, dynamic> linea) {
    final estado = (linea['estado'] ?? correcto).toString();
    if (estado == rechazado) return 0.0;
    return (linea['cantidadRecibida'] as num?)?.toDouble() ?? 0.0;
  }

  /// Deriva AUTOMÁTICAMENTE el desenlace de un ítem a partir de la cantidad
  /// ingresada vs. la pedida (HU-125):
  ///   • recibida <= 0        → 'rechazado'  ("no recibido" reutiliza el estado
  ///                            terminal existente; cuenta faltante)
  ///   • recibida != pedida   → 'diferencia' (faltó o sobró; comentario opcional)
  ///   • recibida == pedida   → 'correcto'
  /// Es una SUGERENCIA reactiva: se recalcula en cada cambio de cantidad y el
  /// usuario puede sobreescribirla con el selector manual de HU-064 (el override
  /// dura hasta el próximo cambio de cantidad).
  static String derivarEstadoItem(double pedida, double recibida) {
    if (recibida <= 0) return rechazado;
    if (recibida != pedida) return diferencia;
    return correcto;
  }
}

/// Desenlace AGREGADO de una recepción a partir de sus líneas (HU-067): resume el
/// estado de todos sus ítems en UNO solo para mostrarlo a nivel recepción.
///   • si alguna línea fue 'rechazado'   → 'rechazado'  (hubo rechazos)
///   • si no, si alguna fue 'diferencia'  → 'diferencia' (llegó con diferencias)
///   • si no                              → 'correcto'
/// Una recepción sin líneas se considera 'correcto' (caso degenerado).
String desenlaceAgregado(List<Map<String, dynamic>> lineas) {
  var hayDiferencia = false;
  for (final l in lineas) {
    final estado = (l['estado'] ?? DesenlaceRecepcion.correcto).toString();
    if (estado == DesenlaceRecepcion.rechazado) {
      return DesenlaceRecepcion.rechazado;
    }
    if (estado == DesenlaceRecepcion.diferencia) hayDiferencia = true;
  }
  return hayDiferencia
      ? DesenlaceRecepcion.diferencia
      : DesenlaceRecepcion.correcto;
}

/// Total RECIBIDO (facturable) de una recepción: Σ (cantidad aceptada × precio
/// unitario) de sus líneas. Lo rechazado vale 0 (no se recibió → no se factura).
/// Es el monto que se factura "contra remito": lo que entró en ESE evento, no lo
/// que se había pedido (HU-067). El precio puede venir como `precioUnitario` o
/// `costoUnitario` según el origen de la línea (mismo fallback que
/// [calcularFaltantes]) — sin él, la línea valía 0 y la recepción "desaparecía"
/// de facturables (HU-128).
double totalRecibidoDeLineas(List<Map<String, dynamic>> lineas) {
  var total = 0.0;
  for (final l in lineas) {
    total +=
        DesenlaceRecepcion.aceptadaDeLinea(l) *
        (((l['precioUnitario'] ?? l['costoUnitario']) as num?)?.toDouble() ??
            0.0);
  }
  return total;
}

/// Total FACTURABLE de una recepción (HU-143): el ÚNICO punto que decide entre
/// el total escrito a mano y el derivado de las líneas. Si [totalManual] no es
/// null, MANDA (es lo que dice la factura/remito del proveedor aunque los
/// precios unitarios difieran o falten); si es null, vale
/// [totalRecibidoDeLineas]. Lo consumen el registro de la recepción
/// (pedidos.total) y la vista admin de facturación (montoRecibido), así el
/// criterio no puede divergir entre pantallas.
double totalFacturable({
  double? totalManual,
  required List<Map<String, dynamic>> lineas,
}) => totalManual ?? totalRecibidoDeLineas(lineas);

/// Valida los ítems verificados de una recepción (HU-064). Devuelve un mensaje de
/// error listo para mostrar en la UI, o `null` si son válidos. Reglas:
///  • `estado` debe ser uno de los tres desenlaces.
///  • la cantidad recibida no puede ser negativa.
/// #265: ni el motivo del rechazo ni el comentario de la diferencia son
/// obligatorios (el motivo lo fue hasta #265; el comentario, hasta #251). Así,
/// un negocio sin "Motivos de recepción" cargados igual puede confirmar.
/// #263: un ítem en 'pendiente' (todavía sin resolver) BLOQUEA: la recepción no
/// se puede confirmar hasta que cada ítem tenga un desenlace elegido.
String? validarItemsRecepcion(List<Map<String, dynamic>> items) {
  for (final it in items) {
    final nombre = (it['nombre'] ?? it['insumoId'] ?? '').toString();
    final estado = (it['estado'] ?? DesenlaceRecepcion.correcto).toString();

    if (estado == DesenlaceRecepcion.pendiente) {
      return 'Marcá el desenlace de "$nombre" (Correcto, Diferencias o Rechazado).';
    }
    if (!DesenlaceRecepcion.todos.contains(estado)) {
      return 'Desenlace inválido en "$nombre".';
    }
    final recibida = (it['cantidadRecibida'] as num?)?.toDouble() ?? 0.0;
    if (recibida < 0) {
      return 'La cantidad recibida no puede ser negativa ("$nombre").';
    }
  }
  return null;
}

/// ¿Se aceptó mercadería en esta recepción? (al menos un ítem no rechazado con
/// cantidad > 0). Es la condición para exigir remito (HU-066): si todo se rechazó
/// o no entró nada, el remito es opcional.
bool hayItemRecibido(List<Map<String, dynamic>> items) =>
    items.any((it) => DesenlaceRecepcion.aceptadaDeLinea(it) > 0);

/// Suma la cantidad ACEPTADA por insumo a lo largo de todas las recepciones.
Map<String, double> _aceptadaPorInsumo(
  List<List<Map<String, dynamic>>> lineasPorRecepcion,
) {
  final aceptada = <String, double>{};
  for (final lineas in lineasPorRecepcion) {
    for (final l in lineas) {
      final id = l['insumoId'] as String?;
      if (id == null) continue;
      aceptada[id] =
          (aceptada[id] ?? 0.0) + DesenlaceRecepcion.aceptadaDeLinea(l);
    }
  }
  return aceptada;
}

/// Calcula los faltantes de un pedido (HU-064): por cada ítem pedido, lo que NO
/// entró (`cantidadPedida` − aceptada acumulada). Devuelve solo los ítems con
/// faltante > 0, en el formato de ítems de pedido (listos para un nuevo borrador).
/// Lo rechazado cuenta como faltante (no se aceptó esa mercadería).
List<Map<String, dynamic>> calcularFaltantes({
  required List<Map<String, dynamic>> itemsPedido,
  required List<List<Map<String, dynamic>>> lineasPorRecepcion,
}) {
  final aceptada = _aceptadaPorInsumo(lineasPorRecepcion);
  final faltantes = <Map<String, dynamic>>[];
  for (final it in itemsPedido) {
    final id = it['insumoId'] as String;
    final pedida = (it['cantidadPedida'] as num?)?.toDouble() ?? 0.0;
    final falta = pedida - (aceptada[id] ?? 0.0);
    if (falta > 0) {
      faltantes.add({
        'insumoId': id,
        'nombre': it['nombre'],
        'unidad': it['unidad'],
        'cantidadPedida': falta,
        'precioUnitario': it['precioUnitario'] ?? it['costoUnitario'] ?? 0,
      });
    }
  }
  return faltantes;
}

/// Anota los faltantes como OBSERVACIÓN del ítem (HU-145, "cerrar sin parcial"):
/// para cada línea de [items] cuyo insumo figura en [faltantes], concatena al
/// `comentario` la leyenda del faltante aceptado. La diferencia queda registrada
/// como evidencia INMUTABLE dentro del JSON del evento de recepción, aunque el
/// pedido se cierre sin generar parcial. Devuelve una lista NUEVA (no muta la
/// original); sin faltantes es un no-op.
List<Map<String, dynamic>> anotarFaltantesEnItems(
  List<Map<String, dynamic>> items,
  List<Map<String, dynamic>> faltantes,
) {
  if (faltantes.isEmpty) return items;
  final faltantePorInsumo = {
    for (final f in faltantes)
      f['insumoId'] as String: (f['cantidadPedida'] as num?)?.toDouble() ?? 0.0,
  };
  return items.map((it) {
    final falta = faltantePorInsumo[it['insumoId']];
    if (falta == null || falta <= 0) return Map<String, dynamic>.of(it);
    final unidad = (it['unidad'] ?? '').toString();
    final leyenda =
        'Faltante aceptado sin parcial: ${_cantidadLegible(falta)}${unidad.isEmpty ? '' : ' $unidad'}';
    final previo = (it['comentario'] ?? '').toString().trim();
    return {
      ...it,
      'comentario': previo.isEmpty ? leyenda : '$previo · $leyenda',
    };
  }).toList();
}

/// Cantidad legible para evidencia: hasta 3 decimales (los que admite la app)
/// sin residuo de punto flotante ("0.30000000000000004" → "0.3", "4.0" → "4").
String _cantidadLegible(double valor) {
  var texto = valor.toStringAsFixed(3);
  texto = texto
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  return texto;
}

/// Deriva el estado del pedido tras una recepción. Un ítem está RESUELTO si se
/// aceptó lo pedido o si fue rechazado (terminal). Si todos resueltos → completo;
/// si alguno queda pendiente → parcial; si no entró nada y nada se rechazó →
/// [estadoBase] (el pedido sigue esperando).
String estadoPedidoTrasRecepcion({
  required List<Map<String, dynamic>> itemsPedido,
  required List<List<Map<String, dynamic>>> lineasPorRecepcion,
  String estadoBase = 'en_espera',
}) {
  final aceptada = _aceptadaPorInsumo(lineasPorRecepcion);

  final rechazados = <String>{};
  for (final lineas in lineasPorRecepcion) {
    for (final l in lineas) {
      if ((l['estado'] ?? '').toString() == DesenlaceRecepcion.rechazado) {
        final id = l['insumoId'] as String?;
        if (id != null) rechazados.add(id);
      }
    }
  }

  double totalAceptada = 0.0;
  bool todosResueltos = true;
  for (final it in itemsPedido) {
    final id = it['insumoId'] as String;
    final pedida = (it['cantidadPedida'] as num?)?.toDouble() ?? 0.0;
    final ya = aceptada[id] ?? 0.0;
    totalAceptada += ya;
    final resuelto = ya >= pedida || rechazados.contains(id);
    if (!resuelto) todosResueltos = false;
  }

  if (totalAceptada <= 0 && rechazados.isEmpty) return estadoBase;
  return todosResueltos ? 'recibido_completo' : 'recibido_parcial';
}

/// Cuántas líneas de la recepción tienen una observación escrita (#212).
///
/// El comentario por ítem es OPCIONAL cuando la línea cierra en Diferencias
/// (#251), así que esto cuenta los renglones que alguien decidió explicar. Es un
/// dato que ayuda a administración a decidir el monto: la tarjeta de Pagos sólo
/// mostraba el desenlace agregado —"Diferencias"— sin decir cuántos renglones lo
/// provocaron. Como el comentario ya no es obligatorio, una recepción con
/// diferencias puede tener 0 observaciones (la tarjeta lo tolera).
///
/// Cuenta líneas, NO comentarios distintos: dos renglones con el mismo texto son
/// dos problemas, no uno.
///
/// Vive acá y no en la pantalla por la misma razón que [desenlaceAgregado]: es
/// una agregación sobre las líneas de una recepción, y la usan dos vistas.
int itemsConObservaciones(List<Map<String, dynamic>> lineas) {
  var n = 0;
  for (final l in lineas) {
    final c = (l['comentario'] as String?)?.trim() ?? '';
    if (c.isNotEmpty) n++;
  }
  return n;
}
