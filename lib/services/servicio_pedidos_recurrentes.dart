import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/repositorios/repositorio_pedidos.dart';
import '../data/repositorios/repositorio_pedidos_recurrentes.dart';
import '../database/database.dart';
import '../utils/agenda_recurrente.dart';
import '../utils/ancla_agenda.dart';
import '../utils/estados_pedido.dart';
import '../utils/fecha_recepcion.dart';
import 'servicio_pedidos.dart';

/// Estado de UNA agenda de cara a la UI (HU-013).
///
/// Lo arma [ServicioPedidosRecurrentes.estadoDe]: junta la regla con lo que
/// realmente pasó (si hay una entrega esperando, cuándo cerró la última) para
/// que la pantalla no tenga que deducir nada.
class EstadoAgenda {
  final PedidosRecurrente agenda;

  /// Próxima entrega, o `null` si la serie está esperando que se recepcione la
  /// anterior.
  final DateTime? proxima;

  /// `true` ⇒ la serie está frenada por una entrega sin recibir.
  final bool enEspera;

  /// Fecha de esa entrega pendiente, para poder decir "la del 12/08". Puede ser
  /// `null` aunque [enEspera] sea `true`: la fecha de un pedido es opcional.
  final DateTime? esperandoDesde;

  const EstadoAgenda({
    required this.agenda,
    required this.proxima,
    required this.enEspera,
    required this.esperandoDesde,
  });

  /// `true` cuando la entrega que frena la serie ya pasó de fecha. Es la señal
  /// que la UI tiene que mostrar destacada: sin gracia, una recepción que nadie
  /// carga congela la serie para siempre, así que el freno TIENE que verse.
  bool vencida({required DateTime hoy}) =>
      enEspera &&
      esperandoDesde != null &&
      esperandoDesde!.isBefore(FechaRecepcion.soloDia(hoy));
}

/// Resultado de una corrida del generador. Sirve para test y para log.
class ResultadoEvaluacion {
  /// Ids de los pedidos materializados en esta corrida.
  final List<String> materializados;

  /// Agendas que no emitieron por estar esperando una recepción.
  final int enEspera;

  /// Agendas cuya próxima entrega cae fuera de la ventana de 6 meses y por eso
  /// todavía no se materializó. Se cuentan y se loguean: no se tragan.
  final int fueraDeVentana;

  const ResultadoEvaluacion({
    this.materializados = const [],
    this.enEspera = 0,
    this.fueraDeVentana = 0,
  });
}

/// Lógica de negocio de los pedidos recurrentes (HU-013).
///
/// **El modelo, que es lo que explica todo lo demás** (decisión del PO,
/// 2026-08-10): el pedido recurrente se confirma UNA sola vez, al crearlo, y
/// ahí se le avisa al proveedor. Desde entonces cada entrega se materializa
/// como un [Pedido] real que nace directamente en `en_espera` —el estado que
/// habilita recibir— sin que nadie tenga que aprobarla.
///
/// **La app nunca le envía nada al proveedor por su cuenta.** Esta clase sólo
/// escribe filas; el WhatsApp lo dispara una persona desde el wizard, una vez.
class ServicioPedidosRecurrentes {
  final RepositorioPedidosRecurrentes _agendas;
  final RepositorioPedidos _pedidos;
  final BaseDatosApp _db;

  /// Se reusa para dos cosas:
  ///  1. resolver los ítems sugeridos al materializar (insumos activos +
  ///     precios de hoy, incluido el precio pactado del catálogo), con la misma
  ///     regla que el armado manual;
  ///  2. declarar los vínculos insumo↔proveedor del ABM de la agenda (#196),
  ///     con `asegurarVinculosDeAgenda` y NO con `asegurarVinculosDeItems`:
  ///     acá el precio no queda congelado en el pedido, así que la agenda no
  ///     puede revivir un precio pactado ni reescribir lo que ya estaba
  ///     declarado.
  ///
  /// Sigue SIN pasar por `guardarBorrador`: el generador escribe sus pedidos por
  /// `materializarOcurrencia`, que nace en `en_espera` y no en `borrador`.
  final ServicioPedidos _servicioPedidos;

  ServicioPedidosRecurrentes(
    this._agendas,
    this._pedidos,
    this._db,
    this._servicioPedidos,
  );

  /// Estados en los que un pedido de la serie YA cerró su ciclo, y por lo tanto
  /// su recepción más reciente es la que lo resolvió.
  ///
  /// Es `historial` MENOS `cancelado`: un pedido cancelado no tuvo entrega, así
  /// que no puede anclar nada (pero sí deja de bloquear, porque es historial).
  ///
  /// ⚠ `pagado` y `recepcionado` TIENEN que estar. Si alguien lo "simplifica" a
  /// {recibidoCompleto, parcialCerrado, facturado}, el ancla DESAPARECE el día
  /// que el administrativo marca la factura como pagada, y la serie vuelve en
  /// silencio a contar desde `fechaInicio`.
  static final Set<String> anclaAdmisible = EstadosPedido.historial.difference({
    EstadosPedido.cancelado,
  });

  /// Un pedido frena el ciclo de su agenda mientras no esté cerrado.
  static bool bloqueaCiclo(String estado) => !EstadosPedido.esHistorial(estado);

  /// Descarta los ítems sin cantidad. Es regla de NEGOCIO y vive acá, no en la
  /// pantalla: un ítem en cero no se pide una vez, se pide en CADA entrega de
  /// la serie, para siempre. El usuario que tilda un insumo y borra el campo de
  /// cantidad no está pidiendo cero — se olvidó de escribir.
  ///
  /// La misma regla que ya aplica el armado manual del pedido (HU-140), pero
  /// acá pesa más: allá se descubre al mirar el pedido, y acá se repetiría en
  /// silencio cada semana.
  static List<Map<String, dynamic>> conCantidad(
    List<Map<String, dynamic>> items,
  ) => items.where((it) => ((it['cantidadPedida'] as num?) ?? 0) > 0).toList();

  /// Evita que dos disparos simultáneos (el postFrame del dashboard y el final
  /// del pull) generen la misma entrega dos veces dentro del MISMO proceso.
  /// Entre dispositivos no protege nada: para eso está el índice único.
  bool _evaluando = false;

  // --- ABM de la agenda -----------------------------------------------------

  /// Da de alta un pedido recurrente. Devuelve el texto del error, o la agenda
  /// creada si salió bien.
  ///
  /// Devuelve la fila y NO la guarda en un campo del Service a propósito: esta
  /// clase vive como singleton en el árbol de providers, así que un "último
  /// creado" compartido sería una carrera en cuanto dos pantallas la usen.
  ///
  /// La validación de la regla se delega al módulo puro: acá no hay ninguna
  /// condición de calendario escrita a mano.
  Future<({String? error, PedidosRecurrente? agenda})> crear({
    required String negocioId,
    required String proveedorId,
    required ConfigRecurrencia config,
    required List<Map<String, dynamic>> items,
    bool tieneEfectivo = false,
    String? nota,
    DateTime? hoy,
  }) async {
    final error = AgendaRecurrente.validar(config);
    if (error != null) return (error: error, agenda: null);
    // Una agenda sin ítems CON CANTIDAD no puede materializar nada: el
    // validador del pedido exige al menos uno mayor a cero, así que la entrega
    // fallaría en silencio, semana tras semana.
    final conCant = conCantidad(items);
    if (conCant.isEmpty) {
      return (error: 'Elegí al menos un insumo con su cantidad.', agenda: null);
    }

    try {
      final creada = await _agendas.crear(
        id: const Uuid().v4(),
        negocioId: negocioId,
        proveedorId: proveedorId,
        config: config,
        items: conCant,
        tieneEfectivo: tieneEfectivo,
        nota: nota,
      );
      // #262: la agenda ya NO declara vínculos insumo↔proveedor (ese eje se
      // retiró; los insumos pertenecen a una categoría). Sólo guarda la agenda y
      // materializa la primera entrega.
      //
      // Materializa la primera entrega YA, sin esperar al próximo arranque.
      //
      // Antes `evaluar` se llamaba desde un solo lugar —el initState del
      // dashboard— así que crear una agenda no producía ninguna entrega hasta
      // reiniciar la app en frío. El PO creó dos recurrentes que empezaban ese
      // mismo día y Recepciones le quedó vacía: la función parecía no andar.
      //
      // Va acá y no en la pantalla para que valga para CUALQUIER entrada, hoy y
      // mañana. Es idempotente, así que llamarlo de más no cuesta nada.
      await evaluar(negocioId, hoy: hoy);
      return (error: null, agenda: creada);
    } catch (e) {
      debugPrint('[AGENDA] No se pudo crear: $e');
      return (error: 'No se pudo guardar el pedido recurrente.', agenda: null);
    }
  }

  /// Modifica una agenda existente. Mismo contrato que [crear]: texto de error
  /// o `null`.
  Future<String?> actualizar({
    required String id,
    ConfigRecurrencia? config,
    List<Map<String, dynamic>>? items,
    bool? tieneEfectivo,
    String? nota,
    DateTime? hoy,
  }) async {
    if (config != null) {
      final error = AgendaRecurrente.validar(config);
      if (error != null) return error;
    }
    final conCant = items == null ? null : conCantidad(items);
    if (conCant != null && conCant.isEmpty) {
      return 'Elegí al menos un insumo con su cantidad.';
    }
    try {
      await _agendas.actualizar(
        id: id,
        config: config,
        items: conCant,
        tieneEfectivo: tieneEfectivo,
        nota: nota,
      );
      // Igual que en el alta: cambiar la frecuencia puede adelantar la próxima
      // entrega, y el usuario tiene que verlo al instante.
      final agenda = await _agendas.porId(id);
      if (agenda != null) {
        // #262: editar la agenda ya no declara vínculos insumo↔proveedor (eje
        // retirado). Sólo se re-materializa por si cambió la frecuencia.
        await evaluar(agenda.negocioId, hoy: hoy);
      }
      return null;
    } catch (e) {
      debugPrint('[AGENDA] No se pudo actualizar $id: $e');
      return 'No se pudo guardar el cambio.';
    }
  }

  /// Baja LÓGICA. Los pedidos que ya nacieron de esta agenda NO se tocan: son
  /// compromisos reales con el proveedor.
  Future<String?> darDeBaja(String id) async {
    try {
      await _agendas.darDeBaja(id);
      return null;
    } catch (e) {
      debugPrint('[AGENDA] No se pudo dar de baja $id: $e');
      return 'No se pudo eliminar el pedido recurrente.';
    }
  }

  Future<List<PedidosRecurrente>> deProveedor(String proveedorId) =>
      _agendas.deProveedor(proveedorId);

  Stream<List<PedidosRecurrente>> observarDeProveedor(String proveedorId) =>
      _agendas.observarDeProveedor(proveedorId);

  // --- Lectura para la UI ---------------------------------------------------

  /// Estado de cada agenda del negocio: próxima entrega, o el motivo por el que
  /// no hay ninguna. Una sola pasada, sin N+1.
  Future<List<EstadoAgenda>> estadoDeAgendas(
    String negocioId, {
    DateTime? hoy,
  }) async {
    final dia = FechaRecepcion.soloDia(hoy ?? DateTime.now());
    final agendas = await _agendas.delNegocio(negocioId);
    if (agendas.isEmpty) return const [];

    final contexto = await _contextoDe(negocioId);
    return [
      for (final a in agendas) _estadoDe(a, contexto, dia),
    ].nonNulls.toList();
  }

  // --- El generador ---------------------------------------------------------

  /// Evalúa todas las agendas del negocio y materializa las entregas que
  /// correspondan. Se llama al abrir la app y al terminar la descarga.
  ///
  /// Es IDEMPOTENTE: correrlo cinco veces en el día produce lo mismo que
  /// correrlo una. Las tres barreras, de la más barata a la más cara:
  ///  1. la regla dura —si la agenda tiene una entrega abierta, no emite nada—;
  ///  2. `fechaUltimaOcurrenciaEmitida`, que impide reofrecer una fecha ya
  ///     emitida aunque la entrega se haya borrado a mano;
  ///  3. el índice único `(agenda_id, fecha)` de Postgres, como último recurso
  ///     entre dispositivos.
  Future<ResultadoEvaluacion> evaluar(String negocioId, {DateTime? hoy}) async {
    if (_evaluando) return const ResultadoEvaluacion();
    _evaluando = true;
    try {
      final dia = FechaRecepcion.soloDia(hoy ?? DateTime.now());
      final agendas = await _agendas.delNegocio(negocioId);
      if (agendas.isEmpty) return const ResultadoEvaluacion();

      final contexto = await _contextoDe(negocioId);
      final proveedores = await _proveedoresActivos(negocioId);

      final materializados = <String>[];
      var enEspera = 0;
      var fueraDeVentana = 0;

      for (final agenda in agendas) {
        // Un proveedor dado de baja no recibe pedidos. La agenda no se toca:
        // si lo reactivan, la serie sigue sola.
        if (!proveedores.containsKey(agenda.proveedorId)) continue;

        final estado = _estadoDe(agenda, contexto, dia);
        if (estado == null) continue; // regla ilegible: ya se logueó
        if (estado.enEspera) {
          enEspera++;
          continue;
        }
        final fecha = estado.proxima;
        if (fecha == null) continue;

        // Ventana de 6 meses: `FechaRecepcion` la aplica a todo pedido que se
        // persiste. Con un N grande (cada 200 días) la primera entrega ya cae
        // afuera. NO se materializa todavía —se hará cuando entre en ventana—
        // pero se LOGUEA: tragárselo sería el silencio que esta HU evita.
        if (!FechaRecepcion.esValida(fecha, hoy: dia)) {
          fueraDeVentana++;
          debugPrint(
            '[AGENDA] ${agenda.id}: la próxima entrega '
            '(${FechaRecepcion.formatear(fecha)}) cae fuera de los 6 meses; '
            'se materializará cuando entre en ventana.',
          );
          continue;
        }

        final id = await _materializar(agenda, fecha, proveedores);
        if (id != null) materializados.add(id);
      }

      return ResultadoEvaluacion(
        materializados: materializados,
        enEspera: enEspera,
        fueraDeVentana: fueraDeVentana,
      );
    } finally {
      _evaluando = false;
    }
  }

  /// Crea la entrega y avanza la memoria de la serie en UNA transacción.
  ///
  /// Que vayan juntas no es prolijidad: si el pedido se creara y la marca no,
  /// el próximo arranque volvería a ofrecer la misma fecha. Además Drift difiere
  /// las notificaciones de los `watch()` hasta el commit, así que el listado
  /// emite UNA vez por agenda y no dos.
  Future<String?> _materializar(
    PedidosRecurrente agenda,
    DateTime fecha,
    Map<String, String> proveedores,
  ) async {
    final guardados = _itemsDe(agenda);
    if (guardados.isEmpty) {
      debugPrint('[AGENDA] ${agenda.id}: sin ítems, no se materializa nada.');
      return null;
    }

    // La lista de insumos y sus cantidades son fijas —es lo que el usuario
    // eligió al crear el pedido recurrente— pero los PRECIOS no: se resuelven
    // al materializar, con la misma regla que el armado manual (incluido el
    // precio pactado del catálogo, HU-138). Y de paso se caen los insumos dados
    // de baja: sin esto, una agenda seguiría pidiendo un producto discontinuado
    // para siempre.
    final sugeridos = await _servicioPedidos.itemsSugeridosDe(
      itemsBase: guardados,
      proveedorId: agenda.proveedorId,
    );
    if (sugeridos.omitidos.isNotEmpty) {
      debugPrint(
        '[AGENDA] ${agenda.id}: se omiten insumos dados de baja: '
        '${sugeridos.omitidos.join(", ")}',
      );
    }
    final items = sugeridos.items;
    if (items.isEmpty) {
      debugPrint(
        '[AGENDA] ${agenda.id}: todos sus insumos están dados de '
        'baja; no se materializa nada.',
      );
      return null;
    }
    final total = items.fold<double>(
      0,
      (acc, it) =>
          acc +
          ((it['cantidadPedida'] as num?) ?? 0) *
              ((it['precioUnitario'] as num?) ?? 0),
    );

    try {
      return await _db.transaction(() async {
        final pedido = await _pedidos.materializarOcurrencia(
          // Id AL AZAR y no derivado de (agenda, fecha), a propósito. Con un id
          // determinista dos dispositivos convergerían a la misma fila, pero un
          // dispositivo desactualizado que materializara una entrega que el otro
          // ya recibió pisaría esa fila y la devolvería a `en_espera`: el push
          // de un INSERT es un upsert sin token de versión. Se prefiere el
          // duplicado VISIBLE —que además frena el índice único del server—
          // antes que la corrupción silenciosa de un pedido ya recibido.
          id: const Uuid().v4(),
          negocioId: agenda.negocioId,
          agendaId: agenda.id,
          proveedorNombre: proveedores[agenda.proveedorId] ?? '',
          proveedorId: agenda.proveedorId,
          // Nace CONFIRMADO: la aprobación se dio una vez, al crear la agenda.
          estado: EstadosPedido.enEspera,
          itemsJson: jsonEncode(items),
          total: total,
          tieneEfectivo: agenda.tieneEfectivo,
          nota: agenda.nota,
          fechaRecepcionSolicitada: fecha,
        );
        if (pedido == null) return null;
        await _agendas.marcarOcurrenciaEmitida(agenda.id, fecha);
        return pedido.id;
      });
    } catch (e) {
      debugPrint(
        '[AGENDA] ${agenda.id}: no se pudo materializar la entrega '
        'del ${FechaRecepcion.formatear(fecha)}: $e',
      );
      return null;
    }
  }

  // --- Interno --------------------------------------------------------------

  /// Lo que hace falta saber de TODAS las agendas, en dos consultas.
  Future<_ContextoAgendas> _contextoDe(String negocioId) async {
    final pedidos = await _pedidos.deAgendas(negocioId);
    final cierres = await _pedidos.ultimosCierresPorAgenda(
      negocioId,
      estadosCerrados: anclaAdmisible,
    );

    // La entrega abierta de cada agenda. Si hubiera más de una —no debería, la
    // regla dura lo impide, pero puede pasar entre dispositivos— gana la de
    // fecha más vieja: es la que hay que recibir primero.
    final abiertas = <String, Pedido>{};
    for (final p in pedidos) {
      final agendaId = p.agendaId;
      if (agendaId == null || !bloqueaCiclo(p.estado)) continue;
      final actual = abiertas[agendaId];
      if (actual == null || _antes(p, actual)) abiertas[agendaId] = p;
    }
    return _ContextoAgendas(abiertas: abiertas, cierres: cierres);
  }

  /// Ordena dos entregas abiertas por su fecha pedida; las que no tienen fecha
  /// van al final, con el mismo criterio que el listado de Recepciones.
  static bool _antes(Pedido a, Pedido b) {
    final fa = a.fechaRecepcionSolicitada;
    final fb = b.fechaRecepcionSolicitada;
    if (fa == null) return false;
    if (fb == null) return true;
    return fa.isBefore(fb);
  }

  EstadoAgenda? _estadoDe(
    PedidosRecurrente agenda,
    _ContextoAgendas contexto,
    DateTime hoy,
  ) {
    final config = _configDe(agenda);
    if (config == null) return null;

    final abierta = contexto.abiertas[agenda.id];
    final ancla = AnclaAgenda.resolver(
      config: config,
      // La regla dura cuelga del ESTADO, no de la fecha: la fecha de un pedido
      // es opcional y borrable, y si el bloqueo dependiera de ella vaciarla lo
      // levantaría en silencio.
      hayEntregaAbierta: abierta != null,
      hoy: hoy,
      ultimaOcurrenciaEmitida: agenda.fechaUltimaOcurrenciaEmitida,
      ultimoCierre: contexto.cierres[agenda.id],
      fechaProgramadaAbierta: abierta?.fechaRecepcionSolicitada,
    );

    if (ancla.enEspera) {
      return EstadoAgenda(
        agenda: agenda,
        proxima: null,
        enEspera: true,
        esperandoDesde: abierta?.fechaRecepcionSolicitada,
      );
    }
    return EstadoAgenda(
      agenda: agenda,
      proxima: AgendaRecurrente.proxima(
        config,
        desde: ancla.desde,
        ancla: ancla.base,
        minimoK: ancla.minimoK,
      ),
      enEspera: false,
      esperandoDesde: null,
    );
  }

  /// Reconstruye la regla desde la fila. Devuelve `null` —y lo loguea— si la
  /// fila es ilegible: puede venir del pull con un `tipo` que esta versión de la
  /// app no conoce, y saltear esa agenda es mejor que adivinar una frecuencia.
  static ConfigRecurrencia? _configDe(PedidosRecurrente a) {
    final tipo = AgendaRecurrente.tipoDesdeCodigo(a.tipo);
    if (tipo == null) {
      debugPrint('[AGENDA] ${a.id}: tipo desconocido "${a.tipo}", se saltea.');
      return null;
    }
    return ConfigRecurrencia(
      tipo: tipo,
      diasSemana: AgendaRecurrente.desdeBitmask(a.diasSemana),
      diaMes: a.diaMes,
      cadaNDias: a.cadaNDias,
      ancla: AgendaRecurrente.anclaDesdeCodigo(a.ancla),
      fechaInicio: a.fechaInicio,
    );
  }

  static List<Map<String, dynamic>> _itemsDe(PedidosRecurrente a) {
    try {
      final crudo = jsonDecode(a.items);
      if (crudo is! List) return const [];
      return crudo.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, String>> _proveedoresActivos(String negocioId) async {
    // Dos `where` en vez de uno con `&`: Drift los combina con AND, y así este
    // Service no necesita importar drift sólo por un operador.
    final filas =
        await (_db.select(_db.proveedores)
              ..where((p) => p.negocioId.equals(negocioId))
              ..where((p) => p.activo.equals(true)))
            .get();
    return {for (final p in filas) p.id: p.nombre};
  }
}

/// Los datos derivados que comparten todas las agendas de una corrida.
class _ContextoAgendas {
  final Map<String, Pedido> abiertas;
  final Map<String, DateTime> cierres;
  const _ContextoAgendas({required this.abiertas, required this.cierres});
}
