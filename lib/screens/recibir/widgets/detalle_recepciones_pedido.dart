import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../database/database.dart';
import '../../../utils/desenlace_recepcion.dart';

/// Sección "Recepciones" del detalle de un pedido (HU-146): por cada evento
/// muestra número, fecha, quién recibió, el desenlace agregado y —si existe—
/// la nota libre de la recepción. Si la nota está vacía NO se renderiza bloque.
///
/// Widget REUTILIZABLE a propósito: es el hook para la ficha del proveedor
/// (HU-009), que va a mostrar el mismo historial por proveedor.
class DetalleRecepcionesPedido extends StatelessWidget {
  final List<Recepcion> recepciones;

  const DetalleRecepcionesPedido({super.key, required this.recepciones});

  @override
  Widget build(BuildContext context) {
    if (recepciones.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recepciones',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 4),
        // Altura acotada + scroll propio: el widget se renderiza en sheets sin
        // scroll (detalle del pedido) y a futuro en la ficha del proveedor
        // (HU-009); varias recepciones con notas largas no deben desbordar.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final r in recepciones) _fila(r)],
            ),
          ),
        ),
      ],
    );
  }

  Widget _fila(Recepcion r) {
    final lineas = _lineas(r.items); // null = items ilegibles (corrupción)
    final nota = (r.nota ?? '').trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'N°${r.numeroRecepcion} · ${_fechaCorta(r.fechaRecepcion)}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(width: 8),
              if (lineas == null)
                _chip('Sin detalle', Colors.grey) // corrupto ≠ "Correcto"
              else
                _chipDesenlace(desenlaceAgregado(lineas)),
              if (r.recepcionadoPorNombre != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'por ${r.recepcionadoPorNombre}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          // La nota sólo se renderiza si se escribió algo (criterio HU-146).
          if (nota.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '“$nota”',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: Colors.black87,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chipDesenlace(String desenlace) {
    switch (desenlace) {
      case DesenlaceRecepcion.rechazado:
        return _chip('Con rechazos', Colors.redAccent);
      case DesenlaceRecepcion.diferencia:
        return _chip('Diferencias', Colors.orange);
      default:
        return _chip('Correcto', Colors.green);
    }
  }

  Widget _chip(String texto, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      texto,
      style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
    ),
  );

  /// Líneas del evento, o null si el JSON es ilegible (no se disfraza de
  /// "Correcto": el caso corrupto se muestra como "Sin detalle").
  List<Map<String, dynamic>>? _lineas(String itemsJson) {
    try {
      return (jsonDecode(itemsJson) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  String _fechaCorta(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}
