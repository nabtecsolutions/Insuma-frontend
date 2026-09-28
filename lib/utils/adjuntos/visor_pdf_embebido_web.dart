import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'visor_pdf_embebido.dart';

VisorPdfEmbebido crearVisorPdfEmbebido() => const _VisorPdfWeb();

/// Web: PDF embebido con el visor NATIVO del navegador (#258).
///
/// Los bytes viven en un Blob local (no hay URL remota): se fabrica una Object
/// URL y se la cuelga de un `<embed type="application/pdf">` montado como
/// `HtmlElementView`. Así el PO obtiene zoom, scroll, búsqueda e impresión —los
/// del visor de Chrome— sin sumar ninguna librería ni assets WASM, y sin tocar
/// la superficie de caché del service worker (el incidente #245). Es el mismo
/// Blob/Object URL que ya usa el abridor (#234) para la pestaña nueva; acá, en
/// vez de `window.open`, va adentro del `<embed>`.
class _VisorPdfWeb implements VisorPdfEmbebido {
  const _VisorPdfWeb();

  @override
  bool get puedeEmbeber => true;

  @override
  Widget construir(Uint8List bytes, {required String nombreArchivo}) =>
      // La `Key` por identidad de los bytes ata el ciclo de vida de la Object
      // URL a ESTE contenido: si el mismo lugar del árbol pasa a mostrar otro
      // PDF (p. ej. cambia la guía staged), la `Key` cambia, el State viejo se
      // desmonta (revoca su URL en `dispose`) y nace uno limpio para el nuevo.
      _PdfEmbebido(key: ValueKey(identityHashCode(bytes)), bytes: bytes);
}

/// Contador de vistas para dar un `viewType` único por instancia: el registro
/// de fábricas de `HtmlElementView` es global y por nombre, así que dos PDFs a
/// la vez (p. ej. dos páginas del paginador) no pueden compartirlo.
int _secuencia = 0;

/// `Stateful` porque la Object URL es un RECURSO con ciclo de vida: se crea al
/// montar y se REVOCA al desmontar. A diferencia del abridor (que revoca por un
/// Timer de 60 s porque entrega la URL a otra pestaña y se desentiende), acá el
/// `<embed>` la usa mientras el widget viva, y puede vivir mucho más que 60 s:
/// revocar por reloj rompería el visor. Se revoca en `dispose`, ni antes ni
/// después. El recambio de contenido lo maneja la `Key` (ver [_VisorPdfWeb]),
/// no un `didUpdateWidget`.
class _PdfEmbebido extends StatefulWidget {
  final Uint8List bytes;

  const _PdfEmbebido({required super.key, required this.bytes});

  @override
  State<_PdfEmbebido> createState() => _PdfEmbebidoState();
}

class _PdfEmbebidoState extends State<_PdfEmbebido> {
  late final String _viewType;
  late final String _url;

  @override
  void initState() {
    super.initState();
    final blob = web.Blob(
      [widget.bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'application/pdf'),
    );
    _url = web.URL.createObjectURL(blob);
    _viewType = 'pdf-embebido-${_secuencia++}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      // `createElement(...) as HTMLEmbedElement` es la forma con la garantía más
      // amplia entre versiones de `package:web` (el constructor directo puede no
      // instanciar según el codegen).
      final embed = web.document.createElement('embed') as web.HTMLEmbedElement;
      embed.type = 'application/pdf';
      embed.src = _url;
      embed.style.border = 'none';
      embed.style.width = '100%';
      embed.style.height = '100%';
      return embed;
    });
  }

  @override
  void dispose() {
    web.URL.revokeObjectURL(_url);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
