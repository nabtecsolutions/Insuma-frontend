import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/controlador_categorias.dart';
import '../../database/database.dart';
import '../../services/servicio_permisos.dart';
import '../../services/servicio_sesion.dart';
import '../../theme/insuma_colors.dart';
import '../widgets/guardia_permiso.dart';
import '../../utils/formatos_entrada.dart';
import '../../utils/sanitizador_texto.dart';

/// Pantalla de administración del catálogo de CATEGORÍAS de insumo (#262).
///
/// Permite al admin dar de alta, renombrar y activar/desactivar (soft-delete) las
/// categorías a las que pertenecen los insumos y que suministran los proveedores.
/// Aislada por negocio y autoprotegida con [GuardiaPermiso]. Usa
/// [Permiso.gestionarRecetas]: es el MISMO permiso de gestión de catálogo que ya
/// gobierna insumos/proveedores (decisión del PO — no un permiso nuevo).
class PantallaCategorias extends StatefulWidget {
  const PantallaCategorias({super.key});

  @override
  State<PantallaCategorias> createState() => _PantallaCategoriasState();
}

class _PantallaCategoriasState extends State<PantallaCategorias> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ControladorCategorias>().cargar();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controlador = context.watch<ControladorCategorias>();
    final puedeGestionar = Permisos.puede(
      context.watch<ServicioSesion>().usuarioRol,
      Permiso.gestionarRecetas,
    );

    return GuardiaPermiso(
      permiso: Permiso.gestionarRecetas,
      mensaje:
          'Se requieren credenciales de Administrador para gestionar las categorías.',
      child: Scaffold(
        backgroundColor: InsumaColors.backgroundLight,
        appBar: AppBar(
          title: const Text('Categorías'),
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 1,
          actions: [
            IconButton(
              tooltip: controlador.verInactivas
                  ? 'Ver solo activas'
                  : 'Ver desactivadas',
              icon: Icon(
                controlador.verInactivas
                    ? Icons.visibility_off
                    : Icons.visibility,
              ),
              onPressed: controlador.alternarVerInactivas,
            ),
          ],
        ),
        floatingActionButton: puedeGestionar
            ? FloatingActionButton.extended(
                backgroundColor: InsumaColors.primaryBlue,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.add),
                label: const Text('Nueva categoría'),
                onPressed: () => _editarCategoria(context),
              )
            : null,
        body: _buildCuerpo(context, controlador),
      ),
    );
  }

  Widget _buildCuerpo(BuildContext context, ControladorCategorias controlador) {
    if (controlador.cargando) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controlador.categorias.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            controlador.verInactivas
                ? 'No hay categorías desactivadas.'
                : 'Todavía no cargaste categorías.\nUsá "Nueva categoría" para crear la primera.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: controlador.categorias.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => _buildTile(context, controlador.categorias[i]),
    );
  }

  Widget _buildTile(BuildContext context, Categoria categoria) {
    final inactiva = !categoria.activo;
    return ListTile(
      leading: Icon(
        inactiva ? Icons.block : Icons.category_outlined,
        color: inactiva ? Colors.grey : InsumaColors.primaryBlue,
      ),
      title: Text(
        categoria.nombre,
        style: TextStyle(
          color: inactiva ? Colors.grey : Colors.black87,
          decoration: inactiva ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: inactiva
          ? const Text('Desactivada', style: TextStyle(fontSize: 11))
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!inactiva)
            IconButton(
              tooltip: 'Editar',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _editarCategoria(context, categoria: categoria),
            ),
          IconButton(
            tooltip: inactiva ? 'Reactivar' : 'Desactivar',
            icon: Icon(
              inactiva ? Icons.restore : Icons.delete_outline,
              size: 20,
              color: inactiva ? Colors.green : Colors.redAccent,
            ),
            onPressed: () => context
                .read<ControladorCategorias>()
                .cambiarEstado(categoria.id, inactiva),
          ),
        ],
      ),
    );
  }

  /// Abre el diálogo de alta (categoria == null) o edición y persiste vía el controlador.
  Future<void> _editarCategoria(
    BuildContext context, {
    Categoria? categoria,
  }) async {
    final controlador = context.read<ControladorCategorias>();
    final messenger = ScaffoldMessenger.of(context);
    final ctrlTexto = TextEditingController(text: categoria?.nombre ?? '');

    final nombre = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(categoria == null ? 'Nueva categoría' : 'Editar categoría'),
        content: TextField(
          controller: ctrlTexto,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: FormatosEntrada.texto(
            maxLongitud: SanitizadorTexto.maxLongitudNombre,
          ),
          decoration: const InputDecoration(
            labelText: 'Nombre de la categoría',
            hintText: 'Ej: Verdulería',
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

    // HU-137: se normaliza antes de guardar, para que "Carnes  rojas " no
    // esquive el índice único de categorías por negocio.
    final nombreLimpio = SanitizadorTexto.limpiar(
      nombre,
      maxLongitud: SanitizadorTexto.maxLongitudNombre,
    );

    final error = categoria == null
        ? await controlador.crear(nombreLimpio)
        : await controlador.renombrar(categoria.id, nombreLimpio);

    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }
}
