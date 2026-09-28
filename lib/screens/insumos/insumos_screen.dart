import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../database/database.dart';
import '../../constants/categorias.dart';
import '../../controllers/controlador_insumos.dart';
import '../../utils/filtros_insumos.dart';
import '../../services/servicio_permisos.dart';
import '../../services/servicio_sesion.dart';
import '../../theme/insuma_colors.dart';
import '../../utils/formato_insumo.dart';
import 'historial_precios_screen.dart';
import 'widgets/formulario_insumo_modal.dart';

/// Pantalla de insumos (HU-004): lista los insumos del negocio con buscador. No
/// es una función principal, por eso no vive en la barra de navegación: se abre
/// desde el menú lateral.
///
/// HU-077 — visibilidad por rol: la LISTA es visible para todos (el cocinero arma
/// pedidos con insumos). Lo que se restringe es operar y ver precios:
///  • alta/edición/baja → sólo `gestionarRecetas` (admin/superadmin), igual que la
///    RLS `admin_update_insumo`;
///  • costo por unidad → sólo `verFinanzas` (HU-060).
class PantallaInsumos extends StatefulWidget {
  const PantallaInsumos({super.key});

  @override
  State<PantallaInsumos> createState() => _PantallaInsumosState();
}

class _PantallaInsumosState extends State<PantallaInsumos> {
  /// El controller es la ÚNICA fuente de verdad del texto buscado: guardarlo
  /// además en un `String` del State deja dos copias que hay que sincronizar a
  /// mano, y de ahí salió el bug del Historial de pedidos (#170).
  final _ctrlBusqueda = TextEditingController();

  // ── Filtros (HU-006). `null` = sin filtrar. ──────────────────────────────
  // #262: se retiró el filtro por Proveedor. Los insumos ya no pertenecen a un
  // proveedor (pertenecen a una Categoría), así que la búsqueda va por Categoría.
  String? _categoria;
  String? _tipo;
  EstadoInsumo _estado = EstadoInsumo.activos;

  bool get _hayFiltros =>
      _ctrlBusqueda.text.isNotEmpty ||
      _categoria != null ||
      _tipo != null ||
      _estado != EstadoInsumo.activos;

  void _limpiarFiltros() {
    _ctrlBusqueda.clear();
    setState(() {
      _categoria = null;
      _tipo = null;
      _estado = EstadoInsumo.activos;
    });
  }

  @override
  void dispose() {
    _ctrlBusqueda.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Refresca el catálogo al entrar (idempotente).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ControladorInsumos>().cargarDatos();
    });
  }

  /// Descarga del negocio desde Supabase y refresca la lista (botón de recarga).
  Future<void> _recargarDesdeLaNube() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Sincronizando…')));
    await context.read<ControladorInsumos>().recargarDesdeLaNube();
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(content: Text('Insumos actualizados.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rol = context.watch<ServicioSesion>().usuarioRol;
    // Sólo admin/superadmin puede dar de alta, editar o desactivar insumos.
    final puedeGestionar = Permisos.puede(rol, Permiso.gestionarRecetas);
    // HU-060: el cocinero no ve costos. La lista se muestra igual, sin el precio.
    final puedeVerCostos = Permisos.puede(rol, Permiso.verFinanzas);

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      appBar: AppBar(
        title: const Text('Insumos'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 1,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Recargar desde la nube',
            onPressed: _recargarDesdeLaNube,
          ),
        ],
      ),
      // #172: el ALTA usa el mismo getter que valida el Service —más estricto
      // que `puedeGestionar`, porque crear un insumo también exige verFinanzas—.
      // Con el predicado viejo el botón se mostraba y el formulario respondía
      // "Sin permiso": un botón muerto que promete una acción imposible.
      floatingActionButton:
          context.watch<ControladorInsumos>().puedeCrearInsumos
          ? FloatingActionButton.extended(
              backgroundColor: InsumaColors.primaryBlue,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Nuevo insumo'),
              onPressed: () => FormularioInsumoModal.mostrar(context),
            )
          : null,
      // HU-077: la lista es visible para TODOS los roles (el cocinero arma pedidos
      // con insumos). Lo que se restringe es OPERAR (alta/edición/baja) y VER COSTOS.
      // HU-077: la lista es visible para TODOS los roles.
      body: Builder(
        builder: (context) {
          final ctrl = context.watch<ControladorInsumos>();
          final catalogo = ctrl.insumosDisponibles;
          // Se calculan UNA vez y se pasan hacia abajo: el desplegable y el
          // filtrado tienen que coincidir sobre qué valor está vigente, y
          // recalcularlos en cada mitad abre la puerta a que difieran.
          final categorias = _opciones(
            CategoriasApp.categoriasInsumo,
            catalogo.map((i) => i.categoria),
          );
          final tipos = _opciones(
            CategoriasApp.tiposInsumo,
            catalogo.map((i) => i.tipo),
          );

          final categoria = _vigente(_categoria, categorias);
          final tipo = _vigente(_tipo, tipos);

          return Column(
            children: [
              _buildBuscador(
                categorias: categorias,
                tipos: tipos,
                categoria: categoria,
                tipo: tipo,
              ),
              Expanded(
                child: _buildLista(
                  ctrl: ctrl,
                  puedeGestionar: puedeGestionar,
                  puedeVerCostos: puedeVerCostos,
                  categoria: categoria,
                  tipo: tipo,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Un valor de filtro sólo vale si sigue estando entre las opciones (#38).
  ///
  /// Es la lección de #170, que la primera versión de esta pantalla repitió: una
  /// opción (p. ej. una categoría) desaparece del desplegable pero el filtro
  /// seguía apuntándole, así que `DropdownButton` recibía un `value` sin item y
  /// disparaba el assert de pantalla roja. Se DERIVA en vez de pisar el estado:
  /// si la opción reaparece, el filtro del usuario vuelve solo.
  T? _vigente<T>(T? elegido, Iterable<T> opciones) =>
      elegido != null && opciones.contains(elegido) ? elegido : null;

  /// Opciones de un desplegable: las de catálogo MÁS las que realmente tienen
  /// los insumos cargados. Sin esta unión, un insumo guardado con una categoría
  /// legacy (p. ej. "Lácteos", que existe en las de proveedor pero no en las de
  /// insumo) sería inalcanzable: no habría opción para aislarlo y desaparecería
  /// al elegir cualquier otra. Es la misma tolerancia que ya tiene el formulario
  /// de alta/edición.
  List<String> _opciones(List<String> deCatalogo, Iterable<String> enUso) =>
      <String>{...deCatalogo, ...enUso}.toList()..sort();

  Widget _buildBuscador({
    required List<String> categorias,
    required List<String> tipos,
    required String? categoria,
    required String? tipo,
  }) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          TextField(
            controller: _ctrlBusqueda,
            style: const TextStyle(color: Colors.black),
            decoration: InputDecoration(
              hintText: 'Buscar insumo...',
              hintStyle: TextStyle(color: Colors.grey[400]),
              prefixIcon: Icon(Icons.search, color: Colors.grey[400]),
              fillColor: Colors.grey[50],
              filled: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
            // El controller ya guardó el texto: sólo hay que repintar.
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          // Los desplegables van en un Wrap y no en Rows fijas: a ancho de
          // teléfono bajan de línea solos en vez de desbordar.
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _menu<String?>(
                etiqueta: 'Categoría',
                valor: categoria,
                opciones: {null: 'Todas', for (final c in categorias) c: c},
                alElegir: (v) => setState(() => _categoria = v),
              ),
              _menu<String?>(
                etiqueta: 'Tipo',
                valor: tipo,
                opciones: {
                  null: 'Todos',
                  for (final t in tipos) t: _capitalizar(t),
                },
                alElegir: (v) => setState(() => _tipo = v),
              ),
              _menu<EstadoInsumo>(
                etiqueta: 'Estado',
                valor: _estado,
                opciones: const {
                  EstadoInsumo.activos: 'Activos',
                  EstadoInsumo.inactivos: 'Dados de baja',
                  EstadoInsumo.todos: 'Todos',
                },
                alElegir: (v) =>
                    setState(() => _estado = v ?? EstadoInsumo.activos),
              ),
              if (_hayFiltros)
                TextButton.icon(
                  onPressed: _limpiarFiltros,
                  icon: const Icon(Icons.filter_alt_off, size: 16),
                  label: const Text('Limpiar', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Desplegable compacto de filtro. Usa `DropdownButton` y no
  /// `DropdownButtonFormField`: el FormField guarda su valor aparte del widget y
  /// sólo lo re-sincroniza cuando `initialValue` cambia, que es de donde salió
  /// el assert de pantalla roja del Historial de pedidos (#170).
  Widget _menu<T>({
    required String etiqueta,
    required T valor,
    required Map<T, String> opciones,
    required ValueChanged<T?> alElegir,
  }) {
    // Ancho ACOTADO en vez de `IntrinsicWidth`: el intrínseco es el del item más
    // ancho, así que un proveedor con nombre largo estiraba el control hasta
    // desbordar la fila —y el `ellipsis` del item nunca llegaba a aplicarse
    // porque el `Row` interno no tiene restricción de ancho—. Con un ancho fijo
    // y `isExpanded`, el nombre largo se recorta con puntos suspensivos.
    return SizedBox(
      width: 168,
      child: InputDecorator(
        decoration: InputDecoration(labelText: etiqueta, isDense: true),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: valor,
            isDense: true,
            isExpanded: true,
            items: opciones.entries
                .map(
                  (e) => DropdownMenuItem<T>(
                    value: e.key,
                    child: Text(
                      e.value,
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: alElegir,
          ),
        ),
      ),
    );
  }

  String _capitalizar(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  Widget _buildLista({
    required ControladorInsumos ctrl,
    required bool puedeGestionar,
    required bool puedeVerCostos,
    required String? categoria,
    required String? tipo,
  }) {
    if (ctrl.cargando) {
      return const Center(child: CircularProgressIndicator());
    }

    // El filtrado es una transformación PURA sobre lo que ya está en memoria
    // (`filtros_insumos.dart`): ninguna consulta nueva, así funciona offline y
    // no rompe la reactividad del listado.
    final insumos = filtrarInsumos(
      ctrl.insumosDisponibles,
      texto: _ctrlBusqueda.text,
      categoria: categoria,
      tipo: tipo,
      estado: _estado,
    )..sort((a, b) => a.nombre.toLowerCase().compareTo(b.nombre.toLowerCase()));

    if (insumos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.search_off, size: 48, color: Colors.grey[300]),
              const SizedBox(height: 12),
              Text(
                _hayFiltros
                    ? 'Ningún insumo coincide con los filtros'
                    : 'No hay insumos cargados todavía.',
                style: const TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              if (_hayFiltros) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _limpiarFiltros,
                  child: const Text('Limpiar filtros'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: insumos.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, index) => _buildCard(
        insumos[index],
        puedeGestionar: puedeGestionar,
        puedeVerCostos: puedeVerCostos,
      ),
    );
  }

  Widget _buildCard(
    Insumo insumo, {
    required bool puedeGestionar,
    required bool puedeVerCostos,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: InsumaColors.cardBorderLight),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: InsumaColors.avatarBg,
          child: const Icon(
            Icons.inventory_2_outlined,
            color: InsumaColors.primaryBlue,
            size: 20,
          ),
        ),
        // #38: con el filtro de estado los dados de baja pasan a ser visibles.
        // Sin distintivo se ven idénticos a los vivos, y mezclados en "Todos" no
        // habría forma de saber cuál es cuál.
        title: Row(
          children: [
            Flexible(
              child: Text(
                insumo.nombre,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: insumo.activo ? Colors.black87 : Colors.grey,
                ),
              ),
            ),
            if (!insumo.activo) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Dado de baja',
                  style: TextStyle(fontSize: 10, color: Colors.black54),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          subtituloInsumo(
            categoria: insumo.categoria,
            unidad: insumo.unidad,
            costoPorUnidad: insumo.costoPorUnidad,
            puedeVerCostos: puedeVerCostos,
          ),
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        // Operar el catálogo es exclusivo del admin: el cocinero lo ve en modo lectura.
        // El historial de precios (HU-017) es información financiera → verFinanzas.
        trailing: !puedeGestionar && !puedeVerCostos
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (puedeVerCostos)
                    IconButton(
                      icon: const Icon(
                        Icons.history,
                        color: InsumaColors.primaryBlue,
                      ),
                      tooltip: 'Historial de precios',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              PantallaHistorialPrecios(insumo: insumo),
                        ),
                      ),
                    ),
                  if (puedeGestionar) ...[
                    IconButton(
                      icon: const Icon(
                        Icons.edit_outlined,
                        color: InsumaColors.primaryBlue,
                      ),
                      tooltip: 'Editar insumo',
                      onPressed: () => _abrirEdicion(insumo),
                    ),
                    // Desactivar SÓLO si está activo: sobre uno ya dado de baja
                    // era un no-op destructivo —volvía a escribir activo=false,
                    // incrementaba el contador de concurrencia de HU-028,
                    // encolaba otro UPDATE y auditaba un cambio que no existió—
                    // y encima confirmaba "desactivado" algo que ya lo estaba.
                    if (insumo.activo)
                      IconButton(
                        icon: const Icon(
                          Icons.block_outlined,
                          color: Colors.redAccent,
                        ),
                        tooltip: 'Desactivar insumo',
                        onPressed: () => _confirmarDesactivar(insumo),
                      ),
                  ],
                ],
              ),
      ),
    );
  }

  /// Abre la edición y RECARGA al volver.
  ///
  /// El editor de vínculos del formulario persiste los cambios de proveedor por
  /// su cuenta, y si no se tocó ningún otro campo `actualizarInsumo` devuelve
  /// "sin cambios" sin recargar. Sin este refresco, el índice de proveedores del
  /// filtro queda viejo: se vincula un insumo y el filtro sigue sin encontrarlo.
  Future<void> _abrirEdicion(Insumo insumo) async {
    final ctrl = context.read<ControladorInsumos>();
    await FormularioInsumoModal.mostrar(context, insumo: insumo);
    await ctrl.cargarDatos();
  }

  /// Confirma la baja lógica (HU-005). Informa si el insumo está en uso en recetas:
  /// no se borra, seguirá visible en sus recetas históricas pero no aparecerá en
  /// nuevas selecciones.
  Future<void> _confirmarDesactivar(Insumo insumo) async {
    final ctrl = context.read<ControladorInsumos>();
    final usos = await ctrl.contarRecetasQueUsanInsumo(insumo.id);
    if (!mounted) return;

    final detalleUso = usos > 0
        ? 'Se usa en $usos receta(s): seguirá visible en ellas (trazabilidad histórica), '
              'pero no aparecerá en nuevas selecciones.'
        : 'No está en uso en ninguna receta.';

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text(
          'Desactivar insumo',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        content: Text(
          'Vas a desactivar "${insumo.nombre}". Es una baja lógica: no se elimina el insumo '
          'ni su historial.\n\n$detalleUso',
          style: const TextStyle(fontSize: 13, color: Colors.black87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Desactivar',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    await ctrl.eliminarInsumo(insumo);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('"${insumo.nombre}" desactivado.')));
  }
}
