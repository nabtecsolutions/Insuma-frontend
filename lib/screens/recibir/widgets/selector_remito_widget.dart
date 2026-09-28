import 'package:flutter/material.dart';

import '../../../controllers/controlador_adjuntos.dart';
import '../../../utils/adjuntos/contenido_archivo.dart';

/// Widget reutilizable para adjuntar y previsualizar los remitos de una recepción
/// (HU-066). Es SOLO presentación: delega toda la lógica en [ControladorAdjuntos]
/// (captura, validación y persistencia). No accede a la base de datos ni codifica
/// bytes; para mostrar la miniatura usa los bytes en memoria del archivo elegido.
///
/// Lo consume la pantalla de recepción (HU-064), que además aplica la regla
/// "hace falta un comprobante cuando entró mercadería" — obligatoria otra vez
/// desde #226, después de que #212 la relajara.
class SelectorRemitoWidget extends StatelessWidget {
  final ControladorAdjuntos controlador;

  /// Título de la sección y texto cuando no hay archivos. Parametrizables para
  /// reutilizar el widget con comprobantes de pago (HU-069), no sólo remitos.
  final String titulo;
  final String textoVacio;

  const SelectorRemitoWidget({
    super.key,
    required this.controlador,
    this.titulo = 'Remitos',
    this.textoVacio = 'Sin remitos adjuntos.',
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controlador,
      builder: (context, _) {
        final pendientes = controlador.pendientes;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.receipt_long, size: 18),
                const SizedBox(width: 6),
                // #209: el título cede espacio con elipsis en vez de empujar el
                // botón fuera de la pantalla. Medido con un widget test que abre
                // el modal de procesar recepción a 360 dp: desbordaba 282 px, y
                // lo recortado era "Adjuntar" — la única acción del widget.
                //
                // Va `Expanded` y NO `Wrap` como en #180 y #204: esto no es una
                // botonera de acciones equivalentes sino un encabezado de
                // "título + acción". Bajar el botón de renglón lo separaría de
                // su título; recortar el título con "…" no pierde nada, porque
                // el contexto del modal ya dice de qué se trata.
                //
                // El `Spacer` se va: `Expanded` ya empuja el botón a la derecha.
                Expanded(
                  child: Text(
                    titulo,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.attach_file, size: 16),
                  label: const Text('Adjuntar'),
                  onPressed: controlador.agregarDesdeSelector,
                ),
              ],
            ),
            if (controlador.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  controlador.error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
            if (pendientes.isEmpty)
              Text(
                textoVacio,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (int i = 0; i < pendientes.length; i++)
                    _TarjetaRemito(
                      contenido: pendientes[i],
                      onQuitar: () => controlador.quitar(i),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// Miniatura de un remito staged: thumbnail si es imagen, ícono+nombre si es PDF.
class _TarjetaRemito extends StatelessWidget {
  final ContenidoArchivo contenido;
  final VoidCallback onQuitar;

  const _TarjetaRemito({required this.contenido, required this.onQuitar});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black12),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: contenido.esImagen
              ? Image.memory(contenido.bytes, fit: BoxFit.cover)
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.picture_as_pdf,
                      size: 28,
                      color: Colors.redAccent,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        contenido.nombreArchivo,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 9),
                      ),
                    ),
                  ],
                ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: IconButton(
            icon: const Icon(Icons.cancel, size: 18, color: Colors.black54),
            onPressed: onQuitar,
            tooltip: 'Quitar',
          ),
        ),
      ],
    );
  }
}
