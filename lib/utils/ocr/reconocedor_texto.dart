import '../adjuntos/contenido_archivo.dart';

/// Seam del motor de reconocimiento de texto (HU-144).
///
/// La app depende SÓLO de esta interfaz; la implementación real (ML Kit,
/// on-device y costo $0) existe únicamente en Android/iOS. En web/desktop la
/// fábrica devuelve [ReconocedorTextoNoDisponible] y el flujo manual queda
/// idéntico (criterio de la HU: sin motor no cambia nada).
abstract class ReconocedorTexto {
  /// ¿Hay motor en esta plataforma? Si es false, la UI ni muestra el botón.
  bool get disponible;

  /// Texto reconocido de una IMAGEN (jpeg/png), o null si el motor no está
  /// disponible, el archivo no es imagen o el reconocimiento falló. Nunca lanza.
  Future<String?> reconocer(ContenidoArchivo archivo);
}

/// Null-object: plataforma sin motor (web/desktop) o motor deshabilitado.
class ReconocedorTextoNoDisponible implements ReconocedorTexto {
  const ReconocedorTextoNoDisponible();

  @override
  bool get disponible => false;

  @override
  Future<String?> reconocer(ContenidoArchivo archivo) async => null;
}
