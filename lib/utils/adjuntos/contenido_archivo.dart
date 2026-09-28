import 'dart:typed_data';

/// Tipos MIME de remito aceptados (HU-066). El remito de una recepción puede ser
/// un PDF o una foto (JPG/PNG) del comprobante de entrega.
const Set<String> kTiposRemitoPermitidos = {
  'application/pdf',
  'image/jpeg',
  'image/png',
};

/// Tope DURO de tamaño del archivo aceptado (5 MB). Por encima se rechaza: evita
/// inflar el payload del Outbox (los bytes viajan como base64, +33%) y la fila remota.
const int kMaxBytesRemito = 5 * 1024 * 1024;

/// Tamaño OBJETIVO al comprimir imágenes (~1.5 MB). No aplica a PDF.
const int kObjetivoBytesImagen = 1536 * 1024;

/// Value object inmutable que representa un archivo capturado EN MEMORIA, antes de
/// persistirlo. Viaja entre capas (selector → service → backend) sin exponer detalles
/// del plugin de captura ni de la base de datos. No conoce ni base64 ni Drift: esas
/// responsabilidades viven en clases propias (CodificadorAdjuntos / RepositorioAdjuntos).
class ContenidoArchivo {
  /// Bytes crudos del archivo.
  final Uint8List bytes;

  /// Nombre original del archivo (ej.: "remito_123.pdf").
  final String nombreArchivo;

  /// Tipo MIME normalizado (ver [kTiposRemitoPermitidos]).
  final String mimeType;

  const ContenidoArchivo({
    required this.bytes,
    required this.nombreArchivo,
    required this.mimeType,
  });

  int get tamanioBytes => bytes.length;
  bool get esImagen => mimeType == 'image/jpeg' || mimeType == 'image/png';
  bool get esPdf => mimeType == 'application/pdf';

  ContenidoArchivo copyWith({
    Uint8List? bytes,
    String? nombreArchivo,
    String? mimeType,
  }) => ContenidoArchivo(
    bytes: bytes ?? this.bytes,
    nombreArchivo: nombreArchivo ?? this.nombreArchivo,
    mimeType: mimeType ?? this.mimeType,
  );
}
