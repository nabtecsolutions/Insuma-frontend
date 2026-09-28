import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Un dato que se copia de un toque: etiqueta, valor y botón de copiar.
///
/// Nació para el alias y el CVU del proveedor (#220), que son justamente datos
/// que nadie tipea a mano: se copian y se pegan en el homebanking. Un dígito
/// mal transcripto en un CBU es una transferencia a otra persona.
///
/// **Cuando el dato no está cargado la fila NO se oculta**: se muestra en gris
/// con el botón apagado. Que falte es información útil —dice "a este proveedor
/// le falta cargarle el alias"—, mientras que esconderla se lee como "esta
/// pantalla no tiene esa función". Es el mismo criterio que ya usa la tarjeta de
/// Pagos con el botón de ver remito.
class FilaDatoCopiable extends StatelessWidget {
  const FilaDatoCopiable({
    super.key,
    required this.icono,
    required this.etiqueta,
    required this.valor,
    this.textoVacio = 'Sin cargar',
  });

  final IconData icono;
  final String etiqueta;

  /// El dato. `null` o vacío ⇒ la fila queda deshabilitada.
  final String? valor;

  /// Qué decir cuando no hay dato. Se muestra en lugar del valor.
  final String textoVacio;

  bool get _hayDato => (valor ?? '').trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final gris = Colors.grey[400];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icono, size: 18, color: gris),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  etiqueta,
                  style: TextStyle(
                    fontSize: 10,
                    color: gris,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _hayDato ? valor!.trim() : textoVacio,
                  // Elipsis y no `Wrap`: un CBU son 22 dígitos y en un teléfono
                  // no entra. Recortarlo no molesta porque nadie lo lee: se
                  // copia. El valor completo viaja igual al portapapeles.
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: _hayDato ? Colors.black87 : gris,
                    fontStyle: _hayDato ? FontStyle.normal : FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _hayDato ? () => _copiar(context) : null,
            tooltip: _hayDato
                ? 'Copiar $etiqueta'
                : '$etiqueta sin cargar para este proveedor',
            icon: const Icon(Icons.copy_rounded, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Future<void> _copiar(BuildContext context) async {
    // El messenger se toma ANTES del await: después, si el widget se
    // desmontó, `context` ya no sirve.
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: valor!.trim()));
    messenger.showSnackBar(
      SnackBar(
        content: Text('$etiqueta copiado.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
