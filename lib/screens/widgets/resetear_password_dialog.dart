import 'package:flutter/material.dart';

/// Datos que el admin confirma para resetear la contraseña de un miembro (HU-076).
class DatosResetPassword {
  final String nuevaPassword;

  /// Contraseña del PROPIO admin: reconfirma su identidad. Se verifica server-side
  /// (hacerlo en el cliente sería evitable con un `curl`).
  final String passwordAdmin;

  const DatosResetPassword({
    required this.nuevaPassword,
    required this.passwordAdmin,
  });
}

/// Diálogo de reset de contraseña de un miembro del equipo (HU-076).
///
/// Es una VISTA: no valida reglas de negocio ni habla con el backend. Sólo hace las
/// comprobaciones de formulario (campos completos, las dos contraseñas coinciden, el
/// largo mínimo) y devuelve los datos. La autorización real —que el caller sea admin,
/// que el objetivo sea de su negocio, que la contraseña del admin sea correcta— la
/// resuelve la Edge Function `resetear-password`.
///
/// Devuelve `null` si el admin cancela.
class ResetearPasswordDialog extends StatefulWidget {
  /// Nombre del miembro al que se le resetea la contraseña (sólo para el copy).
  final String nombreMiembro;

  /// Largo mínimo exigido. Lo provee el llamador desde `ServicioGestionEquipo`, para
  /// que no haya un número mágico duplicado acá.
  final int minPassword;

  const ResetearPasswordDialog({
    super.key,
    required this.nombreMiembro,
    required this.minPassword,
  });

  @override
  State<ResetearPasswordDialog> createState() => _ResetearPasswordDialogState();
}

class _ResetearPasswordDialogState extends State<ResetearPasswordDialog> {
  final _nueva = TextEditingController();
  final _repetir = TextEditingController();
  final _passwordAdmin = TextEditingController();

  bool _ocultar = true;
  String? _error;

  @override
  void dispose() {
    _nueva.dispose();
    _repetir.dispose();
    _passwordAdmin.dispose();
    super.dispose();
  }

  void _confirmar() {
    final nueva = _nueva.text;
    final repetir = _repetir.text;
    final passwordAdmin = _passwordAdmin.text;

    if (nueva.length < widget.minPassword) {
      setState(
        () => _error =
            'La contraseña debe tener al menos ${widget.minPassword} caracteres.',
      );
      return;
    }
    if (nueva != repetir) {
      setState(() => _error = 'Las contraseñas no coinciden.');
      return;
    }
    if (passwordAdmin.isEmpty) {
      setState(() => _error = 'Ingresá TU contraseña para confirmar.');
      return;
    }

    Navigator.pop(
      context,
      DatosResetPassword(nuevaPassword: nueva, passwordAdmin: passwordAdmin),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text('Resetear la contraseña de ${widget.nombreMiembro}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Se le va a cambiar la contraseña en la nube. Sus sesiones abiertas se '
              'cierran y va a necesitar conexión para volver a entrar con la nueva.',
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nueva,
              obscureText: _ocultar,
              decoration: InputDecoration(
                labelText: 'Nueva contraseña',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _ocultar ? Icons.visibility_off : Icons.visibility,
                  ),
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
            ),
            const Divider(height: 32),
            // Reconfirmación de identidad: reemplaza al challenge de PIN que eliminó
            // HU-077. Evita que un teléfono desbloqueado y olvidado sirva para
            // cambiarle la contraseña a cualquiera del equipo.
            TextField(
              controller: _passwordAdmin,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'TU contraseña (para confirmar)',
                helperText: 'Confirmamos que sos vos quien hace el cambio',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _confirmar(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _confirmar, child: const Text('Resetear')),
      ],
    );
  }
}
