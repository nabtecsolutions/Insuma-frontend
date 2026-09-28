import 'dart:convert';

/// Contrato VERSIONADO del JSON que se persiste en `adjuntos.datos_ocr`
/// (HU-068, cimientos del reconocimiento del remito/factura).
///
/// Lógica PURA (sin IO): define la forma del resultado del reconocimiento y su
/// (de)serialización tolerante. La versión `v` permite evolucionar el contrato
/// sin romper lectores viejos: un `v` desconocido se lee como null (el consumidor
/// cae al flujo manual, criterio de HU-144).
///
/// `lineas[].insumoId` es nullable A PROPÓSITO: el modelo no impide asociar el
/// resultado OCR a los ítems del pedido (criterio de la HU) sin construir el
/// matching todavía — HU-144 lo poblará al matchear contra el pedido.
class DatosOcr {
  /// Versión vigente del contrato.
  static const int versionActual = 1;

  final int v;

  /// Motor que produjo el resultado: 'mlkit' (HU-144) o 'manual'.
  final String motor;

  /// Momento del reconocimiento (ISO-8601). String a propósito: es un dato de
  /// evidencia, no se opera con él.
  final String fecha;

  /// Texto completo reconocido, para re-parsear con heurísticas futuras sin
  /// volver a correr el OCR.
  final String textoCompleto;

  final List<LineaOcr> lineas;

  /// Total detectado en el documento (null si no se encontró).
  final double? totalDetectado;

  /// Confianza global del reconocimiento (0..1; 0 si el motor no la informa).
  final double confianza;

  const DatosOcr({
    this.v = versionActual,
    required this.motor,
    required this.fecha,
    this.textoCompleto = '',
    this.lineas = const [],
    this.totalDetectado,
    this.confianza = 0.0,
  });

  Map<String, dynamic> toJson() => {
    'v': v,
    'motor': motor,
    'fecha': fecha,
    'textoCompleto': textoCompleto,
    'lineas': [for (final l in lineas) l.toJson()],
    // jsonEncode LANZA con doubles no finitos (NaN/Infinity de un motor
    // futuro, p. ej. 0/0): el contrato los sanea en el borde.
    'totalDetectado': finitoONull(totalDetectado),
    'confianza': finitoONull(confianza) ?? 0.0,
  };

  /// null si [v] no es un double finito (NaN/±Infinity no son serializables).
  static double? finitoONull(double? v) => (v != null && v.isFinite) ? v : null;

  String serializar() => jsonEncode(toJson());

  /// Lectura TOLERANTE: campos ausentes toman defaults; una versión mayor a la
  /// conocida (o un JSON ilegible) devuelve null — el consumidor no debe
  /// interpretar un contrato que no conoce.
  static DatosOcr? desdeJson(String? json) {
    if (json == null || json.trim().isEmpty) return null;
    try {
      final m = jsonDecode(json);
      if (m is! Map<String, dynamic>) return null;
      final v = (m['v'] as num?)?.toInt() ?? 1;
      if (v > versionActual) return null;
      return DatosOcr(
        v: v,
        motor: (m['motor'] as String?) ?? 'manual',
        fecha: (m['fecha'] as String?) ?? '',
        textoCompleto: (m['textoCompleto'] as String?) ?? '',
        lineas: [
          for (final l in (m['lineas'] as List? ?? const []))
            if (l is Map<String, dynamic>) LineaOcr.desdeMapa(l),
        ],
        totalDetectado: (m['totalDetectado'] as num?)?.toDouble(),
        confianza: (m['confianza'] as num?)?.toDouble() ?? 0.0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Una línea reconocida del documento, opcionalmente asociada a un insumo.
class LineaOcr {
  final String texto;
  final double? cantidad;
  final double? precioUnitario;
  final double? total;

  /// Insumo del pedido al que se asoció la línea (null = sin matchear aún).
  final String? insumoId;

  const LineaOcr({
    required this.texto,
    this.cantidad,
    this.precioUnitario,
    this.total,
    this.insumoId,
  });

  Map<String, dynamic> toJson() => {
    'texto': texto,
    'cantidad': DatosOcr.finitoONull(cantidad),
    'precioUnitario': DatosOcr.finitoONull(precioUnitario),
    'total': DatosOcr.finitoONull(total),
    'insumoId': insumoId,
  };

  factory LineaOcr.desdeMapa(Map<String, dynamic> m) => LineaOcr(
    texto: (m['texto'] as String?) ?? '',
    cantidad: (m['cantidad'] as num?)?.toDouble(),
    precioUnitario: (m['precioUnitario'] as num?)?.toDouble(),
    total: (m['total'] as num?)?.toDouble(),
    insumoId: m['insumoId'] as String?,
  );
}
