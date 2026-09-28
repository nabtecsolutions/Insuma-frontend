import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../constants/mensajes_operacion.dart';
import '../database/database.dart';
import '../services/servicio_pedidos_recurrentes.dart';
import '../utils/agenda_recurrente.dart';
import '../utils/fecha_recepcion.dart';

/// Estado del wizard de alta/edición de un pedido recurrente (HU-013).
///
/// **Vive EN LA RUTA del wizard, nunca en el `MultiProvider` de `main.dart`.**
/// Es lo que hace estructuralmente imposible que el borrador del recurrente se
/// filtre al borrador de pedido que el usuario tenga a medio armar en "Nuevo
/// Pedido": al hacer pop, este objeto muere con la ruta.
///
/// Es un controlador DELGADO, en el sentido del estándar del equipo:
///  • **cero aritmética de fechas propia** — cada fecha sale de
///    `AgendaRecurrente`, que es el módulo puro y testeado;
///  • **cero validación propia** — `errorPaso1` es literalmente
///    `AgendaRecurrente.validar`, así el wizard y el Service dicen lo MISMO;
///  • **cero acceso a datos** — guardar es una llamada al Service, que devuelve
///    el texto del error o `null` (el contrato de la casa).
///
/// Lo único que agrega de suyo son los TEXTOS en criollo (la periodicidad y el
/// aviso de WhatsApp). Están acá y no en el widget para que la vista quede sin
/// una sola regla adentro y para poder testearlos sin árbol de widgets.
class ControladorPedidoRecurrente extends ChangeNotifier {
  final ServicioPedidosRecurrentes _servicio;

  /// Públicos y finales: el contrato ya los exponía con un getter, y un getter
  /// sobre un `final` inmutable es sólo ceremonia.
  final String negocioId;
  final String proveedorId;
  final String proveedorNombre;

  /// Agenda que se está editando, o `null` en un alta.
  final PedidosRecurrente? _edicion;

  /// Inyectable para test: toda la vista previa se proyecta desde acá y no desde
  /// `DateTime.now()` suelto, así el resultado no depende del día en que corra
  /// la suite.
  final DateTime _hoy;

  ControladorPedidoRecurrente({
    required ServicioPedidosRecurrentes servicio,
    required this.negocioId,
    required this.proveedorId,
    required this.proveedorNombre,
    PedidosRecurrente? edicion,
    DateTime? hoy,
    // `_servicio` es privado a propósito, y `this._servicio` obligaría a los
    // llamadores a nombrar el guion bajo.
    // ignore: prefer_initializing_formals
  }) : _servicio = servicio,
       _edicion = edicion,
       // `hoy` NO puede ser un formal inicializador: se normaliza a medianoche
       // para que toda la vista previa proyecte desde un día puro.
       // ignore: prefer_initializing_formals
       _hoy = FechaRecepcion.soloDia(hoy ?? DateTime.now()) {
    _fechaInicio = _hoy;
    if (edicion != null) _precargar(edicion);
  }

  // --- Paso 1: la regla ------------------------------------------------------

  TipoFrecuencia _tipo = TipoFrecuencia.semanal;
  Set<int> _diasSemana = <int>{};
  int? _diaMes;
  int? _cadaNDias;
  AnclaRecurrencia _ancla = AnclaRecurrencia.fija;
  late DateTime _fechaInicio;

  // --- Paso 2: los ítems -----------------------------------------------------

  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  bool _tieneEfectivo = false;
  String? _nota;

  bool _guardando = false;

  TipoFrecuencia get tipo => _tipo;

  /// Cambiar de tipo NO borra lo elegido en los otros: quien va a "mensual" para
  /// mirar y vuelve a "semanal" recupera sus días. La fila que se guarda igual
  /// queda coherente, porque el repositorio escribe en NULL las columnas que no
  /// son del tipo elegido.
  void cambiarTipo(TipoFrecuencia t) {
    if (t == _tipo) return;
    _tipo = t;
    notifyListeners();
  }

  Set<int> get diasSemana => _diasSemana;

  void cambiarDiasSemana(Set<int> d) {
    // Copia propia: el selector arma un Set nuevo en cada toque, pero guardarse
    // el que llega dejaría el estado a merced de quien lo mandó.
    _diasSemana = Set<int>.from(d);
    notifyListeners();
  }

  int? get diaMes => _diaMes;

  void cambiarDiaMes(int d) {
    if (d == _diaMes) return;
    _diaMes = d;
    notifyListeners();
  }

  int? get cadaNDias => _cadaNDias;

  /// Acepta `null` porque el campo se puede vaciar mientras se tipea, y ahí la
  /// config queda inválida a propósito: `errorPaso1` lo dice y el botón se apaga.
  void cambiarCadaNDias(int? n) {
    if (n == _cadaNDias) return;
    _cadaNDias = n;
    notifyListeners();
  }

  AnclaRecurrencia get ancla => _ancla;

  void cambiarAncla(AnclaRecurrencia a) {
    if (a == _ancla) return;
    _ancla = a;
    notifyListeners();
  }

  DateTime get fechaInicio => _fechaInicio;

  void cambiarFechaInicio(DateTime f) {
    final dia = FechaRecepcion.soloDia(f);
    if (dia == _fechaInicio) return;
    _fechaInicio = dia;
    notifyListeners();
  }

  /// Ítems en la forma canónica de `pedidos.items`:
  /// `[{insumoId, nombre, unidad, cantidadPedida, precioUnitario}]`. Es la misma
  /// forma que se copia a cada entrega materializada, así que no se traduce nada.
  List<Map<String, dynamic>> get items => _items;

  void cambiarItems(List<Map<String, dynamic>> i) {
    _items = List<Map<String, dynamic>>.from(i);
    notifyListeners();
  }

  bool get tieneEfectivo => _tieneEfectivo;

  void cambiarTieneEfectivo(bool v) {
    if (v == _tieneEfectivo) return;
    _tieneEfectivo = v;
    notifyListeners();
  }

  String? get nota => _nota;

  /// Una nota en blanco se guarda como NULL, no como `''`: son lo mismo para el
  /// usuario y dos representaciones distintas ensucian el diff del sync.
  void cambiarNota(String? n) {
    final limpia = (n ?? '').trim();
    final valor = limpia.isEmpty ? null : limpia;
    if (valor == _nota) return;
    _nota = valor;
    notifyListeners();
  }

  bool get esEdicion => _edicion != null;
  DateTime get hoy => _hoy;
  bool get guardando => _guardando;

  // --- Lo que la vista pregunta en vez de deducir ----------------------------

  /// La regla armada desde el estado. Se construye en cada lectura a propósito:
  /// es un objeto chico e inmutable, y así no hay ninguna copia desactualizada
  /// dando vueltas.
  ConfigRecurrencia get config => ConfigRecurrencia(
    tipo: _tipo,
    diasSemana: _diasSemana,
    diaMes: _diaMes,
    cadaNDias: _cadaNDias,
    ancla: _ancla,
    fechaInicio: _fechaInicio,
  );

  /// Motivo por el que el paso 1 no cierra, o `null`. El texto sale del módulo
  /// puro: si mañana cambia el mensaje, cambia en un solo lado.
  String? get errorPaso1 => AgendaRecurrente.validar(config);

  bool get puedeAvanzarPaso1 => errorPaso1 == null;

  /// No alcanza con que HAYA ítems: tienen que tener cantidad. Se pregunta con
  /// la misma función que el Service usa para filtrar al persistir, así que la
  /// pantalla no puede habilitar algo que el Service después descarta.
  ///
  /// Importa más que en un pedido suelto: un ítem en cero no se pide una vez,
  /// se pide en CADA entrega de la serie, para siempre.
  bool get puedeAvanzarPaso2 =>
      ServicioPedidosRecurrentes.conCantidad(_items).isNotEmpty;

  /// Vista previa de las próximas entregas.
  ///
  /// Se proyecta la GRILLA desde hoy, **sin pasar por `AnclaAgenda`**, y no es
  /// un olvido: acá se está editando la REGLA, no mirando el estado de la serie.
  /// Con una entrega abierta, `AnclaAgenda` devolvería "en espera" y el wizard
  /// se quedaría sin ninguna fecha que mostrar justo mientras el usuario elige
  /// el día. Mostrar el freno ("la próxima se agenda cuando recibas la del
  /// 12/08") es trabajo de la pantalla de agendas, que sí conoce las entregas.
  List<DateTime> get proximasEntregas => AgendaRecurrente.proximas(
    config,
    desde: _hoy,
    cantidad: vistaPreviaLimitada ? 1 : 3,
  );

  /// Día desde el que se proyecta la vista previa: hoy, o la fecha de inicio si
  /// la agenda arranca en el futuro.
  ///
  /// Lo expone el controlador —y no lo resuelve la pantalla— porque es el MISMO
  /// piso que aplica [proximasEntregas] por dentro (`AgendaRecurrente.proxima`
  /// nunca emite antes de `fechaInicio`). Si el selector del día del mes
  /// proyectara desde otro día, el slide 1 mostraría dos listas de fechas
  /// distintas para la misma regla.
  DateTime get desdeProyeccion =>
      _fechaInicio.isAfter(_hoy) ? _fechaInicio : _hoy;

  /// `true` cuando sólo se puede anticipar la PRIMERA entrega.
  ///
  /// Con el ancla "cuento desde que recibo", la fecha de la entrega N+1 se
  /// calcula desde el día en que se recibió la N — un dato que todavía no
  /// existe. Proyectar la grilla igual mostraría fechas que después no se van a
  /// cumplir, así que se muestra una sola y la pantalla lo explica.
  bool get vistaPreviaLimitada =>
      _tipo == TipoFrecuencia.cadaNDias && _ancla == AnclaRecurrencia.real;

  /// Total estimado de UNA entrega.
  ///
  /// Se calcula con la MISMA cuenta que usa el Service al materializar
  /// (`cantidadPedida * precioUnitario`, tolerando campos ausentes), para que el
  /// número del resumen sea el que después va a aparecer en el pedido real.
  /// Es "estimado" porque los precios se resuelven de nuevo en cada entrega.
  double get totalEstimado => _items.fold<double>(
    0,
    (acc, it) =>
        acc +
        ((it['cantidadPedida'] as num?) ?? 0) *
            ((it['precioUnitario'] as num?) ?? 0),
  );

  // --- Textos en criollo -----------------------------------------------------
  //
  // Viven en el controlador y no en el widget por el estándar del equipo: la
  // vista no decide qué dice la regla, la pide. Además así el mensaje que se le
  // manda al proveedor se puede testear sin levantar un árbol de widgets.

  /// Nombres de los días. Duplican los de `SelectorDiasSemana.describir` a
  /// propósito: importar un widget desde `controllers/` invertiría las capas (y
  /// arrastraría `material` a un objeto que no dibuja nada) para ahorrar siete
  /// strings que no van a cambiar nunca. El TEXTO sí se mantiene idéntico al del
  /// selector, para que el slide 1 y el resumen no se contradigan.
  static const List<String> _nombresDias = [
    'lunes',
    'martes',
    'miércoles',
    'jueves',
    'viernes',
    'sábado',
    'domingo',
  ];

  /// Cada cuánto se repite, redactado para encajar en "Lo necesito ___":
  /// "todos los lunes y jueves", "el día 30 de cada mes", "cada 7 días".
  String get descripcionPeriodicidad {
    switch (_tipo) {
      case TipoFrecuencia.semanal:
        return 'todos ${_diasEnCriollo(_diasSemana)}';
      case TipoFrecuencia.mensual:
        return _diaMes == null
            ? 'una vez por mes'
            : 'el día $_diaMes de cada mes';
      case TipoFrecuencia.cadaNDias:
        if (_cadaNDias == null) return 'cada cierta cantidad de días';
        return _cadaNDias == 1 ? 'todos los días' : 'cada $_cadaNDias días';
    }
  }

  /// Aclaración del anclaje, o `null` si el tipo elegido no tiene ninguno.
  /// Semanal y mensual tienen grilla propia: no dependen de ninguna recepción.
  String? get descripcionAncla {
    if (_tipo != TipoFrecuencia.cadaNDias) return null;
    return _ancla == AnclaRecurrencia.real
        ? 'Los días se cuentan desde que recibís la entrega anterior.'
        : 'Los días se cuentan siempre igual, aunque una entrega se atrase.';
  }

  /// "los martes" / "los martes y jueves" / "los lunes, miércoles y viernes".
  static String _diasEnCriollo(Set<int> dias) {
    if (dias.isEmpty) return 'los días que elijas';
    final ordenados = dias.toList()..sort();
    final nombres = [
      for (final d in ordenados)
        if (d >= DateTime.monday && d <= DateTime.sunday) _nombresDias[d - 1],
    ];
    if (nombres.isEmpty) return 'los días que elijas';
    if (nombres.length == 1) return 'los ${nombres.single}';
    final ultimo = nombres.removeLast();
    return 'los ${nombres.join(", ")} y $ultimo';
  }

  /// Cantidad legible: sin el `.0` de los enteros (`2.0` ⇒ "2").
  static String formatearCantidad(num cantidad) =>
      cantidad == cantidad.roundToDouble()
      ? cantidad.toInt().toString()
      : cantidad.toString();

  /// El aviso ÚNICO para el proveedor.
  ///
  /// Describe la PERIODICIDAD, no un pedido suelto, y ése es todo el modelo de
  /// esta HU: el recurrente se confirma UNA vez, acá, y desde entonces cada
  /// entrega aparece en Recepciones ya confirmada. Por eso el texto dice
  /// explícitamente que queda pactado de forma permanente — si el proveedor
  /// entendiera que es un pedido más, esperaría una confirmación por entrega que
  /// nadie le va a mandar.
  ///
  /// Sin precios, igual que `MensajesPedido.whatsapp` (HU-060).
  String get textoParaProveedor {
    final buffer = StringBuffer();
    buffer.writeln(
      esEdicion
          ? 'Hola $proveedorNombre, te paso actualizado el pedido fijo que tenemos:'
          : 'Hola $proveedorNombre, quiero dejar armado un pedido fijo:',
    );
    for (final it in _items) {
      final cantidad = (it['cantidadPedida'] as num?) ?? 0;
      final unidad = (it['unidad'] ?? '').toString();
      final nombre = (it['nombre'] ?? '').toString();
      buffer.writeln('- ${formatearCantidad(cantidad)} $unidad $nombre'.trim());
    }
    buffer.writeln();
    buffer.writeln(
      'Lo voy a necesitar $descripcionPeriodicidad, a partir del '
      '${FechaRecepcion.formatear(_fechaInicio)}.',
    );
    final aclaracion = descripcionAncla;
    if (aclaracion != null) buffer.writeln(aclaracion);
    buffer.writeln();
    buffer.writeln(
      'Queda confirmado de forma permanente: no hace falta que lo '
      'confirmemos cada vez. Si algo cambia, te aviso.',
    );
    buffer.write('¡Gracias!');
    return buffer.toString();
  }

  // --- Guardar ---------------------------------------------------------------

  /// Crea o actualiza según [esEdicion]. Devuelve el texto del error, o `null`
  /// si salió bien.
  ///
  /// NO valida de nuevo antes de llamar: el Service ya rechaza la config
  /// inválida y la lista vacía con los mismos mensajes, y repetir la condición
  /// acá sería dos verdades que se pueden desincronizar.
  Future<String?> confirmar() async {
    // Doble toque con el guardado en vuelo. El botón ya está deshabilitado por
    // [guardando], pero un alta duplicada no se puede deshacer —cada llamada
    // genera un uuid nuevo— así que la puerta se cierra también acá.
    if (_guardando) return MensajesOperacion.guardadoEnCurso;

    _guardando = true;
    notifyListeners();
    try {
      if (esEdicion) {
        return await _servicio.actualizar(
          id: _edicion!.id,
          config: config,
          items: _items,
          tieneEfectivo: _tieneEfectivo,
          nota: _nota,
        );
      }
      final resultado = await _servicio.crear(
        negocioId: negocioId,
        proveedorId: proveedorId,
        config: config,
        items: _items,
        tieneEfectivo: _tieneEfectivo,
        nota: _nota,
      );
      return resultado.error;
    } finally {
      _guardando = false;
      notifyListeners();
    }
  }

  // --- Precarga de la edición ------------------------------------------------

  /// Reconstruye el estado desde la fila.
  ///
  /// Tres traducciones que la fila necesita y que NO se hacen a mano: el tipo y
  /// el ancla salen de sus códigos (`'cada_n_dias'`, `'recepcion'`) y los días
  /// de la semana del BITMASK, todo con los conversores de `AgendaRecurrente`.
  void _precargar(PedidosRecurrente agenda) {
    // Un tipo desconocido puede llegar del pull (una versión más nueva de la
    // app). Se cae en el default en vez de reventar el wizard: el usuario ve
    // "semanal" y decide, que es mejor que una pantalla en blanco.
    _tipo =
        AgendaRecurrente.tipoDesdeCodigo(agenda.tipo) ?? TipoFrecuencia.semanal;
    _diasSemana = AgendaRecurrente.desdeBitmask(agenda.diasSemana);
    _diaMes = agenda.diaMes;
    _cadaNDias = agenda.cadaNDias;
    _ancla = AgendaRecurrente.anclaDesdeCodigo(agenda.ancla);
    _fechaInicio = FechaRecepcion.soloDia(agenda.fechaInicio);
    _items = _itemsDe(agenda.items);
    _tieneEfectivo = agenda.tieneEfectivo;
    _nota = agenda.nota;
  }

  /// Los ítems son un TEXT con JSON. Se parsea con la misma tolerancia que el
  /// Service: una fila ilegible abre el paso 2 VACÍO, nunca tira la pantalla
  /// abajo. `whereType` y no `cast`, porque `cast` explota recién al iterar y el
  /// stack no diría nunca que el problema era un ítem del medio.
  static List<Map<String, dynamic>> _itemsDe(String json) {
    try {
      final crudo = jsonDecode(json);
      if (crudo is! List) return <Map<String, dynamic>>[];
      return crudo.whereType<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[AGENDA] Ítems ilegibles al precargar el wizard: $e');
      return <Map<String, dynamic>>[];
    }
  }
}
