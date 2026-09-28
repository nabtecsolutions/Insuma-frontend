import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/servicio_recuperacion_password.dart';
import '../../utils/formatos_entrada.dart';

/// Diálogo de autoservicio "olvidé mi contraseña" (HU-076 Fase 2).
///
/// Dos pasos EN LA MISMA app (sin deep linking): (1) pedir el email → Supabase manda
/// un código numérico; (2) ingresar el código + la nueva contraseña. Toda la
/// lógica —envío, verificación, política de contraseña, anti-enumeración— vive en
/// [ServicioRecuperacionPassword]; este widget sólo orquesta la interacción y muestra
/// los mensajes que el service devuelve.
///
/// Al terminar con éxito hace `Navigator.pop(context, true)` para que el login avise
/// "listo, entrá con la nueva". Cancela con `pop(null)`.
class RecuperarPasswordDialog extends StatefulWidget {
  /// Email pre-cargado (el que el usuario ya tipeó en el login), para no re-pedirlo.
  final String emailInicial;

  const RecuperarPasswordDialog({super.key, this.emailInicial = ''});

  @override
  State<RecuperarPasswordDialog> createState() =>
      _RecuperarPasswordDialogState();
}

enum _Paso { pedirEmail, ingresarCodigo }

class _RecuperarPasswordDialogState extends State<RecuperarPasswordDialog> {
  late final TextEditingController _email = TextEditingController(
    text: widget.emailInicial,
  );
  final _codigo = TextEditingController();
  final _nueva = TextEditingController();
  final _repetir = TextEditingController();

  _Paso _paso = _Paso.pedirEmail;
  bool _cargando = false;
  bool _ocultar = true;
  String? _error;
  String? _info;

  ServicioRecuperacionPassword get _servicio =>
      context.read<ServicioRecuperacionPassword>();

  @override
  void dispose() {
    _email.dispose();
    _codigo.dispose();
    _nueva.dispose();
    _repetir.dispose();
    super.dispose();
  }

  Future<void> _enviarCodigo() async {
    setState(() {
      _cargando = true;
      _error = null;
      _info = null;
    });
    final error = await _servicio.solicitarCodigo(_email.text);
    if (!mounted) return;
    setState(() {
      _cargando = false;
      if (error != null) {
        _error = error;
      } else {
        // Mensaje NEUTRO (anti-enumeración): no confirma si el email existe.
        _info = ServicioRecuperacionPassword.mensajeCodigoEnviado;
        _paso = _Paso.ingresarCodigo;
      }
    });
  }

  Future<void> _confirmar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    final error = await _servicio.confirmarCodigo(
      email: _email.text,
      codigo: _codigo.text,
      nuevaPassword: _nueva.text,
      repetirPassword: _repetir.text,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _cargando = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Recuperar contraseña'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_paso == _Paso.pedirEmail)
              ..._camposEmail()
            else
              ..._camposCodigo(),
            if (_info != null) ...[
              const SizedBox(height: 12),
              Text(
                _info!,
                style: TextStyle(color: Colors.green.shade700, fontSize: 13),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Colors.red.shade700, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _cargando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _cargando
              ? null
              : (_paso == _Paso.pedirEmail ? _enviarCodigo : _confirmar),
          child: _cargando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _paso == _Paso.pedirEmail
                      ? 'Enviar código'
                      : 'Cambiar contraseña',
                ),
        ),
      ],
    );
  }

  List<Widget> _camposEmail() => [
    const Text(
      'Ingresá tu correo y te enviaremos un código de '
      '${ServicioRecuperacionPassword.digitosCodigo} dígitos para '
      'restablecer tu contraseña.',
      style: TextStyle(fontSize: 13),
    ),
    const SizedBox(height: 16),
    TextField(
      controller: _email,
      keyboardType: TextInputType.emailAddress,
      inputFormatters: FormatosEntrada.email(),
      autofocus: true,
      decoration: const InputDecoration(
        labelText: 'Correo electrónico',
        border: OutlineInputBorder(),
      ),
      onSubmitted: (_) => _cargando ? null : _enviarCodigo(),
    ),
  ];

  List<Widget> _camposCodigo() => [
    TextField(
      controller: _codigo,
      keyboardType: TextInputType.number,
      // Sólo dígitos, y tantos como emite el backend (#97). El tope va justo en
      // el largo del código: antes admitía 10 y la etiqueta decía 6, así que el
      // campo aceptaba de más y el cartel pedía de menos.
      inputFormatters: FormatosEntrada.entero(
        maxDigitos: ServicioRecuperacionPassword.digitosCodigo,
      ),
      autofocus: true,
      decoration: const InputDecoration(
        labelText:
            'Código de ${ServicioRecuperacionPassword.digitosCodigo} dígitos',
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _nueva,
      obscureText: _ocultar,
      decoration: InputDecoration(
        labelText: 'Nueva contraseña',
        helperText:
            'Mínimo ${ServicioRecuperacionPassword.minPassword} caracteres',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(_ocultar ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _ocultar = !_ocultar),
        ),
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _repetir,
      obscureText: _ocultar,
      decoration: const InputDecoration(
        labelText: 'Repetir la nueva contraseña',
        border: OutlineInputBorder(),
      ),
      onSubmitted: (_) => _cargando ? null : _confirmar(),
    ),
  ];
}
