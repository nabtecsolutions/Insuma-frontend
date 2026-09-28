import 'package:flutter/material.dart';

import '../../../theme/insuma_colors.dart';
import '../../../utils/trazabilidad_pedido.dart';

/// Los pasos del pedido, en el detalle (#273).
///
/// Recibe la lista YA ARMADA: la regla de qué pasos hay y de dónde sale cada uno
/// vive en `utils/trazabilidad_pedido.dart`, que es puro y testeado. Acá sólo
/// hay presentación.
///
/// ## Los pasos sin dato se muestran igual
///
/// Un paso que todavía no ocurrió, uno que la app no puede saber y uno que es
/// anterior a la versión que lo empezó a registrar se ven los tres, con textos
/// DISTINTOS. Esconderlos dejaría una lista que se lee como completa sin serlo,
/// y quien mire no podría distinguir "esto no pasó" de "esto no se guarda".
class BloqueTrazabilidad extends StatelessWidget {
  final List<PasoTrazabilidad> pasos;

  const BloqueTrazabilidad({super.key, required this.pasos});

  static String _fechaHora(DateTime d) {
    final l = d.toLocal();
    final dd = l.day.toString().padLeft(2, '0');
    final mm = l.month.toString().padLeft(2, '0');
    final hh = l.hour.toString().padLeft(2, '0');
    final mi = l.minute.toString().padLeft(2, '0');
    return '$dd/$mm/${l.year} $hh:$mi';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 14),
        const Text(
          'Trazabilidad',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 6),
        for (final paso in pasos) _fila(paso),
      ],
    );
  }

  Widget _fila(PasoTrazabilidad paso) {
    final gris = !paso.tieneDato;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      // `Wrap` y no `Row` por lo mismo que la botonera y la línea de fecha de la
      // tarjeta (#180): "Confirmado por el proveedor" + "No se sincroniza entre
      // dispositivos" no entra en un renglón de teléfono, y la app compone su
      // propio factor de tipografía hasta 1.3x (HU-054).
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(
            gris ? Icons.remove_circle_outline : Icons.check_circle_outline,
            size: 13,
            color: gris ? Colors.grey : InsumaColors.primaryBlue,
          ),
          Text(
            etiquetaPaso(paso.paso),
            style: TextStyle(
              fontSize: 12,
              color: gris ? Colors.grey : Colors.black87,
              fontWeight: gris ? FontWeight.normal : FontWeight.w500,
            ),
          ),
          if (paso.tieneDato) ...[
            Text(
              // El nombre puede faltar aunque el hecho exista: un usuario dado
              // de baja, o que este dispositivo nunca bajó. Se dice así, no se
              // muestra el UUID —que es lo que hacía el detalle hasta #273— ni
              // se inventa un "Usuario desconocido" que se lea como un nombre.
              paso.nombre ?? 'Usuario no identificado',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            Text(
              _fechaHora(paso.cuando!),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ] else
            Text(
              textoSinDato(paso.motivo ?? MotivoSinDato.noOcurrio),
              style: const TextStyle(
                fontSize: 11,
                color: Colors.grey,
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      ),
    );
  }
}

/// Lo que se muestra si la trazabilidad no se pudo cargar (#273).
///
/// Existe porque el bloque tiene **captura de errores propia**: hasta #273 un
/// solo fallo en la carga previa abortaba el sheet ENTERO del detalle, y el
/// usuario se quedaba sin ver los ítems ni los costos por un bloque secundario.
/// Acá el detalle se abre igual y sólo este bloque avisa.
class TrazabilidadNoDisponible extends StatelessWidget {
  const TrazabilidadNoDisponible({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: Text(
        'No se pudo cargar la trazabilidad de este pedido.',
        style: TextStyle(fontSize: 11, color: Colors.grey),
      ),
    );
  }
}
