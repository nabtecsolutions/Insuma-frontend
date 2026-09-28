import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../../database/database.dart';
import '../../../services/servicio_adjuntos.dart';
import '../../../utils/adjuntos/contenido_archivo.dart';

/// Un documento que el visor sabe mostrar, venga de donde venga (#261).
///
/// El visor (`PantallaVisorRemito`/`_VisorAdjunto`) nació atado a [Adjunto] +
/// `ServicioAdjuntos.obtenerContenido` (todo por id, desde la base). Pero la
/// guía del Paso 2 necesita mostrar en la MISMA vista los adjuntos ya
/// persistidos de la recepción Y los recién adjuntados (staged, [ContenidoArchivo]
/// con bytes en RAM, sin id todavía). Esta abstracción es la costura: el visor
/// consume `DocVisualizable` y no le importa el origen; cada fuente trae su
/// propia forma de resolver los bytes y su `clave` de identidad.
abstract class DocVisualizable {
  /// Los bytes del documento. El visor lo llama UNA vez por documento (memoiza
  /// por [clave]); para un persistido es una descarga, para un staged es
  /// inmediato (ya está en RAM).
  Future<Uint8List> bytes();

  /// MIME normalizado ('image/...', 'application/pdf'): decide imagen vs PDF.
  String get mimeType;

  /// Nombre para el título/descarga y "abrir afuera".
  String get nombreArchivo;

  /// Identidad estable para la `Key` del paginador (que ata el State y los
  /// recursos —future memoizado, Object URL del PDF— a ESTE documento).
  Key get clave;

  /// `true` si es un adjunto recién agregado (aún no persistido): la UI lo
  /// marca como "Nuevo" en el filmstrip.
  bool get esStaged;
}

/// Documento respaldado por un [Adjunto] ya persistido: los bytes se traen del
/// servicio por id.
class DocAdjunto implements DocVisualizable {
  final Adjunto adjunto;
  final ServicioAdjuntos servicio;

  const DocAdjunto(this.adjunto, this.servicio);

  @override
  Future<Uint8List> bytes() => servicio.obtenerContenido(adjunto.id);

  @override
  String get mimeType => adjunto.mimeType;

  @override
  String get nombreArchivo => adjunto.nombreArchivo;

  @override
  Key get clave => ValueKey('adj_${adjunto.id}');

  @override
  bool get esStaged => false;
}

/// Documento respaldado por un [ContenidoArchivo] STAGED: los bytes ya están en
/// RAM (sin refetch). La `clave` es por IDENTIDAD de instancia —no por índice—
/// para que sacar un staged no desalinee las keys del resto (mismo idioma que
/// `persistirEn`, que casa por `identical`).
class DocStaged implements DocVisualizable {
  final ContenidoArchivo contenido;

  const DocStaged(this.contenido);

  @override
  Future<Uint8List> bytes() async => contenido.bytes;

  @override
  String get mimeType => contenido.mimeType;

  @override
  String get nombreArchivo => contenido.nombreArchivo;

  @override
  Key get clave => ObjectKey(contenido);

  @override
  bool get esStaged => true;
}
