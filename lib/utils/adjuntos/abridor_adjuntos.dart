import 'dart:typed_data';

/// Abre un adjunto FUERA del visor embebido (#234).
///
/// Es el punto de swap por plataforma: en Android/desktop los bytes se vuelcan
/// a un temporal y los abre la app del sistema; en web se abren en una PESTAÑA
/// nueva del navegador — el PO carga datos en una pestaña mientras mira el
/// remito o la factura en la otra. La implementación se elige por import
/// condicional en `fabrica_abridor_adjuntos.dart`, el mismo patrón que el OCR
/// (`fabrica_reconocedor.dart`): interfaz y fábrica en archivos separados para
/// que ninguna plataforma importe código de la otra.
///
/// Antes de #234 el camino io vivía dentro del visor y era el ÚNICO: en
/// Flutter Web "Abrir PDF" reventaba en runtime (dart:io + path_provider +
/// open_filex no existen allá) — justo donde prueba el PO.
abstract class AbridorAdjuntos {
  /// `true` cuando "abrir" significa pestaña nueva (web): la UI cambia el
  /// rótulo del botón de PDF y ofrece el botón también sobre las imágenes.
  bool get abreEnPestana;

  /// Abre los [bytes] fuera del visor. Lanza si el sistema no pudo (sin
  /// cliente para el tipo, pestaña bloqueada por el navegador, etc.).
  Future<void> abrir(
    Uint8List bytes, {
    required String mimeType,
    required String nombreArchivo,
  });
}

/// Nombre de archivo seguro para el sistema de archivos (sin caracteres
/// raros). Función PURA y pública para testearse sin plataforma; la usa la
/// implementación io al escribir el temporal.
String nombreSeguroDeArchivo(String nombre, {String porDefecto = 'adjunto'}) {
  final base = nombre.isNotEmpty ? nombre : porDefecto;
  return base.replaceAll(RegExp(r'[^\w.\-]'), '_');
}
