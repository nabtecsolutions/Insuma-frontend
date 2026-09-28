import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Un input premium glassmorphic con iconos y bordes para el onboarding.
///
/// #254: el campo encapsula por completo el caso "contraseña". Con
/// [esPassword] `true` nace oculto, ofusca el texto y dibuja su PROPIO ojo
/// para mostrar/ocultar —el estado de visibilidad es de la Vista y vive acá,
/// no en el controlador de negocio (regla de arquitectura del proyecto)—. Así
/// cada campo de contraseña maneja su ojo de forma independiente y ningún
/// call-site tiene que rearmar el IconButton a mano.
///
/// El fondo es un translúcido OSCURO (no claro): sobre el degradé celeste del
/// onboarding, el texto blanco quedaba ilegible —el defecto reportado en #254—.
class InputGlassmorphic extends StatefulWidget {
  final String label;
  final String hint;
  final Function(String) onChange;
  final IconData icono;

  /// #254: marca el campo como contraseña. Ofusca el texto, arranca oculto y
  /// muestra el ojo para alternar la visibilidad (manejado internamente).
  final bool esPassword;

  /// Tipo de teclado (email, número). Complementa —no reemplaza— a
  /// [inputFormatters]: en web y escritorio el teclado no impide tipear nada.
  final TextInputType? tipoTeclado;

  /// HU-137: restringe lo que se puede TIPEAR. Ver [FormatosEntrada].
  final List<TextInputFormatter>? inputFormatters;

  /// Foco del campo (para encadenar Enter entre campos de forma explícita, saltando botones).
  final FocusNode? focusNode;

  /// Acción del teclado (qué muestra el botón Enter: "siguiente", "listo", etc.).
  final TextInputAction? textInputAction;

  /// Se dispara al apretar Enter / el botón de acción del teclado.
  final VoidCallback? onSubmitted;

  const InputGlassmorphic({
    super.key,
    required this.label,
    required this.hint,
    required this.onChange,
    required this.icono,
    this.esPassword = false,
    this.tipoTeclado,
    this.inputFormatters,
    this.focusNode,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  State<InputGlassmorphic> createState() => _InputGlassmorphicState();
}

class _InputGlassmorphicState extends State<InputGlassmorphic> {
  /// Visibilidad del texto ofuscado. Solo aplica cuando [widget.esPassword].
  /// Arranca oculto, como cualquier campo de contraseña.
  bool _oculto = true;

  @override
  Widget build(BuildContext context) {
    final ofuscar = widget.esPassword && _oculto;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label.toUpperCase(),
          style: const TextStyle(
            color: Color(0xE6FFFFFF), // 90% opacidad
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            // #254: translúcido OSCURO. Sobre el degradé celeste, el texto
            // blanco necesita fondo oscuro para leerse (antes: blanco 18% →
            // blanco-sobre-claro, ilegible).
            color: const Color(0x66000000), // negro 40% opacidad
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x59FFFFFF)), // 35% opacidad
          ),
          child: TextField(
            focusNode: widget.focusNode,
            obscureText: ofuscar,
            keyboardType: widget.tipoTeclado,
            inputFormatters: widget.inputFormatters,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            textInputAction: widget.textInputAction,
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: const TextStyle(
                color: Color(0x99FFFFFF),
              ), // 60% opacidad
              prefixIcon: Icon(widget.icono, color: Colors.white70),
              suffixIcon: widget.esPassword
                  ? IconButton(
                      icon: Icon(
                        _oculto ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white,
                      ),
                      tooltip: _oculto ? 'Mostrar' : 'Ocultar',
                      onPressed: () => setState(() => _oculto = !_oculto),
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                vertical: 16,
                horizontal: 16,
              ),
            ),
            onChanged: widget.onChange,
            onSubmitted: widget.onSubmitted == null
                ? null
                : (_) => widget.onSubmitted!(),
          ),
        ),
      ],
    );
  }
}
