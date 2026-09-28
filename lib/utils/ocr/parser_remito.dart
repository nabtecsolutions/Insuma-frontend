import 'contrato_datos_ocr.dart';

/// Parser HEURÍSTICO del texto reconocido de un remito/factura argentino
/// (HU-144). Lógica PURA (sin IO ni ML): recibe el texto crudo del motor y los
/// ítems del pedido, y devuelve sugerencias de precio por insumo y el total.
///
/// Heurísticas (en orden):
///  • Números en formato AR: `1.234,56`, `$ 850`, `850.50` — [parsearNumeroAr].
///  • Matching de línea → insumo por PALABRAS completas del nombre (más de la
///    mitad de los tokens presentes, sin acentos ni mayúsculas), con
///    asignación GLOBAL por mejor puntaje (una línea y un insumo, una vez).
///  • En la línea matcheada (ceros descartados): si hay ≥3 números, el primero
///    ≈ cantidad y cantidad×precio ≈ importe, el segundo es el precio; si no,
///    el último número es el IMPORTE (precio = importe / cantidad recibida,
///    con la pedida como fallback).
///  • Total: número de la última línea que contiene "total" (ignorando
///    "subtotal" si hay un "total" posterior); sin esa palabra, no se sugiere
///    total (mejor no sugerir que sugerir cualquier cosa).
///
/// Cada valor es una SUGERENCIA: la UI los marca, son editables y nada se
/// persiste sin confirmación humana (criterio de la HU).
class ParserRemito {
  ParserRemito._();

  /// Parsea el [texto] del OCR contra los [itemsPedido]
  /// (`{insumoId, nombre, cantidadPedida|cantidad, ...}`). Devuelve null si no
  /// se pudo sugerir NADA (el llamador cae al flujo manual).
  static SugerenciasRemito? parsear({
    required String texto,
    required List<Map<String, dynamic>> itemsPedido,
  }) {
    if (texto.trim().isEmpty) return null;
    final lineasTexto = texto
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lineasTexto.isEmpty) return null;

    // Fase 1: TODOS los puntajes (ítem × línea). La asignación es GLOBAL por
    // mejor puntaje (no greedy en orden del pedido): así un ítem ausente del
    // remito no le "roba" la línea a otro que matchea mejor. El corte es
    // ESTRICTO (> 0.5): compartir la mitad de los tokens (p. ej. sólo
    // "aceite" entre oliva y girasol) no alcanza para sugerir un precio.
    final candidatos = <({String insumoId, int idx, double puntaje})>[];
    final porId = {
      for (final it in itemsPedido)
        if (it['insumoId'] != null) it['insumoId'] as String: it,
    };
    final palabrasPorLinea = [
      for (final l in lineasTexto)
        _normalizar(
          l,
        ).split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toSet(),
    ];
    for (final entrada in porId.entries) {
      final tokens = _tokens((entrada.value['nombre'] ?? '').toString());
      if (tokens.isEmpty) continue;
      for (var i = 0; i < lineasTexto.length; i++) {
        // Palabra COMPLETA (no substring): "sol" no matchea "girasol".
        final aciertos = tokens.where(palabrasPorLinea[i].contains).length;
        final puntaje = aciertos / tokens.length;
        if (puntaje > 0.5) {
          candidatos.add((insumoId: entrada.key, idx: i, puntaje: puntaje));
        }
      }
    }
    candidatos.sort((a, b) => b.puntaje.compareTo(a.puntaje));

    final porInsumo = <String, SugerenciaPrecio>{};
    final lineasOcr = <LineaOcr>[];
    final usadas = <int>{};
    for (final c in candidatos) {
      if (porInsumo.containsKey(c.insumoId) || usadas.contains(c.idx)) continue;
      final item = porId[c.insumoId]!;
      final linea = lineasTexto[c.idx];
      // Los ceros se descartan: el "000" de "HARINA 000" parsea como 0 y
      // rompería la detección de la columna cantidad.
      final numeros = extraerNumerosAr(
        linea,
      ).where((v) => v > 0).toList(growable: false);
      if (numeros.isEmpty) continue;

      // Divisor: la cantidad RECIBIDA actual si existe (>0); si no, la pedida.
      final recibida = (item['cantidadRecibida'] as num?)?.toDouble() ?? 0.0;
      final pedida =
          ((item['cantidadPedida'] ?? item['cantidad']) as num?)?.toDouble() ??
          0.0;
      final cantidad = recibida > 0 ? recibida : pedida;

      double? precio;
      if (numeros.length >= 3 &&
          cantidad > 0 &&
          _aprox(numeros.first, cantidad) &&
          _aproxRel(numeros[1] * numeros.first, numeros.last)) {
        // "SAL FINA  1  300  300,00" → cantidad, precio, importe COHERENTES.
        precio = numeros[1];
      } else if (numeros.length >= 3 &&
          cantidad > 0 &&
          _aprox(numeros.first, cantidad)) {
        precio = numeros[1]; // sin importe verificable: mejor esfuerzo
      } else {
        // Uno o dos números (o no arranca con la cantidad): el último es el
        // IMPORTE de la línea ("Harina x2 … 1.700,00" → 1700/2 = 850).
        final importe = numeros.last;
        precio = cantidad > 0 ? importe / cantidad : importe;
      }
      if (precio <= 0 || !precio.isFinite) continue;

      usadas.add(c.idx);
      porInsumo[c.insumoId] = SugerenciaPrecio(
        insumoId: c.insumoId,
        precioUnitario: _redondear2(precio),
        textoFuente: linea,
      );
      lineasOcr.add(
        LineaOcr(
          texto: linea,
          cantidad: cantidad > 0 ? cantidad : null,
          precioUnitario: _redondear2(precio),
          insumoId: c.insumoId,
        ),
      );
    }

    // Total: la ÚLTIMA línea con "total" que no sea un total intermedio del
    // desglose fiscal (subtotal, total iva, total neto/bruto/gravado) — ese
    // valor precarga el total manual de HU-143 y NO puede ser el IVA.
    double? totalDetectado;
    final excluidas = RegExp(r'subtotal|iva|neto|bruto|gravado');
    for (final linea in lineasTexto) {
      final norm = _normalizar(linea);
      if (!norm.contains('total') || excluidas.hasMatch(norm)) continue;
      final numeros = extraerNumerosAr(linea);
      if (numeros.isNotEmpty) totalDetectado = _redondear2(numeros.last);
    }

    if (porInsumo.isEmpty && totalDetectado == null) return null;

    return SugerenciasRemito(
      porInsumo: porInsumo,
      totalDetectado: totalDetectado,
      lineas: lineasOcr,
    );
  }

  /// Números de una línea en formato AR: `1.234,56` (miles con punto, decimal
  /// con coma), `850,50`, `850.50`, `$ 850`. Devuelve en orden de aparición.
  static List<double> extraerNumerosAr(String linea) {
    final regex = RegExp(
      r'\$?\s*(\d{1,3}(?:\.\d{3})+(?:,\d+)?|\d+(?:[.,]\d+)?)',
    );
    final resultado = <double>[];
    for (final m in regex.allMatches(linea)) {
      final v = parsearNumeroAr(m.group(1)!);
      if (v != null) resultado.add(v);
    }
    return resultado;
  }

  /// `1.234,56` → 1234.56 · `850,5` → 850.5 · `850.50` → 850.5 · `1200` → 1200.
  static double? parsearNumeroAr(String crudo) {
    var s = crudo.trim();
    if (s.contains(',')) {
      // Coma = decimal AR; los puntos son miles.
      s = s.replaceAll('.', '').replaceAll(',', '.');
    } else if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(s)) {
      // Sólo puntos con grupos de 3: son miles ("1.700" = 1700).
      s = s.replaceAll('.', '');
    }
    return double.tryParse(s);
  }

  static String _normalizar(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[áàä]'), 'a')
      .replaceAll(RegExp(r'[éèë]'), 'e')
      .replaceAll(RegExp(r'[íìï]'), 'i')
      .replaceAll(RegExp(r'[óòö]'), 'o')
      .replaceAll(RegExp(r'[úùü]'), 'u')
      .replaceAll('ñ', 'n');

  /// Tokens significativos del nombre de un insumo (≥3 letras, sin números).
  static List<String> _tokens(String nombre) => _normalizar(
    nombre,
  ).split(RegExp(r'[^a-z]+')).where((t) => t.length >= 3).toList();

  static bool _aprox(double a, double b) => (a - b).abs() < 0.001;

  /// Aproximación RELATIVA (2%) para validar cantidad × precio ≈ importe
  /// (tolera redondeos de la impresión del remito).
  static bool _aproxRel(double a, double b) =>
      b != 0 && ((a - b).abs() / b.abs()) < 0.02;

  static double _redondear2(double v) => (v * 100).roundToDouble() / 100;
}

/// Sugerencia de precio unitario para UN insumo del pedido.
class SugerenciaPrecio {
  final String insumoId;
  final double precioUnitario;

  /// Línea del OCR de la que salió (trazabilidad en la UI).
  final String textoFuente;

  const SugerenciaPrecio({
    required this.insumoId,
    required this.precioUnitario,
    required this.textoFuente,
  });
}

/// Resultado del parseo de un remito: sugerencias por insumo + total detectado
/// + las líneas ya asociadas (para armar el [DatosOcr] que persiste HU-068).
class SugerenciasRemito {
  final Map<String, SugerenciaPrecio> porInsumo;
  final double? totalDetectado;
  final List<LineaOcr> lineas;

  const SugerenciasRemito({
    required this.porInsumo,
    this.totalDetectado,
    this.lineas = const [],
  });

  bool get hayAlgo => porInsumo.isNotEmpty || totalDetectado != null;
}
