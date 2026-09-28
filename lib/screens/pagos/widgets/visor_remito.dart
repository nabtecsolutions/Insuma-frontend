import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../database/database.dart';
import '../../../services/servicio_adjuntos.dart';
import '../../../utils/adjuntos/fabrica_abridor_adjuntos.dart';
import '../../../utils/adjuntos/fabrica_visor_pdf_embebido.dart';
import 'doc_visualizable.dart';

/// Visor a pantalla completa de los remitos adjuntos a una recepción (HU-067).
///
/// Reutiliza el manejo de adjuntos de HU-066: lista los [Adjunto] de la recepción y
/// trae sus bytes con [ServicioAdjuntos.obtenerContenido]. NO accede a la base ni
/// (de)codifica bytes: sólo presenta lo que el servicio entrega. Si la recepción
/// tiene varios remitos, se recorren con un [PageView].
///
/// Las imágenes (JPG/PNG) se muestran embebidas con zoom. Abrir FUERA del visor
/// lo resuelve [AbridorAdjuntos] (#234): en Android/desktop, el visor del
/// sistema (PDF sin render embebido); en web, una PESTAÑA nueva — y ahí el
/// botón se ofrece también sobre las imágenes, para mirar el remito en una
/// pestaña mientras se cargan datos en la otra.
class PantallaVisorRemito extends StatelessWidget {
  /// Recepción puntual cuyos remitos se muestran (desde Pagos). Excluyente con [pedidoId].
  final String? recepcionId;

  /// Pedido cuyos adjuntos (de TODAS sus recepciones) se muestran (historial).
  final String? pedidoId;

  /// #234: qué ve la variante de pedido. Con permiso de finanzas, los tres
  /// grupos (remitos + facturas + comprobantes); sin él, solo remitos. La
  /// decisión la aplica el SERVICE — acá solo se transporta el bool, que debe
  /// salir SIEMPRE de `Permisos`/sesión (nunca hardcodeado en la pantalla).
  final bool puedeVerFinanzas;

  /// Título para el AppBar (p. ej. "Remito · Proveedor").
  final String? titulo;

  /// Sustantivo para los textos (empty/título): 'remito' o 'comprobante'.
  final String sustantivo;

  /// #234: cómo se abre un adjunto FUERA del visor. Inyectable para los tests
  /// (la rama web no corre en la VM); en la app queda null y la fábrica elige
  /// por plataforma en `build`.
  final AbridorAdjuntos? abridor;

  /// #258: cómo se embebe un PDF DENTRO del visor. Mismo patrón que [abridor]:
  /// inyectable para los tests (la rama web no corre en la VM); en la app queda
  /// null y la fábrica elige por plataforma en `build` (web embebe, io no).
  final VisorPdfEmbebido? visorPdf;

  /// Visor de los remitos de una recepción puntual (Pagos).
  const PantallaVisorRemito.deRecepcion({
    super.key,
    required String this.recepcionId,
    this.titulo,
    this.abridor,
    this.visorPdf,
  }) : pedidoId = null,
       documentosDeRecepcionId = null,
       respaldoDeRecepcionId = null,
       comprobantesDePagoId = null,
       puedeVerFinanzas = false,
       sustantivo = 'remito';

  /// Visor de TODOS los adjuntos de un pedido (Historial, #234): los remitos
  /// de cada entrega y —solo con [puedeVerFinanzas]— sus facturas y
  /// comprobantes de pago. Reemplaza a la vieja `.dePedido` (solo remitos),
  /// cuyo único consumidor era el historial.
  const PantallaVisorRemito.deAdjuntosDePedido({
    super.key,
    required String this.pedidoId,
    required this.puedeVerFinanzas,
    this.titulo,
    this.abridor,
    this.visorPdf,
  }) : recepcionId = null,
       documentosDeRecepcionId = null,
       respaldoDeRecepcionId = null,
       comprobantesDePagoId = null,
       // Para el cocinero la vista ES la de remitos: sus textos lo dicen.
       sustantivo = puedeVerFinanzas ? 'adjunto' : 'remito';

  // #244: las variantes `.deComprobante` (HU-069) y `.deFactura` (HU-148)
  // se PODARON — quedaron sin un solo caller cuando `.deDocumentos` (#209) y
  // `.deRespaldoFactura` (#238) las absorbieron, y una variante muerta es una
  // política de adjuntos que nadie mantiene.

  /// Recepción cuyos documentos TODOS —remitos y facturas— se muestran (#209).
  final String? documentosDeRecepcionId;

  /// Recepción cuyos respaldos FINANCIEROS —facturas y comprobantes— se
  /// muestran juntos (#238).
  final String? respaldoDeRecepcionId;

  /// Visor del respaldo financiero de una factura (#238): la factura del
  /// proveedor y, si hubo, los comprobantes de pago de esa recepción.
  ///
  /// Séptima variante del MISMO visor. Existe porque las filas históricas del
  /// wizard quedaron como 'comprobante' y las nuevas van como 'factura': la
  /// cuenta corriente necesita UN botón que muestre los dos mundos.
  const PantallaVisorRemito.deRespaldoFactura({
    super.key,
    required String this.respaldoDeRecepcionId,
    this.titulo,
    this.abridor,
    this.visorPdf,
  }) : recepcionId = null,
       pedidoId = null,
       documentosDeRecepcionId = null,
       comprobantesDePagoId = null,
       puedeVerFinanzas = false,
       sustantivo = 'documento';

  /// Pago cuyos COMPROBANTES de transferencia se muestran (#238).
  final String? comprobantesDePagoId;

  /// Visor de los comprobantes colgados de un PAGO (#238): la prueba de la
  /// transferencia, adjuntada en "Registrar pago". Octava variante del MISMO
  /// visor.
  const PantallaVisorRemito.deComprobanteDePago({
    super.key,
    required String this.comprobantesDePagoId,
    this.titulo,
    this.abridor,
    this.visorPdf,
  }) : recepcionId = null,
       pedidoId = null,
       documentosDeRecepcionId = null,
       respaldoDeRecepcionId = null,
       puedeVerFinanzas = false,
       sustantivo = 'comprobante';

  /// Visor de todos los papeles que respaldan una recepción (#209).
  ///
  /// Quinta variante del MISMO visor. Existe porque al procesar una recepción
  /// hay que cotejar las dos cosas a la vez: qué llegó (remito) contra qué te
  /// cobran (factura). Tenerlas en dos botones separados obligaba a entrar y
  /// salir dos veces del mismo modal.
  const PantallaVisorRemito.deDocumentos({
    super.key,
    required String this.documentosDeRecepcionId,
    this.titulo,
    this.abridor,
    this.visorPdf,
  }) : recepcionId = null,
       pedidoId = null,
       respaldoDeRecepcionId = null,
       comprobantesDePagoId = null,
       puedeVerFinanzas = false,
       sustantivo = 'documento';

  Future<List<Adjunto>> _cargar(ServicioAdjuntos servicio) {
    if (comprobantesDePagoId != null) {
      return servicio.listarComprobantesDePago(comprobantesDePagoId!);
    }
    if (respaldoDeRecepcionId != null) {
      return servicio.listarRespaldosFinancieros(respaldoDeRecepcionId!);
    }
    if (documentosDeRecepcionId != null) {
      return servicio.listarDocumentos(documentosDeRecepcionId!);
    }
    if (recepcionId != null) return servicio.listarPorRecepcion(recepcionId!);
    return servicio.listarAdjuntosDePedido(
      pedidoId!,
      puedeVerFinanzas: puedeVerFinanzas,
    );
  }

  @override
  Widget build(BuildContext context) {
    final servicio = context.read<ServicioAdjuntos>();
    final abridorEfectivo = abridor ?? crearAbridorAdjuntos();
    final visorPdfEfectivo = visorPdf ?? crearVisorPdfEmbebido();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          titulo ?? (sustantivo == 'comprobante' ? 'Comprobante' : 'Remito'),
        ),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: FutureBuilder<List<Adjunto>>(
        future: _cargar(servicio),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final adjuntos = snap.data ?? const <Adjunto>[];
          if (adjuntos.isEmpty) {
            return _MensajeCentrado(
              icono: Icons.receipt_long_outlined,
              texto: 'No hay $sustantivo adjunto.',
            );
          }
          return _Paginador(
            docs: [for (final a in adjuntos) DocAdjunto(a, servicio)],
            abridor: abridorEfectivo,
            visorPdf: visorPdfEfectivo,
          );
        },
      ),
    );
  }
}

/// Visor a pantalla completa de una LISTA de documentos ya resuelta (#261).
///
/// Hermano de [PantallaVisorRemito]: comparte el mismo paginador con zoom, pero
/// en vez de cargar adjuntos por id desde el servicio, recibe una lista de
/// [DocVisualizable] YA armada — así puede mostrar juntos los adjuntos
/// PERSISTIDOS de la recepción y los STAGED (que no tienen id ni están en la
/// base). Lo usa el filmstrip de la guía del Paso 2 para "ampliar" con zoom.
class PantallaVisorDocumentos extends StatelessWidget {
  final List<DocVisualizable> docs;
  final int indiceInicial;
  final String? titulo;
  final AbridorAdjuntos? abridor;
  final VisorPdfEmbebido? visorPdf;

  const PantallaVisorDocumentos({
    super.key,
    required this.docs,
    this.indiceInicial = 0,
    this.titulo,
    this.abridor,
    this.visorPdf,
  });

  @override
  Widget build(BuildContext context) {
    final abridorEfectivo = abridor ?? crearAbridorAdjuntos();
    final visorPdfEfectivo = visorPdf ?? crearVisorPdfEmbebido();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(titulo ?? 'Adjuntos'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: docs.isEmpty
          ? const _MensajeCentrado(
              icono: Icons.receipt_long_outlined,
              texto: 'No hay adjuntos.',
            )
          : _Paginador(
              docs: docs,
              abridor: abridorEfectivo,
              visorPdf: visorPdfEfectivo,
              indiceInicial: indiceInicial,
            ),
    );
  }
}

/// Muestra un único adjunto: imagen embebida con zoom, PDF embebido (web, #258)
/// o placeholder con "abrir afuera" cuando no se puede embeber.
class _VisorAdjunto extends StatefulWidget {
  final DocVisualizable doc;
  final AbridorAdjuntos abridor;
  final VisorPdfEmbebido visorPdf;
  final int indice;
  final int total;

  const _VisorAdjunto({
    super.key,
    required this.doc,
    required this.abridor,
    required this.visorPdf,
    required this.indice,
    required this.total,
  });

  @override
  State<_VisorAdjunto> createState() => _VisorAdjuntoState();
}

class _VisorAdjuntoState extends State<_VisorAdjunto> {
  /// Los bytes se piden UNA sola vez y se comparten entre el render (imagen o
  /// PDF embebido) y "abrir afuera" (#258). Antes se pedía el contenido dos
  /// veces —el FutureBuilder de la imagen y `_abrirExterno`—: con un PDF de
  /// hasta 5 MB eso eran dos descargas completas del mismo adjunto. La `clave`
  /// del documento (por id o por instancia) garantiza un State —y por ende un
  /// future— por documento. Para un staged, `bytes()` resuelve inmediato (RAM).
  late final Future<Uint8List> _contenido = widget.doc.bytes();

  bool get _esImagen => widget.doc.mimeType.startsWith('image/');
  bool get _esPdf => widget.doc.mimeType == 'application/pdf';

  /// #258: el PDF se embebe cuando es PDF y la plataforma sabe hacerlo (web sí,
  /// io no). Si no, cae al placeholder con "abrir afuera" de siempre.
  bool get _pdfEmbebible => _esPdf && widget.visorPdf.puedeEmbeber;

  /// Abre el adjunto FUERA del visor vía [AbridorAdjuntos] (#234): visor del
  /// sistema en io, pestaña nueva en web. Reusa los bytes ya pedidos; el
  /// try/catch y el aviso quedan acá, que es donde hay context.
  Future<void> _abrirExterno(BuildContext context) async {
    try {
      final bytes = await _contenido;
      await widget.abridor.abrir(
        bytes,
        mimeType: widget.doc.mimeType,
        nombreArchivo: widget.doc.nombreArchivo,
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo abrir el adjunto.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // PDF/otro que no se puede embeber (io, o un tipo que el navegador no
    // muestra): placeholder + "abrir afuera". No hace falta traer los bytes
    // para esto — se piden recién al tocar el botón.
    if (!_esImagen && !_pdfEmbebible) return _placeholderAbrir(context);

    // Imagen o PDF embebido: ambos necesitan los bytes.
    return FutureBuilder<Uint8List>(
      future: _contenido,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError || snap.data == null) {
          return const _MensajeCentrado(
            icono: Icons.broken_image_outlined,
            texto: 'No se pudo cargar el adjunto.',
          );
        }
        return _esImagen
            ? _vistaImagen(context, snap.data!)
            : _vistaPdfEmbebido(context, snap.data!);
      },
    );
  }

  /// Imagen con zoom. Los controles Flutter van SUPERPUESTOS: acá no hay
  /// elemento DOM que capture los toques (a diferencia del PDF embebido).
  Widget _vistaImagen(BuildContext context, Uint8List bytes) {
    return Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
          ),
        ),
        // #234: SOLO en web — en el teléfono la imagen ya se ve acá mismo con
        // zoom y "abrir afuera" no aporta nada. En web permite tener el remito
        // en una pestaña mientras se cargan datos en la otra.
        if (widget.abridor.abreEnPestana)
          Positioned(
            top: 8,
            right: 8,
            child: Material(
              color: Colors.black.withValues(alpha: 0.45),
              shape: const CircleBorder(),
              child: IconButton(
                key: const ValueKey('abrir_pestana'),
                tooltip: 'Abrir en pestaña nueva',
                onPressed: () => _abrirExterno(context),
                icon: const Icon(Icons.open_in_new, size: 22),
                color: Colors.white,
              ),
            ),
          ),
        if (widget.total > 1) _contadorInferior(),
      ],
    );
  }

  /// PDF embebido (web, #258). El `<embed>` es un elemento DOM que CAPTURA los
  /// toques en su rectángulo, así que NINGÚN control Flutter se le superpone:
  /// la acción "abrir en pestaña" y el contador viven en una barra ARRIBA del
  /// embed, y el embed se achica a los lados (`_gutter`) para dejarle a las
  /// flechas del paginador un pasillo Flutter donde sí reciben el toque.
  Widget _vistaPdfEmbebido(BuildContext context, Uint8List bytes) {
    final gutter = widget.total > 1 ? 56.0 : 0.0;
    return Column(
      children: [
        _barraPdf(context),
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: widget.visorPdf.construir(
              bytes,
              nombreArchivo: widget.doc.nombreArchivo,
            ),
          ),
        ),
      ],
    );
  }

  /// Barra Flutter (fuera del rectángulo del embed) con el contador y —en web—
  /// el acceso a "abrir en pestaña nueva".
  Widget _barraPdf(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          if (widget.total > 1)
            Text(
              'Adjunto ${widget.indice + 1} de ${widget.total}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          // `Expanded` + `Align` en vez de `Spacer` + botón: así el botón se
          // alinea a la derecha y, sólo si el ancho del teléfono no le alcanza,
          // el label recorta (ellipsis) en lugar de desbordar la barra.
          if (widget.abridor.abreEnPestana)
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const ValueKey('abrir_pestana'),
                  onPressed: () => _abrirExterno(context),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text(
                    'Abrir en pestaña nueva',
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _contadorInferior() => Positioned(
    bottom: 16,
    left: 0,
    right: 0,
    child: Center(
      child: Text(
        'Adjunto ${widget.indice + 1} de ${widget.total}',
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    ),
  );

  /// PDF/otro sin embebido posible: ícono + nombre + "abrir afuera" (io, o tipos
  /// que el navegador no muestra).
  Widget _placeholderAbrir(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.picture_as_pdf, size: 64, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(
              widget.doc.nombreArchivo,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => _abrirExterno(context),
              icon: const Icon(Icons.open_in_new, size: 18),
              // #234: en web el rótulo dice a dónde va de verdad — y de paso
              // este camino FUNCIONA allá (el viejo, dart:io, reventaba).
              label: Text(
                widget.abridor.abreEnPestana
                    ? 'Abrir en pestaña nueva'
                    : 'Abrir PDF',
              ),
            ),
            if (widget.total > 1) ...[
              const SizedBox(height: 12),
              Text(
                'Adjunto ${widget.indice + 1} de ${widget.total}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Mensaje centrado (vacío/error/placeholder) sobre el fondo oscuro del visor.
class _MensajeCentrado extends StatelessWidget {
  final IconData icono;
  final String texto;

  const _MensajeCentrado({required this.icono, required this.texto});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icono, size: 64, color: Colors.white54),
            const SizedBox(height: 16),
            Text(
              texto,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

/// El `PageView` de los adjuntos, con sus flechas (#208).
///
/// **Las flechas no son decoración: sin ellas el visor es inalcanzable con
/// mouse.** El `ScrollBehavior` por defecto de Flutter no incluye
/// `PointerDeviceKind.mouse` en `dragDevices`, así que en Flutter Web el
/// `PageView` no responde al arrastre. En Android, con el dedo, siempre anduvo.
/// Por eso el visor mostraba "Adjunto 1 de 3" y no había ninguna forma de
/// llegar al 2 ni al 3.
///
/// Se eligió agregar controles y NO un `ScrollBehavior` global que habilite el
/// arrastre con mouse: aquello es invisible —nada indica que se pueda
/// arrastrar— y cambiaría el scroll de toda la app, no sólo de este visor.
///
/// Es `Stateful` porque hacen falta el `PageController` y el índice actual para
/// poder deshabilitar cada flecha en su extremo. Una flecha que no lleva a
/// ningún lado y no lo dice es peor que no tenerla.
class _Paginador extends StatefulWidget {
  final List<DocVisualizable> docs;
  final AbridorAdjuntos abridor;
  final VisorPdfEmbebido visorPdf;
  final int indiceInicial;

  const _Paginador({
    required this.docs,
    required this.abridor,
    required this.visorPdf,
    this.indiceInicial = 0,
  });

  @override
  State<_Paginador> createState() => _PaginadorState();
}

class _PaginadorState extends State<_Paginador> {
  late final PageController _controlador;
  late int _indice;

  @override
  void initState() {
    super.initState();
    // #261: arranca en el documento pedido (p. ej. la miniatura que se tocó en
    // el filmstrip). El clamp protege un índice fuera de rango.
    _indice = widget.indiceInicial.clamp(0, widget.docs.length - 1);
    _controlador = PageController(initialPage: _indice);
  }

  @override
  void dispose() {
    _controlador.dispose();
    super.dispose();
  }

  void _ir(int destino) {
    // El clamp es defensivo: las flechas ya vienen deshabilitadas en los
    // extremos, pero `animateToPage` fuera de rango deja el controlador en un
    // estado del que no vuelve.
    final i = destino.clamp(0, widget.docs.length - 1);
    if (i == _indice) return;
    _controlador.animateToPage(
      i,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.docs.length;
    return Stack(
      children: [
        PageView.builder(
          controller: _controlador,
          itemCount: total,
          onPageChanged: (i) => setState(() => _indice = i),
          itemBuilder: (context, i) => _VisorAdjunto(
            // La `clave` del documento (por id o por instancia) ata el estado
            // (future memoizado, Object URL del PDF) a ESTE documento: si el
            // paginador reordena o reusa la posición, no se cruzan los recursos.
            key: widget.docs[i].clave,
            doc: widget.docs[i],
            abridor: widget.abridor,
            visorPdf: widget.visorPdf,
            indice: i,
            total: total,
          ),
        ),
        // Con un solo adjunto no hay a dónde ir: el contador ya se oculta por
        // la misma razón.
        if (total > 1) ...[
          _Flecha(
            clave: const ValueKey('flecha_anterior'),
            icono: Icons.chevron_left,
            alineacion: Alignment.centerLeft,
            etiqueta: 'Adjunto anterior',
            alTocar: _indice == 0 ? null : () => _ir(_indice - 1),
          ),
          _Flecha(
            clave: const ValueKey('flecha_siguiente'),
            icono: Icons.chevron_right,
            alineacion: Alignment.centerRight,
            etiqueta: 'Adjunto siguiente',
            alTocar: _indice == total - 1 ? null : () => _ir(_indice + 1),
          ),
        ],
      ],
    );
  }
}

/// Flecha de navegación sobre el visor.
///
/// Va sobre un fondo negro con la imagen abajo, así que lleva su propio disco
/// semitransparente: un ícono suelto se pierde sobre una foto de remito clara.
class _Flecha extends StatelessWidget {
  final Key clave;
  final IconData icono;
  final Alignment alineacion;
  final String etiqueta;
  final VoidCallback? alTocar;

  const _Flecha({
    required this.clave,
    required this.icono,
    required this.alineacion,
    required this.etiqueta,
    required this.alTocar,
  });

  @override
  Widget build(BuildContext context) {
    final habilitada = alTocar != null;
    return Align(
      alignment: alineacion,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Material(
          color: Colors.black.withValues(alpha: habilitada ? 0.45 : 0.15),
          shape: const CircleBorder(),
          child: IconButton(
            key: clave,
            onPressed: alTocar,
            tooltip: etiqueta,
            icon: Icon(icono, size: 32),
            color: Colors.white,
            disabledColor: Colors.white24,
          ),
        ),
      ),
    );
  }
}
