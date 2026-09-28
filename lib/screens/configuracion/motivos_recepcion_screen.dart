import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/controlador_motivos_recepcion.dart';
import '../../database/database.dart';
import '../../services/servicio_permisos.dart';
import '../../services/servicio_sesion.dart';
import '../../theme/insuma_colors.dart';
import '../widgets/guardia_permiso.dart';
import '../../utils/formatos_entrada.dart';
import '../../utils/sanitizador_texto.dart';

/// Pantalla de administración del catálogo de motivos de recepción (HU-065).
///
/// Permite al admin dar de alta, renombrar y activar/desactivar (soft-delete) los
/// motivos que luego se eligen al rechazar/observar un ítem en la recepción
/// (HU-064). Aislada por negocio y autoprotegida con [GuardiaPermiso]: solo
/// admin/superadmin (mismo criterio que el resto de pantallas secundarias de admin).
class PantallaMotivosRecepcion extends StatefulWidget {
  const PantallaMotivosRecepcion({super.key});

  @override
  State<PantallaMotivosRecepcion> createState() =>
      _PantallaMotivosRecepcionState();
}

class _PantallaMotivosRecepcionState extends State<PantallaMotivosRecepcion> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ControladorMotivosRecepcion>().cargar();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controlador = context.watch<ControladorMotivosRecepcion>();
    final puedeGestionar = Permisos.puede(
      context.watch<ServicioSesion>().usuarioRol,
      Permiso.gestionarRecetas,
    );

    return GuardiaPermiso(
      permiso: Permiso.gestionarRecetas,
      mensaje:
          'Se requieren credenciales de Administrador para gestionar los motivos de recepción.',
      child: Scaffold(
        backgroundColor: InsumaColors.backgroundLight,
        appBar: AppBar(
          title: const Text('Motivos de recepción'),
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 1,
          actions: [
            IconButton(
              tooltip: controlador.verInactivos
                  ? 'Ver solo activos'
                  : 'Ver desactivados',
              icon: Icon(
                controlador.verInactivos
                    ? Icons.visibility_off
                    : Icons.visibility,
              ),
              onPressed: controlador.alternarVerInactivos,
            ),
          ],
        ),
        floatingActionButton: puedeGestionar
            ? FloatingActionButton.extended(
                backgroundColor: InsumaColors.primaryBlue,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.add),
                label: const Text('Nuevo motivo'),
                onPressed: () => _editarMotivo(context),
              )
            : null,
        body: _buildCuerpo(context, controlador),
      ),
    );
  }

  Widget _buildCuerpo(
    BuildContext context,
    ControladorMotivosRecepcion controlador,
  ) {
    if (controlador.cargando) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controlador.motivos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            controlador.verInactivos
                ? 'No hay motivos desactivados.'
                : 'Todavía no cargaste motivos de recepción.\nUsá "Nuevo motivo" para crear el primero.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: controlador.motivos.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => _buildTile(context, controlador.motivos[i]),
    );
  }

  Widget _buildTile(BuildContext context, MotivosRecepcionData motivo) {
    final inactivo = !motivo.activo;
    return ListTile(
      leading: Icon(
        inactivo ? Icons.block : Icons.label_important_outline,
        color: inactivo ? Colors.grey : InsumaColors.primaryBlue,
      ),
      title: Text(
        motivo.nombre,
        style: TextStyle(
          color: inactivo ? Colors.grey : Colors.black87,
          decoration: inactivo ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: inactivo
          ? const Text('Desactivado', style: TextStyle(fontSize: 11))
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!inactivo)
            IconButton(
              tooltip: 'Editar',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _editarMotivo(context, motivo: motivo),
            ),
          IconButton(
            tooltip: inactivo ? 'Reactivar' : 'Desactivar',
            icon: Icon(
              inactivo ? Icons.restore : Icons.delete_outline,
              size: 20,
              color: inactivo ? Colors.green : Colors.redAccent,
            ),
            onPressed: () => context
                .read<ControladorMotivosRecepcion>()
                .cambiarEstado(motivo.id, inactivo),
          ),
        ],
      ),
    );
  }

  /// Abre el diálogo de alta (motivo == null) o edición y persiste vía el controlador.
  Future<void> _editarMotivo(
    BuildContext context, {
    MotivosRecepcionData? motivo,
  }) async {
    final controlador = context.read<ControladorMotivosRecepcion>();
    final messenger = ScaffoldMessenger.of(context);
    final ctrlTexto = TextEditingController(text: motivo?.nombre ?? '');

    final nombre = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(motivo == null ? 'Nuevo motivo' : 'Editar motivo'),
        content: TextField(
          controller: ctrlTexto,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: FormatosEntrada.texto(
            maxLongitud: SanitizadorTexto.maxLongitudNombre,
          ),
          decoration: const InputDecoration(
            labelText: 'Nombre del motivo',
            hintText: 'Ej: Producto vencido',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrlTexto.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    if (nombre == null) return; // cancelado

    // HU-137: se normaliza antes de guardar, para que "Producto  vencido " no
    // esquive el índice único de motivos por negocio.
    final nombreLimpio = SanitizadorTexto.limpiar(
      nombre,
      maxLongitud: SanitizadorTexto.maxLongitudNombre,
    );

    final error = motivo == null
        ? await controlador.crear(nombreLimpio)
        : await controlador.renombrar(motivo.id, nombreLimpio);

    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }
}
