import '../data/repositorios/repositorio_adjuntos.dart';
import '../utils/adjuntos/contenido_archivo.dart';
import '../utils/ocr/contrato_datos_ocr.dart';
import '../utils/ocr/parser_remito.dart';
import '../utils/ocr/reconocedor_texto.dart';

/// Servicio de sugerencias por OCR del remito/factura (HU-144).
///
/// Orquesta el motor on-device ([ReconocedorTexto], costo $0) y el parser puro
/// ([ParserRemito]); persiste el resultado en `adjuntos.datos_ocr` a través del
/// repositorio (cimientos de HU-068). Devuelve null ante CUALQUIER fallo: el
/// flujo manual sigue exactamente igual (criterio de la HU).
class ServicioOcrRemito {
  final ReconocedorTexto _reconocedor;
  final RepositorioAdjuntos _adjuntos;

  ServicioOcrRemito(this._reconocedor, this._adjuntos);

  /// ¿Hay motor en esta plataforma? Si es false la UI no muestra "Escanear".
  bool get disponible => _reconocedor.disponible;

  /// Reconoce y parsea [archivo] (imagen staged del remito) contra los
  /// [itemsPedido]. Devuelve las sugerencias + el [DatosOcr] listo para
  /// persistir, o null si no hay motor / no es imagen / no se reconoció nada
  /// útil. NADA se persiste acá: la persistencia ocurre recién al confirmar la
  /// recepción ([guardarResultado]).
  Future<ResultadoOcrRemito?> analizar({
    required ContenidoArchivo archivo,
    required List<Map<String, dynamic>> itemsPedido,
  }) async {
    if (!disponible) return null;
    final texto = await _reconocedor.reconocer(archivo);
    if (texto == null) return null;

    final sugerencias = ParserRemito.parsear(
      texto: texto,
      itemsPedido: itemsPedido,
    );
    if (sugerencias == null || !sugerencias.hayAlgo) return null;

    final datos = DatosOcr(
      motor: 'mlkit',
      fecha: DateTime.now().toUtc().toIso8601String(),
      textoCompleto: texto,
      lineas: sugerencias.lineas,
      totalDetectado: sugerencias.totalDetectado,
      // ML Kit no informa confianza global; 0.0 = "no informada" (contrato v1).
    );
    return ResultadoOcrRemito(sugerencias: sugerencias, datos: datos);
  }

  /// Persiste el resultado del reconocimiento en el adjunto YA CREADO (HU-068).
  /// Best-effort tras confirmar la recepción: un fallo no debe romper el cierre
  /// (la recepción ya está registrada; el OCR es re-escaneable).
  Future<void> guardarResultado({
    required String adjuntoId,
    required String datosOcrJson,
  }) async {
    try {
      await _adjuntos.actualizarDatosOcr(adjuntoId, datosOcrJson);
    } catch (_) {
      /* best-effort: el OCR se puede volver a escanear */
    }
  }
}

/// Salida de [ServicioOcrRemito.analizar]: sugerencias para la UI + el JSON de
/// evidencia listo para persistir al confirmar.
class ResultadoOcrRemito {
  final SugerenciasRemito sugerencias;
  final DatosOcr datos;

  const ResultadoOcrRemito({required this.sugerencias, required this.datos});
}
