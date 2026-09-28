import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../controllers/controlador_adjuntos.dart';
import '../../../../database/database.dart';
import '../../../../services/servicio_adjuntos.dart';
import '../../../../theme/insuma_colors.dart';
import '../../../../utils/adjuntos/fabrica_visor_pdf_embebido.dart';
import '../../widgets/doc_visualizable.dart';
import '../../widgets/visor_remito.dart';

/// #255/#258/#261: la guía de adjuntos para cargar los precios (Paso 2 de
/// Procesar recepción).
///
/// Muestra un FILMSTRIP con TODOS los adjuntos de la recepción — los ya
/// PERSISTIDOS (el remito/factura cargado al recibir, #261) y los recién
/// agregados en este wizard (STAGED, [ControladorAdjuntos.pendientes], bytes en
/// RAM) — y un panel grande del seleccionado. Tocarlo abre el visor a pantalla
/// completa con zoom ([PantallaVisorDocumentos], reusando la costura de #258:
/// imagen con InteractiveViewer, PDF con `<embed>` nativo en web).
///
/// Antes (#255) sólo miraba los staged; los persistidos —que son justo la guía
/// que el PO quiere ver para tipear— no aparecían. El gating por rol lo aplica
/// el Service (se le pasa [puedeVerFinanzas]); los bytes de los persistidos se
/// piden una sola vez (memoizados), los staged salen de RAM sin refetch.
class PreviewFacturaStaged extends StatefulWidget {
  final ControladorAdjuntos comprobantes;
  final String recepcionId;
  final String pedidoId;
  final String proveedorNombre;
  final bool puedeVerFinanzas;

  /// #258/#261: cómo se embebe un PDF en el panel/visor. Inyectable para tests
  /// (la rama web no corre en la VM); en la app la fábrica elige por plataforma.
  final VisorPdfEmbebido? visorPdf;

  const PreviewFacturaStaged({
    super.key,
    required this.comprobantes,
    required this.recepcionId,
    required this.pedidoId,
    required this.proveedorNombre,
    required this.puedeVerFinanzas,
    this.visorPdf,
  });

  @override
  State<PreviewFacturaStaged> createState() => _PreviewFacturaStagedState();
}

class _PreviewFacturaStagedState extends State<PreviewFacturaStaged> {
  late final ServicioAdjuntos _servicio;
  late final VisorPdfEmbebido _visor;

  /// Los adjuntos YA persistidos de la recepción, pedidos UNA sola vez. Memoizar
  /// es clave: `PasoDetalleItems` rebuildea por cada tecla al tipear precios, y
  /// sin esto se re-consultaría el listado y cada `obtenerContenido` por dígito.
  late final Future<List<Adjunto>> _existentesFuture;

  /// Bytes por documento, memoizados por su `clave` (persistido = una descarga;
  /// staged = inmediato desde RAM). Compartidos entre miniatura y panel.
  final Map<Key, Future<Uint8List>> _bytesCache = {};

  int _seleccion = 0;

  /// Cuántos persistidos hay (se sabe al resolver el future). Lo usa el
  /// auto-salto para ubicar el último staged, que va al final de la lista.
  int _existentesCount = 0;

  /// Cuántos staged había en la última pasada: si crecen, el PO acaba de sumar
  /// un adjunto y quiere verlo (es lo que va a mirar para tipear) → se
  /// selecciona solo.
  int _conteoStaged = 0;

  @override
  void initState() {
    super.initState();
    _servicio = context.read<ServicioAdjuntos>();
    _visor = widget.visorPdf ?? crearVisorPdfEmbebido();
    _conteoStaged = widget.comprobantes.pendientes.length;
    _existentesFuture = _servicio.listarAdjuntos(
      ContextoAdjuntos.documentosDeRecepcion,
      widget.recepcionId,
      puedeVerFinanzas: widget.puedeVerFinanzas,
    );
    widget.comprobantes.addListener(_alCambiarStaged);
  }

  @override
  void dispose() {
    widget.comprobantes.removeListener(_alCambiarStaged);
    super.dispose();
  }

  /// Al AGREGAR un staged, saltar a mostrarlo (los staged van al final). Quitar
  /// uno no mueve la selección: el clamp del build la mantiene en rango.
  void _alCambiarStaged() {
    final nuevo = widget.comprobantes.pendientes.length;
    if (nuevo > _conteoStaged && mounted) {
      setState(() => _seleccion = _existentesCount + nuevo - 1);
    }
    _conteoStaged = nuevo;
  }

  Future<Uint8List> _bytesDe(DocVisualizable d) =>
      _bytesCache.putIfAbsent(d.clave, () => d.bytes());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Adjunto>>(
      future: _existentesFuture,
      builder: (context, snap) {
        final existentes = [
          for (final a in snap.data ?? const <Adjunto>[])
            DocAdjunto(a, _servicio),
        ];
        // Lo consume el auto-salto (_alCambiarStaged) para ubicar el último
        // staged; asignarlo acá no dispara rebuild.
        _existentesCount = existentes.length;
        // Escucha a `comprobantes`: agregar/quitar un staged re-arma la lista
        // (los existentes memoizados no se re-consultan).
        return ListenableBuilder(
          listenable: widget.comprobantes,
          builder: (context, _) {
            final staged = [
              for (final c in widget.comprobantes.pendientes) DocStaged(c),
            ];
            // Existentes primero (la guía que se mira para tipear), staged al
            // final (marcados "Nuevo").
            final docs = <DocVisualizable>[...existentes, ...staged];
            final seleccion = docs.isEmpty
                ? 0
                : _seleccion.clamp(0, docs.length - 1);
            return _contenido(docs, seleccion);
          },
        );
      },
    );
  }

  Widget _contenido(List<DocVisualizable> docs, int seleccion) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (docs.isNotEmpty) _panel(docs, seleccion),
        // SIEMPRE presente: acceso a TODOS los adjuntos del pedido (todas las
        // recepciones), como fallback y para el pedido completo.
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PantallaVisorRemito.deAdjuntosDePedido(
                  pedidoId: widget.pedidoId,
                  puedeVerFinanzas: widget.puedeVerFinanzas,
                  titulo: 'Adjuntos · ${widget.proveedorNombre}',
                ),
              ),
            ),
            icon: const Icon(Icons.collections_outlined, size: 16),
            label: const Text(
              'Ver todos los adjuntos del pedido',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
        const Divider(height: 16),
      ],
    );
  }

  Widget _panel(List<DocVisualizable> docs, int seleccion) {
    return Card(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: InsumaColors.cardBorderLight),
      ),
      child: ExpansionTile(
        initiallyExpanded: true,
        shape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        leading: const Icon(
          Icons.receipt_long_outlined,
          size: 20,
          color: Colors.black54,
        ),
        title: Text(
          docs.length > 1
              ? 'Factura (guía) · ${docs.length}'
              : 'Factura (guía)',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        trailing: IconButton(
          key: const ValueKey('ampliar_guia'),
          tooltip: 'Ampliar',
          icon: const Icon(Icons.open_in_full, size: 20, color: Colors.black54),
          onPressed: () => _ampliar(docs, seleccion),
        ),
        children: [
          if (docs.length > 1) _filmstrip(docs, seleccion),
          const SizedBox(height: 8),
          _panePrincipal(docs, seleccion),
        ],
      ),
    );
  }

  /// Tira de miniaturas: imágenes con thumbnail downscaleado, PDF como ícono.
  Widget _filmstrip(List<DocVisualizable> docs, int seleccion) {
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: docs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => _miniatura(docs[i], i, i == seleccion),
      ),
    );
  }

  Widget _miniatura(DocVisualizable doc, int i, bool activa) {
    final esImagen = doc.mimeType.startsWith('image/');
    return InkWell(
      key: ValueKey('miniatura_$i'),
      onTap: () => setState(() => _seleccion = i),
      child: Stack(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: activa
                    ? InsumaColors.primaryBlue
                    : InsumaColors.cardBorderLight,
                width: activa ? 2 : 1,
              ),
              color: Colors.grey.shade100,
            ),
            clipBehavior: Clip.antiAlias,
            child: esImagen
                ? FutureBuilder<Uint8List>(
                    future: _bytesDe(doc),
                    builder: (context, s) => s.data == null
                        ? const Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Image.memory(
                            s.data!,
                            cacheWidth: 128,
                            fit: BoxFit.cover,
                          ),
                  )
                : const Icon(
                    Icons.picture_as_pdf,
                    color: Colors.redAccent,
                    size: 28,
                  ),
          ),
          if (doc.esStaged)
            Positioned(
              top: 2,
              left: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: InsumaColors.primaryBlue,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'Nuevo',
                  style: TextStyle(color: Colors.white, fontSize: 9),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Panel del documento seleccionado, más grande que el preview viejo (220 →
  /// ~300), que encoge con el teclado abierto para no tapar el campo activo.
  Widget _panePrincipal(List<DocVisualizable> docs, int seleccion) {
    final sel = docs[seleccion];
    final altoPantalla = MediaQuery.sizeOf(context).height;
    final tecladoAbierto = MediaQuery.viewInsetsOf(context).bottom > 0;
    final maxAlto = tecladoAbierto
        ? 160.0
        : math.min(300.0, altoPantalla * 0.4);
    final esImagen = sel.mimeType.startsWith('image/');
    final esPdf = sel.mimeType == 'application/pdf';

    Widget cuerpo;
    if (esImagen) {
      cuerpo = FutureBuilder<Uint8List>(
        future: _bytesDe(sel),
        builder: (context, s) => s.data == null
            ? const Center(child: CircularProgressIndicator())
            : Image.memory(s.data!, fit: BoxFit.contain),
      );
    } else if (esPdf && _visor.puedeEmbeber) {
      cuerpo = FutureBuilder<Uint8List>(
        future: _bytesDe(sel),
        builder: (context, s) => s.data == null
            ? const Center(child: CircularProgressIndicator())
            : _visor.construir(s.data!, nombreArchivo: sel.nombreArchivo),
      );
    } else {
      // PDF en io (sin embebido) u otro tipo: no se dibuja acá; se ve con
      // "Ampliar" (que cae al placeholder "abrir afuera" de #258).
      cuerpo = _placeholderPdf(docs, seleccion);
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxAlto),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        // El `<embed>` del PDF se come los toques; para imágenes el tap-para-
        // ampliar va en un botón aparte (abajo) para no depender de eso.
        child: esImagen
            ? InkWell(
                key: const ValueKey('ampliar_pane'),
                onTap: () => _ampliar(docs, seleccion),
                child: cuerpo,
              )
            : cuerpo,
      ),
    );
  }

  Widget _placeholderPdf(List<DocVisualizable> docs, int seleccion) =>
      Container(
        height: 120,
        alignment: Alignment.center,
        color: Colors.grey.shade100,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.picture_as_pdf, size: 40, color: Colors.redAccent),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => _ampliar(docs, seleccion),
              icon: const Icon(Icons.open_in_full, size: 16),
              label: const Text('Ver PDF', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );

  /// Única ruta al visor grande: recibe la lista ya construida por el build (sin
  /// re-derivar nada async) y arranca en el documento seleccionado.
  void _ampliar(List<DocVisualizable> docs, int seleccion) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PantallaVisorDocumentos(
          docs: docs,
          indiceInicial: seleccion,
          titulo: 'Adjuntos · ${widget.proveedorNombre}',
          visorPdf: widget.visorPdf,
        ),
      ),
    );
  }
}
