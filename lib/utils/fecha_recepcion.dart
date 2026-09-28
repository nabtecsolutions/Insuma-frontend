/// Reglas de la **fecha de recepción deseada** de un pedido (HU-142).
///
/// Módulo PURO: sin Flutter y sin base de datos, para que la regla se pueda
/// testear sola y la compartan el formulario del pedido, el Service y —cuando
/// llegue— el generador de agendas recurrentes de HU-013.
///
/// La fecha es un **día de calendario**, no un instante: se normaliza siempre a
/// medianoche local para que dos fechas del mismo día comparen iguales sin
/// importar a qué hora se tocó el botón.
class FechaRecepcion {
  FechaRecepcion._();

  /// Tope hacia adelante. Evita el dedazo de elegir el año 2030 en el
  /// calendario sin que nadie lo note hasta que el pedido queda en el limbo.
  static const int mesesMaximos = 6;

  /// Devuelve [fecha] a medianoche local, descartando la hora.
  static DateTime soloDia(DateTime fecha) =>
      DateTime(fecha.year, fecha.month, fecha.day);

  /// Días de calendario que van de [a] a [b] (positivo si [b] es posterior).
  ///
  /// Se calcula sobre `DateTime.utc` a propósito: en hora local, un tramo que
  /// cruza un cambio de horario dura 23 o 25 horas y `difference().inDays` se
  /// come un día (o inventa uno). En UTC no hay saltos y la cuenta es exacta.
  ///
  /// Vivió en `AgendaRecurrente` hasta #268, que la necesitó desde un segundo
  /// módulo (`semaforo_entrega.dart`). Se mudó acá en vez de copiarse: es la
  /// aritmética de "día de calendario", que es justo lo que define esta clase,
  /// y dos implementaciones del mismo DST se desincronizan al primer retoque.
  static int diasEntre(DateTime a, DateTime b) => DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  /// Igual que [soloDia] pero tolera `null`, que es un valor válido: el campo
  /// es opcional. Evita repetir el `== null ? null : ...` en cada persistencia.
  static DateTime? soloDiaNullable(DateTime? fecha) =>
      fecha == null ? null : soloDia(fecha);

  /// Primer día elegible: **hoy** (decisión del PO del 2026-08-08 — un pedido
  /// se puede pedir y recibir el mismo día).
  static DateTime minima({DateTime? hoy}) => soloDia(hoy ?? DateTime.now());

  /// Último día elegible: hoy + [mesesMaximos].
  ///
  /// Se construye con `DateTime(año, mes + N, día)`, que normaliza solo el
  /// desborde de mes; para un día que no existe en el mes destino (31 de agosto
  /// + 6 meses → "31 de febrero") Dart corre al día siguiente válido, que es
  /// un tope aceptable.
  static DateTime maxima({DateTime? hoy}) {
    final d = minima(hoy: hoy);
    return DateTime(d.year, d.month + mesesMaximos, d.day);
  }

  /// `true` si [fecha] cae dentro de la ventana elegible \[hoy, hoy+6 meses\].
  ///
  /// Una fecha nula es válida: el campo es OPCIONAL (decisión del PO). Quien
  /// necesite distinguir "sin fecha" de "fecha mala" debe chequear el null antes.
  static bool esValida(DateTime? fecha, {DateTime? hoy}) {
    if (fecha == null) return true;
    final d = soloDia(fecha);
    return !d.isBefore(minima(hoy: hoy)) && !d.isAfter(maxima(hoy: hoy));
  }

  /// Motivo del rechazo, o `null` si [fecha] es aceptable.
  ///
  /// Devolver el texto acá —y no en la pantalla— mantiene el mensaje único para
  /// el formulario, el Service y cualquier otra entrada futura.
  static String? validar(DateTime? fecha, {DateTime? hoy}) {
    if (fecha == null) return null;
    final d = soloDia(fecha);
    if (d.isBefore(minima(hoy: hoy))) {
      return 'La fecha de recepción no puede ser anterior a hoy.';
    }
    if (d.isAfter(maxima(hoy: hoy))) {
      return 'La fecha de recepción no puede pasar los $mesesMaximos meses.';
    }
    return null;
  }

  /// Formato corto para mostrar: `dd/mm/aaaa`. Vacío si no hay fecha.
  static String formatear(DateTime? fecha) {
    if (fecha == null) return '';
    final d = soloDia(fecha);
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year}';
  }

  /// Formato sin año: `dd/mm`. Vacío si no hay fecha.
  ///
  /// Para rótulos donde el año es ruido —el encabezado de una sección de la
  /// lista de recepciones (#277)— y el largo compite con el resto de la línea.
  static String formatearCorto(DateTime? fecha) {
    if (fecha == null) return '';
    final completo = formatear(fecha);
    // Se recorta el formato largo en vez de repetir el padding: una sola
    // definición de "cómo se escribe un día" y no dos que se desincronizan.
    return completo.substring(0, 5);
  }

  /// Serializa para Supabase como `aaaa-mm-dd` (columna `date`).
  ///
  /// A propósito NO se usa `toIso8601String()`: ese formato arrastra la hora y
  /// la zona, que es justo lo que esta columna no debe tener.
  static String? aIso(DateTime? fecha) {
    if (fecha == null) return null;
    final d = soloDia(fecha);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  /// Parsea lo que baja de Supabase. Tolera tanto `aaaa-mm-dd` como un
  /// timestamp completo (por si la columna cambiara de tipo), y siempre
  /// devuelve el día a medianoche local.
  static DateTime? desdeIso(dynamic valor) {
    if (valor == null) return null;
    if (valor is DateTime) return soloDia(valor);
    if (valor is! String || valor.isEmpty) return null;
    final parseada = DateTime.tryParse(valor);
    return parseada == null ? null : soloDia(parseada);
  }
}
