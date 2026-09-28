/// Desde dónde cuenta una agenda recurrente para su próxima entrega (HU-013).
///
/// Módulo PURO, igual que `agenda_recurrente.dart`: **no recibe un `Pedido` de
/// drift**. Recibe la fecha programada de la entrega abierta (si la hay) y la
/// fecha del último cierre, ya resueltas por el Service. Acá no se mira ningún
/// estado: qué es "abierta" y qué es "cierre" lo decide el Service con
/// `EstadosPedido`, y este módulo se testea solo.
///
/// **La regla del PO (2026-08-10), que es lo que hace a este archivo corto:**
/// si la agenda tiene una entrega abierta, NO hay próxima fecha. Punto, y para
/// las TRES frecuencias. Recién cuando esa entrega se cierra se calcula la
/// siguiente, y ahí sí el origen depende del tipo.
///
/// **NO HAY GRACIA.** Si nadie recepciona, la serie espera indefinidamente: el
/// PO eligió la regla dura sabiendo el riesgo. Por eso [resolver] no recibe el
/// `N` del ciclo — no hay ninguna duración contra la cual comparar, y un
/// parámetro sin uso sería justo el gancho para que alguien reponga la gracia.
/// (`hoy` sí entra, pero sólo para el piso de búsqueda, nunca para decidir si
/// el bloqueo sigue vigente.) La mitigación del riesgo es de la UI —mostrar
/// destacada la entrega vencida y avisar "la próxima se agenda cuando recibas
/// la del 12/08"—, no de la aritmética.
///
/// **El bloqueo es POR AGENDA, nunca por proveedor**: acá no hay proveedor.
library;

import 'agenda_recurrente.dart';
import 'fecha_recepcion.dart';

class AnclaAgenda {
  /// Nunca cerró un ciclo (o la grilla no se mueve con los cierres): se cuenta
  /// desde `fechaInicio`.
  static const String motivoInicio = 'inicio';

  /// Ancla real con un cierre a cuestas: se cuenta desde el día en que se
  /// recibió.
  static const String motivoCierre = 'cierre';

  /// Hay una entrega abierta: la serie espera. No hay próxima fecha.
  static const String motivoCicloAbierto = 'ciclo_abierto';

  /// Origen desde el que se cuenta, siempre a medianoche.
  final DateTime base;

  /// `0` ⇒ la propia [base] puede ser ocurrencia; `1` ⇒ ya se consumió y la
  /// próxima cae estrictamente después. Se pasa tal cual a
  /// `AgendaRecurrente.proxima`.
  final int minimoK;

  /// `true` ⇒ **no hay próxima fecha todavía**. Quien llame tiene que cortar
  /// acá: [base] y [minimoK] son sólo una degradación razonable (posterior a la
  /// entrega abierta) para que un descuido no produzca una fecha absurda.
  final bool enEspera;

  /// Piso desde el que hay que BUSCAR: se pasa como `desde` a
  /// `AgendaRecurrente.proxima`. Viene calculado acá adentro a propósito —ver
  /// la nota de [resolver]— para que no se pueda usar el ancla sin el piso.
  final DateTime desde;

  /// Uno de [motivoInicio], [motivoCierre] o [motivoCicloAbierto]. Es lo que la
  /// UI usa para explicar por qué la agenda no muestra fecha.
  final String motivo;

  const AnclaAgenda._({
    required this.base,
    required this.minimoK,
    required this.enEspera,
    required this.desde,
    required this.motivo,
  });

  /// Resuelve el ancla de UNA agenda.
  ///
  /// - [hayEntregaAbierta]: si ESTA agenda tiene una entrega que todavía no
  ///   cerró su ciclo. El Service lo calcula con `!EstadosPedido.esHistorial(...)`.
  ///   Un pedido cancelado ya es historial, así que deja de bloquear en el acto.
  /// - [fechaProgramadaAbierta]: la fecha de esa entrega, SÓLO para el texto de
  ///   la UI ("la próxima se agenda cuando recibas la del 12/08"). Puede ser
  ///   `null` y eso NO levanta el bloqueo: ver la nota de abajo.
  /// - [ultimoCierre]: día de la última recepción que cerró un ciclo de esta
  ///   agenda. Es un DERIVADO (no se persiste en la agenda), por eso entra como
  ///   parámetro.
  static AnclaAgenda resolver({
    required ConfigRecurrencia config,
    required bool hayEntregaAbierta,
    required DateTime hoy,
    DateTime? ultimaOcurrenciaEmitida,
    DateTime? ultimoCierre,
    DateTime? fechaProgramadaAbierta,
  }) {
    // El piso se calcula ACÁ y viaja en el resultado, en vez de quedar en una
    // función suelta que el Service tiene que acordarse de llamar. Antes eran
    // dos llamadas independientes y nada las acoplaba: quien resolviera el
    // ancla y se olvidara del piso re-emitía la MISMA fecha de grilla —la
    // entrega del lunes recibida ese lunes volvía a ofrecer ese lunes— y la
    // falla era silenciosa: se materializaba un pedido duplicado, sin error.
    // Un docstring no es un compilador; un campo requerido sí.
    final desde = _pisoDeBusqueda(
      hoy: hoy,
      ultimaOcurrenciaEmitida: ultimaOcurrenciaEmitida,
    );
    // REGLA ÚNICA Y PREVIA. Vale para semanal, mensual y cada N días, con
    // cualquier ancla: "no se agendará otro pedido hasta que se recepcione el
    // pendiente". Va PRIMERO justamente para que ninguna rama de abajo pueda
    // saltearla.
    //
    // El bloqueo cuelga del BOOLEANO y no de la fecha, a propósito: la fecha de
    // un pedido es nullable y se puede BORRAR desde la UI (HU-142 dejó el campo
    // opcional, con su X para vaciarlo). Si el bloqueo dependiera de la fecha,
    // borrarla en una entrega abierta lo levantaría en silencio y la agenda
    // emitiría una segunda entrega con la primera sin recibir — justo lo que el
    // PO prohibió. Y la segunda red se cae por la MISMA causa: el índice único
    // `ux_pedidos_ocurrencia` es sobre (agenda_id, fecha), y Postgres considera
    // los NULL distintos entre sí, así que tampoco frenaría el duplicado.
    final abierta = FechaRecepcion.soloDiaNullable(fechaProgramadaAbierta);
    if (hayEntregaAbierta) {
      return AnclaAgenda._(
        // Sin fecha conocida se cae a la de inicio: `base` y `minimoK` son una
        // degradación deliberada mientras `enEspera` es true (el Service tiene
        // que cortar por ahí), no una respuesta alternativa.
        base: abierta ?? config.fechaInicio,
        minimoK: 1,
        enEspera: true,
        desde: desde,
        motivo: motivoCicloAbierto,
      );
    }

    // El ancla REAL sólo existe en 'cada N días'. El chequeo del tipo no es
    // decorativo: si una fila semanal o mensual bajara del pull con
    // `ancla = 'recepcion'`, anclar la grilla en el cierre la haría DERIVAR
    // (una mensual del 30 cerrada un 2 de marzo pasaría a ser "todos los 2").
    final cuentaDesdeElCierre =
        config.tipo == TipoFrecuencia.cadaNDias &&
        config.ancla == AnclaRecurrencia.real;
    final cierre = FechaRecepcion.soloDiaNullable(ultimoCierre);
    if (cuentaDesdeElCierre && cierre != null) {
      return AnclaAgenda._(
        base: cierre,
        minimoK:
            1, // "cierre + N": el día que se recibió no es el próximo pedido
        enEspera: false,
        desde: desde,
        motivo: motivoCierre,
      );
    }

    // Fallback EXPLÍCITO, no accidental: sin cierre, el ancla real se comporta
    // igual que la fija hasta el primer cierre. Y para semanal, mensual y
    // 'cada N días' fija, el cierre no mueve nada: la grilla no espera a nadie.
    return AnclaAgenda._(
      base: config.fechaInicio,
      minimoK: 0,
      enEspera: false,
      desde: desde,
      motivo: motivoInicio,
    );
  }

  /// Piso desde el que hay que BUSCAR la próxima ocurrencia: `hoy`, o el día
  /// siguiente a la última ocurrencia ya emitida si ésa es posterior.
  ///
  /// PRIVADA a propósito: la calcula [resolver] y la devuelve en [desde]. Si
  /// fuera pública volvería a ser posible resolver el ancla sin el piso.
  ///
  /// **Sin esto la serie se duplica.** Dos motivos distintos, los dos reales:
  ///  1. La grilla fija (semanal, mensual y 'cada N días' fija) NO se mueve al
  ///     cerrar el ciclo: si la entrega del lunes se recibe ese mismo lunes, la
  ///     grilla vuelve a ofrecer ese lunes. El único dato que dice "esa ya se
  ///     emitió" es `fechaUltimaOcurrenciaEmitida`.
  ///  2. La ocurrencia se materializa POR ADELANTADO, así que la última emitida
  ///     suele estar en el FUTURO: una entrega programada para el 15/09 que se
  ///     recibe el 10/09, con N = 1 y ancla real, daría "cierre + 1" = 11/09,
  ///     anterior a una fecha que ya existe como pedido.
  ///
  /// Es además lo que hace que "saltar esta vez" funcione: el borrador borrado
  /// no se resucita en el próximo arranque.
  static DateTime _pisoDeBusqueda({
    required DateTime hoy,
    DateTime? ultimaOcurrenciaEmitida,
  }) {
    final dia = FechaRecepcion.soloDia(hoy);
    final ultima = FechaRecepcion.soloDiaNullable(ultimaOcurrenciaEmitida);
    if (ultima == null) return dia;
    // Con el constructor, nunca con Duration (ver AgendaRecurrente).
    final siguiente = DateTime(ultima.year, ultima.month, ultima.day + 1);
    return siguiente.isAfter(dia) ? siguiente : dia;
  }

  @override
  String toString() =>
      'AnclaAgenda(base: ${FechaRecepcion.formatear(base)}, '
      'minimoK: $minimoK, enEspera: $enEspera, '
      'desde: ${FechaRecepcion.formatear(desde)}, motivo: $motivo)';
}
