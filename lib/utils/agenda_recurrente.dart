/// Aritmética de las agendas de pedidos recurrentes (HU-013).
///
/// Módulo PURO: sin Flutter, sin drift y sin IO, para que la regla se pueda
/// testear sola y la compartan el wizard, el Service y el generador. Mismo
/// molde que `fecha_recepcion.dart` (HU-142): constructor privado, todo
/// `static`, y **cero código de fechas propio** — la normalización a día sale
/// de [FechaRecepcion.soloDia], que ya es la definición de "día" de la casa.
///
/// Tres cosas que NO están acá, a propósito:
///  • **El proveedor.** Este módulo ve UNA agenda y calcula SU serie, nada más.
///    El bloqueo que pidió el PO es por AGENDA ("que no me entregue las peras
///    del lunes no debe bloquear las bananas del jueves"): si acá apareciera el
///    proveedor, alguien terminaría cruzando series distintas.
///  • **La coherencia entre campos** (que un 'semanal' no traiga `diaMes`). Esa
///    barrera es el CHECK de Postgres: un constraint local convierte el pull en
///    un descartador silencioso de filas (misma doctrina que la tabla `Insumos`).
///  • **La ventana de 6 meses** de `FechaRecepcion.validar`. Ese tope es del
///    PEDIDO que se materializa, no de la regla: la agenda proyecta más lejos
///    —la vista previa del wizard tiene que explicar un corrimiento que cae a 7
///    meses— y es el Service el que decide qué materializa y qué no.
library;

import 'dart:math' as math;

import 'fecha_recepcion.dart';

/// Cada cuánto se repite una agenda.
///
/// Se persiste como texto ('semanal' | 'mensual' | 'cada_n_dias'): ver
/// [AgendaRecurrente.codigoDeTipo] y [AgendaRecurrente.tipoDesdeCodigo].
enum TipoFrecuencia { semanal, mensual, cadaNDias }

/// Desde dónde se cuentan los días en 'cada N días'.
///
/// SÓLO aplica a [TipoFrecuencia.cadaNDias]: semanal y mensual tienen grilla
/// propia (día de la semana / día del mes) y no dependen de ninguna recepción.
enum AnclaRecurrencia {
  /// "Contar igual, aunque el pedido se atrase": la grilla arranca en
  /// `fechaInicio` y no espera a nadie.
  fija,

  /// "Contar desde que RECIBO el pedido": la próxima se cuenta desde el día del
  /// último cierre. En la base se guarda como `'recepcion'`, no como `'real'`
  /// (el código nombra el evento que la mueve). Ojo al mapear.
  real,
}

/// La REGLA de una agenda: qué se repite y desde cuándo. Nada de la base.
class ConfigRecurrencia {
  final TipoFrecuencia tipo;

  /// Días elegidos, 1..7 con la convención de `DateTime.weekday` (1 = lunes).
  /// Varios días ⇒ varias entregas por semana, y siguen siendo UNA sola serie
  /// (si se las quiere independientes, se modelan como dos agendas).
  final Set<int> diasSemana;

  /// Día del mes, 1..31, SIN recorte. Ver [AgendaRecurrente.proxima].
  final int? diaMes;

  /// Cantidad de días del ciclo, > 0.
  final int? cadaNDias;

  final AnclaRecurrencia ancla;

  /// Primer día en que la agenda puede entregar. Es un PISO además de un
  /// origen: nunca se emite una ocurrencia anterior, ni siquiera si la grilla
  /// (por ejemplo "todos los lunes") existiría desde antes.
  final DateTime fechaInicio;

  ConfigRecurrencia({
    required this.tipo,
    required DateTime fechaInicio,
    Set<int> diasSemana = const {},
    this.diaMes,
    this.cadaNDias,
    this.ancla = AnclaRecurrencia.fija,
  }) : fechaInicio = FechaRecepcion.soloDia(fechaInicio),
       // Copia inmutable: la config viaja al wizard, al Service y al
       // generador, y ninguno de los tres debería poder editarle los días al
       // otro por referencia.
       diasSemana = Set.unmodifiable(diasSemana);
}

/// Generador de las fechas de una agenda. Todo estático y sin estado.
class AgendaRecurrente {
  AgendaRecurrente._();

  // --------------------------------------------------------------------------
  // Serialización: los códigos con los que la regla viaja a Drift y a Supabase.
  // --------------------------------------------------------------------------

  static const String codigoSemanal = 'semanal';
  static const String codigoMensual = 'mensual';
  static const String codigoCadaNDias = 'cada_n_dias';

  /// Código del ancla REAL en la base. NO es `'real'`: la columna nombra el
  /// evento que mueve la cuenta (la recepción). Es la trampa más fácil de esta
  /// serialización, por eso está como constante y no como literal suelto.
  static const String codigoAnclaRecepcion = 'recepcion';
  static const String codigoAnclaFija = 'fija';

  static const Map<String, TipoFrecuencia> _tiposPorCodigo = {
    codigoSemanal: TipoFrecuencia.semanal,
    codigoMensual: TipoFrecuencia.mensual,
    codigoCadaNDias: TipoFrecuencia.cadaNDias,
  };

  static String codigoDeTipo(TipoFrecuencia tipo) => switch (tipo) {
    TipoFrecuencia.semanal => codigoSemanal,
    TipoFrecuencia.mensual => codigoMensual,
    TipoFrecuencia.cadaNDias => codigoCadaNDias,
  };

  /// Devuelve `null` ante un código desconocido o nulo, y es a propósito: no
  /// hay default sano para una frecuencia. Adivinar "semanal" le inventaría al
  /// negocio entregas que nadie pidió; quien lea una fila así la tiene que
  /// saltear.
  static TipoFrecuencia? tipoDesdeCodigo(String? codigo) =>
      _tiposPorCodigo[codigo];

  static String codigoDeAncla(AnclaRecurrencia ancla) => switch (ancla) {
    AnclaRecurrencia.fija => codigoAnclaFija,
    AnclaRecurrencia.real => codigoAnclaRecepcion,
  };

  /// Acá sí hay default: la columna `ancla` es NULL para semanal y mensual, y
  /// FIJA es la lectura conservadora (la grilla no espera a nadie). Sólo el
  /// código exacto `'recepcion'` activa el ancla real.
  static AnclaRecurrencia anclaDesdeCodigo(String? codigo) =>
      codigo == codigoAnclaRecepcion
      ? AnclaRecurrencia.real
      : AnclaRecurrencia.fija;

  /// Días de la semana ⇒ entero 1..127, con el bit `(weekday - 1)`.
  ///
  /// Una sola columna `smallint`, sin parsear strings, que soporta un día o los
  /// siete sin cambiar nada. Los valores fuera de 1..7 se ignoran en vez de
  /// desbordar la máscara: ya los rechaza [validar], acá sólo se evita escribir
  /// un número que el CHECK de Postgres tiraría.
  static int aBitmask(Set<int> diasSemana) {
    var mascara = 0;
    for (final dia in diasSemana) {
      if (dia < DateTime.monday || dia > DateTime.sunday) continue;
      mascara |= 1 << (dia - 1);
    }
    return mascara;
  }

  /// Inversa de [aBitmask]. Devuelve los días en orden (lunes → domingo).
  ///
  /// Una máscara nula o 0 da un set VACÍO, que [validar] rechaza: es el estado
  /// imposible de guardar desde la app, pero alcanzable desde el pull.
  static Set<int> desdeBitmask(int? mascara) {
    final dias = <int>{};
    if (mascara == null) return dias;
    for (var dia = DateTime.monday; dia <= DateTime.sunday; dia++) {
      if ((mascara & (1 << (dia - 1))) != 0) dias.add(dia);
    }
    return dias;
  }

  // --------------------------------------------------------------------------
  // Validación
  // --------------------------------------------------------------------------

  /// Motivo del rechazo, o `null` si la config es usable. Mismo contrato que
  /// `FechaRecepcion.validar`: el texto vive acá, no en la pantalla, para que
  /// el formulario y el Service digan lo mismo.
  ///
  /// Sólo se valida lo que la aritmética necesita de CADA tipo, no la
  /// coherencia cruzada entre campos (eso es del CHECK de Postgres). Y no es
  /// una validación cosmética: los datos no vienen únicamente de la grilla del
  /// wizard, también del pull de Supabase.
  static String? validar(ConfigRecurrencia c) => switch (c.tipo) {
    TipoFrecuencia.semanal => _validarSemanal(c.diasSemana),
    TipoFrecuencia.mensual => _validarMensual(c.diaMes),
    TipoFrecuencia.cadaNDias => _validarCadaNDias(c.cadaNDias),
  };

  static String? _validarSemanal(Set<int> dias) {
    if (dias.isEmpty) return 'Elegí al menos un día de la semana.';
    if (dias.any((d) => d < DateTime.monday || d > DateTime.sunday)) {
      return 'Los días de la semana van de 1 (lunes) a 7 (domingo).';
    }
    return null;
  }

  /// El rango 1..31 NO es un capricho de UI: `DateTime(y, m, 0)` devuelve EN
  /// SILENCIO el último día del mes ANTERIOR (verificado:
  /// `DateTime(2026, 3, 0) == 2026-02-28`). Sin este rechazo, un 0 llegado del
  /// pull corre toda la serie un mes para atrás sin un solo error.
  static String? _validarMensual(int? diaMes) {
    if (diaMes == null || diaMes < 1 || diaMes > 31) {
      return 'Elegí un día del mes, entre 1 y 31.';
    }
    return null;
  }

  /// N ≤ 0 se rechaza ANTES de la aritmética: con 0 hay división por cero y con
  /// negativos el ciclo camina hacia atrás.
  static String? _validarCadaNDias(int? cadaNDias) {
    if (cadaNDias == null || cadaNDias <= 0) {
      return 'La cantidad de días tiene que ser mayor que cero.';
    }
    return null;
  }

  // --------------------------------------------------------------------------
  // Aritmética
  // --------------------------------------------------------------------------

  /// Próxima ocurrencia de [c] a partir de [desde], o `null` si la config es
  /// inválida (no se inventa una fecha con una regla que no cierra).
  ///
  /// - [desde] es **INCLUSIVO**: si hoy cae en la grilla, hoy cuenta. Misma
  ///   decisión que `FechaRecepcion.minima` ("un pedido se puede pedir y
  ///   recibir el mismo día").
  /// - [ancla] es el origen desde el que se cuenta; por defecto `fechaInicio`.
  ///   Lo resuelve `AnclaAgenda`, que es quien sabe si la serie cuenta desde el
  ///   inicio o desde el último cierre.
  /// - [minimoK] es lo ÚNICO que separa los dos anclajes: `0` ⇒ la propia base
  ///   puede ser ocurrencia; `1` (o más) ⇒ la base YA se consumió y la próxima
  ///   cae estrictamente después (el día en que se recibió no es también el día
  ///   del próximo pedido).
  ///
  /// La ocurrencia nunca es anterior a la base: una agenda que arranca en el
  /// futuro no emite nada hasta su `fechaInicio`.
  static DateTime? proxima(
    ConfigRecurrencia c, {
    required DateTime desde,
    DateTime? ancla,
    int minimoK = 0,
  }) {
    if (validar(c) != null) return null;

    final base = FechaRecepcion.soloDia(ancla ?? c.fechaInicio);
    final minK = math.max(0, minimoK);

    // Piso único para las tres frecuencias: nunca antes de la base y, si la
    // base ya se consumió, nunca la base misma. Tenerlo acá arriba es lo que
    // hace que `minimoK` signifique lo mismo en semanal, mensual y cada N días,
    // en vez de tres reglas distintas.
    final pisoBase = minK == 0 ? base : _sumarDias(base, 1);

    // `fechaInicio` es piso SIEMPRE, también cuando viene un [ancla] externa.
    // Sin esta línea el piso se armaba sólo con la base, y como el ancla real
    // SIEMPRE pasa una base (el último cierre), mover la `fechaInicio` hacia
    // adelante —que es como se posterga una serie— no frenaba nada: con cierre
    // el 12/09 y un inicio reeditado al 01/12, la serie seguía emitiendo el
    // 19/09 y materializaba un pedido real dos meses y medio antes.
    // Es no-op en el caso normal (el cierre es posterior al inicio).
    final piso = pisoBase.isAfter(c.fechaInicio) ? pisoBase : c.fechaInicio;
    final dia = FechaRecepcion.soloDia(desde);
    final arranque = dia.isAfter(piso) ? dia : piso;

    // Los `!` son seguros: `validar` ya garantizó el campo que usa cada rama.
    return switch (c.tipo) {
      TipoFrecuencia.semanal => _proximaSemanal(c.diasSemana, arranque),
      TipoFrecuencia.mensual => _proximaMensual(
        base,
        c.diaMes!,
        arranque,
        minK,
      ),
      TipoFrecuencia.cadaNDias => _proximaCadaNDias(
        base,
        c.cadaNDias!,
        arranque,
        minK,
      ),
    };
  }

  /// Las próximas [cantidad] ocurrencias, en orden. Lista vacía si la config es
  /// inválida o si [cantidad] no es positiva.
  ///
  /// Es la vista previa del wizard: proyecta la GRILLA desde [desde]. Para el
  /// ancla real —que depende de un cierre que todavía no ocurrió— no hay
  /// proyección posible más allá de la primera fecha: se usa [proxima].
  /// [minimoK] se aplica SÓLO a la primera vuelta, que es la única que usa la
  /// base: de ahí en adelante el cursor ya está estrictamente después de la
  /// última emitida y un mínimo extra saltearía fechas. Sin este parámetro, una
  /// vista previa con [ancla] traída de un cierre devolvía como primera fecha
  /// el día del cierre mismo — o sea, ofrecía recibir dos veces el mismo día.
  static List<DateTime> proximas(
    ConfigRecurrencia c, {
    required DateTime desde,
    DateTime? ancla,
    int minimoK = 0,
    int cantidad = 3,
  }) {
    final salida = <DateTime>[];
    var cursor = FechaRecepcion.soloDia(desde);
    for (var i = 0; i < cantidad; i++) {
      final fecha = proxima(
        c,
        desde: cursor,
        ancla: ancla,
        minimoK: i == 0 ? minimoK : 0,
      );
      if (fecha == null) break;
      salida.add(fecha);
      // El día siguiente a la última emitida: la serie es estrictamente
      // creciente, así que esto no puede repetir ni saltear una fecha.
      cursor = _sumarDias(fecha, 1);
    }
    return salida;
  }

  /// Primer mes, a partir de [desde], en el que el día [diaMes] NO existe y la
  /// entrega se corre a los primeros días del mes siguiente. `null` si no se
  /// corre nunca (días 1..28) o si no se corre dentro de la ventana escaneada.
  ///
  /// Devuelve el mes INTENTADO (el que no llega al día) y la fecha REAL en la
  /// que caería, que es lo que necesita la franja del wizard: "febrero de 2027
  /// no tiene 30, así que esa entrega cae el 02/03/2027".
  ///
  /// [desde] es el arranque de la PROYECCIÓN, no necesariamente hoy: una agenda
  /// que empieza el año que viene no debe reportar un corrimiento anterior a su
  /// primera entrega.
  static ({int anio, int mes, DateTime real})? primerDesborde(
    int diaMes, {
    required DateTime desde,
  }) {
    // Config inválida: no hay nada que explicarle al usuario.
    if (diaMes < 1 || diaMes > 31) return null;
    // Ningún mes baja de 28 días: del 1 al 28 no hay corrimiento posible.
    if (diaMes <= 28) return null;

    final dia = FechaRecepcion.soloDia(desde);
    for (var k = 0; k < mesesDeEscaneo; k++) {
      final real = DateTime(dia.year, dia.month + k, diaMes);
      if (real.isBefore(dia)) continue; // ocurrencia ya pasada
      if (real.day == diaMes) continue; // el mes llegó al día: no se corre
      // Mes intentado, normalizado por si el desborde cruzó el año:
      // `DateTime(2026, 14, 1)` es febrero de 2027.
      final intentado = DateTime(dia.year, dia.month + k);
      return (anio: intentado.year, mes: intentado.month, real: real);
    }
    return null;
  }

  /// Meses que escanea [primerDesborde]. Son 24 y no 12 por un caso medido: el
  /// día 29 arrancando en marzo de 2027 NO se corre en febrero de 2028 (que es
  /// bisiesto y sí tiene 29) y recién se corre en febrero de 2029, o sea k = 23.
  /// Con 12 meses la pantalla diría "nunca se corre", que es falso.
  static const int mesesDeEscaneo = 24;

  // --------------------------------------------------------------------------
  // Privados: una función por frecuencia, todas O(1) (sin recorrer día por día)
  // --------------------------------------------------------------------------

  /// Suma días con el CONSTRUCTOR, nunca con `Duration`.
  ///
  /// `Duration` es wall-clock: al cruzar un cambio de horario, "sumar 7 días"
  /// deja la fecha en 23:00 o 01:00 y rompe la igualdad con
  /// `FechaRecepcion.soloDia`, que es como toda la app compara días. El
  /// constructor es inmune al horario de verano y encima normaliza gratis el
  /// desborde de mes y de año.
  static DateTime _sumarDias(DateTime dia, int dias) =>
      DateTime(dia.year, dia.month, dia.day + dias);

  /// El día elegido más cercano a [arranque], contando el propio [arranque].
  ///
  /// `delta = (dia - arranque.weekday + 7) % 7` da 0 cuando arranque YA es el
  /// día buscado y 1..6 en cualquier otro caso. No se asume que la semana
  /// empieza el lunes: se usa `DateTime.weekday` tal cual.
  static DateTime _proximaSemanal(Set<int> dias, DateTime arranque) {
    var mejorDelta = 7; // los deltas posibles son 0..6: cualquiera gana
    for (final dia in dias) {
      final delta = (dia - arranque.weekday + 7) % 7;
      if (delta < mejorDelta) mejorDelta = delta;
    }
    return _sumarDias(arranque, mejorDelta);
  }

  /// Ocurrencia mensual número [k] contada desde el mes de [base].
  ///
  /// **NO HAY CÓDIGO DE RECORTE DE FIN DE MES, Y NO ES UN OLVIDO.** La regla
  /// del PO —"si el mes tiene 28 días y se recibe el 30, se recibe el 2 del
  /// próximo mes"— ES, textualmente, la normalización nativa de Dart.
  /// Verificado corriéndolo:
  ///
  /// ```
  /// DateTime(2026, 2, 30) => 2026-03-02   ← feb 2026 tiene 28. El ejemplo del PO.
  /// DateTime(2026, 2, 31) => 2026-03-03
  /// DateTime(2028, 2, 30) => 2028-03-01   ← feb bisiesto (29 días)
  /// DateTime(2026, 4, 31) => 2026-05-01
  /// DateTime(2026, 1, 31) => 2026-01-31   ← enero SÍ tiene 31: no se mueve
  /// DateTime(2026,13,  5) => 2027-01-05   ← el desborde de AÑO sale gratis
  /// ```
  ///
  /// Recortar al último día del mes (un `clamp` a 28/30) sería un **BUG CONTRA
  /// LA ESPECIFICACIÓN**, no un arreglo. Precedente de la casa:
  /// `FechaRecepcion.maxima` ya acepta y documenta este mismo comportamiento.
  ///
  /// Y se cuenta SIEMPRE desde el mes de la base con el día ORIGINAL, jamás
  /// "la ocurrencia anterior + 1 mes": con día 30, febrero daría 2 de marzo y
  /// el mes siguiente 2 de abril, y la serie derivaría para siempre.
  static DateTime _mensual(DateTime base, int k, int diaMes) =>
      DateTime(base.year, base.month + k, diaMes);

  /// Salta directo al mes candidato y ajusta 2 o 3 vueltas como mucho: no
  /// recorre mes por mes desde el inicio de la agenda.
  ///
  /// El `- 1` del arranque es por el corrimiento: la ocurrencia del mes
  /// anterior a [arranque] puede caer DENTRO del mes de [arranque] (el 30 de
  /// febrero es el 2 de marzo) y es la que hay que devolver. Un mes más atrás
  /// no hace falta: el corrimiento máximo es de 3 días, así que nunca alcanza a
  /// llegar al mes de [arranque].
  static DateTime _proximaMensual(
    DateTime base,
    int diaMes,
    DateTime arranque,
    int minimoK,
  ) {
    var k = math.max(
      minimoK,
      (arranque.year - base.year) * 12 + (arranque.month - base.month) - 1,
    );
    var fecha = _mensual(base, k, diaMes);
    while (fecha.isBefore(arranque)) {
      k++;
      fecha = _mensual(base, k, diaMes);
    }
    return fecha;
  }

  /// Fórmula cerrada, sin materializar la serie ni iterar por ciclo: la app
  /// puede haber estado cerrada 4 ciclos y se devuelve UNA fecha, no un backlog
  /// de entregas vencidas.
  static DateTime _proximaCadaNDias(
    DateTime base,
    int n,
    DateTime arranque,
    int minimoK,
  ) {
    // `arranque` ya viene pisado por la base, así que la división nunca es
    // negativa; el `max` con `minimoK` queda igual como red de seguridad.
    final k = math.max(
      minimoK,
      (FechaRecepcion.diasEntre(base, arranque) / n).ceil(),
    );
    return _sumarDias(base, k * n);
  }
}
