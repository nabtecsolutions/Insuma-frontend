import 'dart:convert';
import 'dart:typed_data';

/// Contrato de (de)codificación de los bytes de un adjunto (HU-066).
///
/// El payload del Outbox es JSON (texto) y JSON no puede transportar bytes crudos,
/// por lo que los bytes viajan como base64. Aislar esto detrás de una interfaz
/// mantiene el encode/decode FUERA de controladores y vistas: solo el repositorio
/// (al armar el payload de sincronización) y el pull de sync deben usarlo.
abstract class CodificadorAdjuntos {
  /// Bytes → texto transportable por el Outbox (JSON) y almacenable como `text` remoto.
  String codificar(Uint8List bytes);

  /// Texto (base64) → bytes, al recibir una fila remota en el pull de sync.
  Uint8List decodificar(String texto);
}

/// Implementación base64 estándar (sin estado; reutilizable como `const`).
class CodificadorAdjuntosBase64 implements CodificadorAdjuntos {
  const CodificadorAdjuntosBase64();

  @override
  String codificar(Uint8List bytes) => base64Encode(bytes);

  @override
  Uint8List decodificar(String texto) => base64Decode(texto);
}
