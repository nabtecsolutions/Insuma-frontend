import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/servicio_sesion.dart';
import '../../services/servicio_permisos.dart';

/// Envuelve una pantalla o sección sensible y solo la muestra si el rol del
/// usuario en sesión tiene el [permiso] requerido. Si no, muestra una vista de
/// "Acceso restringido".
///
/// Es la barrera de **defensa en profundidad**: aunque el menú esconda la opción,
/// la pantalla se protege a sí misma. Así, un acceso directo a una ruta no
/// autorizada queda bloqueado igual.
class GuardiaPermiso extends StatelessWidget {
  final Permiso permiso;
  final Widget child;

  /// Mensaje opcional que se muestra en la vista de acceso restringido.
  final String? mensaje;

  const GuardiaPermiso({
    super.key,
    required this.permiso,
    required this.child,
    this.mensaje,
  });

  @override
  Widget build(BuildContext context) {
    // Usamos el rol EFECTIVO: el base normalmente (para el SuperAdmin dentro de
    // un negocio ya es 'admin'), o el elevado si hay una elevación por PIN
    // vigente (HU-043). Al vencer/revocarse, la sesión notifica y esta barrera
    // se reconstruye, re-bloqueando la sección automáticamente.
    final rol = context.watch<ServicioSesion>().usuarioRol;
    if (Permisos.puede(rol, permiso)) return child;
    return _VistaRestringida(mensaje: mensaje);
  }
}

/// Vista mostrada cuando el rol no tiene el permiso requerido.
class _VistaRestringida extends StatelessWidget {
  final String? mensaje;

  const _VistaRestringida({this.mensaje});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                color: Color(0xFFFDEDEC),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_outline,
                size: 40,
                color: Colors.redAccent,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Acceso Restringido',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              mensaje ??
                  'Se requieren credenciales de Administrador para acceder a esta sección.',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
