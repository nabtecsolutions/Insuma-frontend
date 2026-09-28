import 'package:flutter/material.dart';

/// Diálogo para dar de baja a un miembro del equipo (HU-076 Fase 3).
///
/// Reconfirma la identidad del admin pidiéndole SU contraseña, igual que el reset:
/// un teléfono desbloqueado y olvidado no debe alcanzar para banear a todo el equipo.
/// La contraseña se verifica server-side (la Edge Function `dar-de-baja-usuario`);
/// acá sólo se recolecta.
///
/// Devuelve la contraseña del admin si confirma, o `null` si cancela.
class ConfirmarBajaDialog extends StatefulWidget {
  /// Nombre del miembro a dar de baja (sólo para el copy).
  final String nombreMiembro;

  const ConfirmarBajaDialog({super.key, required this.nombreMiembro});

  @override
  State<ConfirmarBajaDialog> createState() => _ConfirmarBajaDialogState();
}

class _ConfirmarBajaDialogState extends State<ConfirmarBajaDialog> {
  final _passwordAdmin = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _passwordAdmin.dispose();
    super.dispose();
  }

  void _confirmar() {
    if (_passwordAdmin.text.isEmpty) {
      setState(() => _error = 'Ingresá TU contraseña para confirmar.');
      return;
    }
    Navigator.pop(context, _passwordAdmin.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Dar de baja usuario',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '¿Dar de baja a "${widget.nombreMiembro}"? Perderá el acceso a la app '
            '(se cierra su cuenta y sus sesiones activas). Es reversible.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordAdmin,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'TU contraseña (para confirmar)',
              helperText: 'Confirmamos que sos vos quien da de baja',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _confirmar(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Colors.red.shade700, fontSize: 13),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: _confirmar,
          style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          child: const Text('Dar de baja'),
        ),
      ],
    );
  }
}
