import 'package:flutter/material.dart';

/// Campo de fecha con calendario, con el mismo look que el resto de los campos
/// del formulario (usa [InputDecorator], igual que `CampoNumerico`).
///
/// Nace con HU-142 (fecha de recepción deseada), pero se escribe genérico a
/// propósito: soporta fecha **opcional** (con botón para borrarla) y fecha
/// obligatoria, que es el caso que hoy resuelve a mano `pagos_screen.dart` con
/// un `_selectorFecha` privado.
///
/// No conoce ninguna regla de negocio: los límites entran por [primeraFecha] y
/// [ultimaFecha], y quien lo usa decide de dónde salen.
class CampoFecha extends StatelessWidget {
  /// Texto del label del campo.
  final String etiqueta;

  /// Fecha elegida, o `null` si todavía no hay ninguna.
  final DateTime? valor;

  /// Primer día seleccionable en el calendario.
  final DateTime primeraFecha;

  /// Último día seleccionable en el calendario.
  final DateTime ultimaFecha;

  /// Se dispara con la fecha elegida, o con `null` si se tocó el botón de
  /// borrar. Sólo se llama cuando el valor realmente cambia.
  final ValueChanged<DateTime?> onCambiar;

  /// Qué mostrar cuando no hay fecha.
  final String textoVacio;

  /// Si `true`, aparece una X para volver a "sin fecha". Se apaga cuando el
  /// campo es obligatorio.
  final bool permiteBorrar;

  /// Texto de error a mostrar bajo el campo, o `null` si está todo bien.
  final String? mensajeError;

  /// Si es `false`, el campo se ve pero no abre el calendario (por ejemplo,
  /// un pedido ya confirmado que quedó congelado).
  final bool habilitado;

  const CampoFecha({
    super.key,
    required this.etiqueta,
    required this.valor,
    required this.primeraFecha,
    required this.ultimaFecha,
    required this.onCambiar,
    this.textoVacio = 'Sin definir',
    this.permiteBorrar = true,
    this.mensajeError,
    this.habilitado = true,
  });

  /// `dd/mm/aaaa`. Se formatea acá adentro para que el widget no dependa de
  /// ningún módulo de negocio.
  static String _formatear(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year}';
  }

  /// Elige el día inicial del calendario dejándolo SIEMPRE dentro del rango
  /// permitido: `showDatePicker` lanza un assert si `initialDate` cae fuera de
  /// \[firstDate, lastDate\], y eso pasa solo cuando se reabre un registro
  /// viejo cuya fecha ya venció.
  DateTime get _inicial {
    final base = valor ?? DateTime.now();
    if (base.isBefore(primeraFecha)) return primeraFecha;
    if (base.isAfter(ultimaFecha)) return ultimaFecha;
    return base;
  }

  Future<void> _abrirCalendario(BuildContext context) async {
    final elegida = await showDatePicker(
      context: context,
      initialDate: _inicial,
      firstDate: primeraFecha,
      lastDate: ultimaFecha,
      helpText: etiqueta,
    );
    if (elegida != null && elegida != valor) onCambiar(elegida);
  }

  @override
  Widget build(BuildContext context) {
    final tieneValor = valor != null;
    return InkWell(
      onTap: habilitado ? () => _abrirCalendario(context) : null,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: etiqueta,
          errorText: mensajeError,
          enabled: habilitado,
          prefixIcon: const Icon(Icons.event_outlined),
          // El botón de borrar sólo aparece cuando hay algo que borrar.
          suffixIcon: (tieneValor && permiteBorrar && habilitado)
              ? IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Quitar la fecha',
                  onPressed: () => onCambiar(null),
                )
              : null,
        ),
        child: Text(
          tieneValor ? _formatear(valor!) : textoVacio,
          style: TextStyle(
            color: tieneValor ? Colors.black : Colors.black54,
            fontStyle: tieneValor ? FontStyle.normal : FontStyle.italic,
          ),
        ),
      ),
    );
  }
}
