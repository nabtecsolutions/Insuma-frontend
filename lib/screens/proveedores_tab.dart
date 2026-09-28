import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../database/database.dart';
import '../controllers/controlador_proveedores.dart';
import '../constants/categorias.dart';
import '../theme/insuma_colors.dart';
import '../utils/validador_datos.dart';
import '../utils/formatos_entrada.dart';
import '../utils/sanitizador_texto.dart';
import 'proveedores/ficha_proveedor_screen.dart';

/// Componente que gestiona la pestaña de Proveedores.
/// Permite listar, buscar, filtrar por categorías, agregar nuevos y ver fichas de perfil con validaciones.
class PestanaProveedores extends StatefulWidget {
  const PestanaProveedores({super.key});

  @override
  State<PestanaProveedores> createState() => _PestanaProveedoresState();
}

class _PestanaProveedoresState extends State<PestanaProveedores> {
  // Categorías de rubros estándar en gastronomía
  final List<String> _categorias = CategoriasApp.categoriasProveedor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ControladorProveedores>().cargarInfoLocalYProveedores();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controlador = context.watch<ControladorProveedores>();

    if (controlador.cargando) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      body: Column(
        children: [
          // Barra de Búsqueda y Filtros
          _buildBarraBusqueda(controlador),

          // Carrusel de Categorías
          _buildCarruselCategorias(controlador),

          // Listado de Proveedores
          Expanded(child: _buildListadoProveedores(controlador)),
        ],
      ),
      // En modo "ver desactivados" no se crean proveedores: solo se reactivan.
      floatingActionButton: controlador.verInactivos
          ? null
          : FloatingActionButton(
              onPressed: _mostrarFormularioProveedor,
              backgroundColor: InsumaColors.primaryBlue,
              foregroundColor: Colors.white,
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.add),
            ),
    );
  }

  /// Descarga del negocio desde Supabase y refresca la lista (botón de recarga).
  Future<void> _recargarDesdeLaNube(ControladorProveedores controlador) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Sincronizando…')));
    await controlador.recargarDesdeLaNube();
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(content: Text('Proveedores actualizados.')),
    );
  }

  /// Construye el campo de texto superior para búsquedas.
  Widget _buildBarraBusqueda(ControladorProveedores controlador) {
    final esAdmin = controlador.usuarioRol == 'admin';
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              style: const TextStyle(color: Colors.black),
              decoration: InputDecoration(
                hintText: 'Buscar por empresa o contacto...',
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
              onChanged: (v) => controlador.actualizarBusqueda(v),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Recargar desde la nube',
            onPressed: () => _recargarDesdeLaNube(controlador),
            icon: Icon(Icons.refresh, color: Colors.grey[500]),
          ),
          // Solo el admin puede ver/gestionar proveedores desactivados (HU-008).
          if (esAdmin) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: controlador.verInactivos
                  ? 'Ver activos'
                  : 'Ver desactivados',
              onPressed: () => controlador.alternarVerInactivos(),
              icon: Icon(
                controlador.verInactivos
                    ? Icons.visibility_off
                    : Icons.visibility_outlined,
                color: controlador.verInactivos
                    ? Colors.redAccent
                    : Colors.grey[500],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Construye el selector horizontal de categorías de rubro.
  Widget _buildCarruselCategorias(ControladorProveedores controlador) {
    return Container(
      height: 52,
      color: Colors.white,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _categorias.length,
        itemBuilder: (context, index) {
          final cat = _categorias[index];
          final seleccionado = controlador.categoriaSeleccionada == cat;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: ChoiceChip(
              label: Text(cat),
              selected: seleccionado,
              onSelected: (val) {
                if (val) controlador.actualizarCategoriaSeleccionada(cat);
              },
              selectedColor: InsumaColors.primaryBlue,
              backgroundColor: Colors.grey[100],
              labelStyle: TextStyle(
                color: seleccionado ? Colors.white : Colors.black87,
                fontWeight: seleccionado ? FontWeight.bold : FontWeight.normal,
                fontSize: 12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              side: BorderSide.none,
              showCheckmark: false,
            ),
          );
        },
      ),
    );
  }

  /// Construye el listado de tarjetas de proveedores.
  Widget _buildListadoProveedores(ControladorProveedores controlador) {
    final filtrados = controlador.proveedoresFiltrados;
    if (filtrados.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.local_shipping_outlined,
              size: 48,
              color: Colors.grey[300],
            ),
            const SizedBox(height: 12),
            Text(
              'No se encontraron proveedores',
              style: TextStyle(color: Colors.grey[500], fontSize: 14),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: filtrados.length,
      itemBuilder: (context, index) {
        final prov = filtrados[index];
        return Card(
          color: Colors.white,
          elevation: 0,
          margin: const EdgeInsets.symmetric(vertical: 4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: InsumaColors.cardBorderLight),
          ),
          child: InkWell(
            onTap: () => _mostrarFichaProveedor(prov),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: InsumaColors.avatarBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      prov.nombre.substring(0, 1).toUpperCase(),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: InsumaColors.primaryBlue,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          prov.nombre,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.grey[100],
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                prov.categoria ?? 'Otros',
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: Colors.black54,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (prov.plazoPago != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                'Plazo: ${prov.plazoPago}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                            if (!prov.activo) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.red[50],
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'Desactivado',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: Colors.redAccent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Muestra el modal de alta o edición de proveedor con validaciones (HU-007/HU-008).
  /// Si recibe [proveedor], precarga sus datos y guarda los cambios; si no, crea uno nuevo.
  void _mostrarFormularioProveedor([Proveedore? proveedor]) {
    final esEdicion = proveedor != null;
    final categoriasValidas = _categorias.where((c) => c != 'Todos').toList();
    const plazos = ['Contado', '7 días', '15 días', '30 días'];

    String nombre = proveedor?.nombre ?? '';
    String rubro =
        (proveedor?.categoria != null &&
            categoriasValidas.contains(proveedor!.categoria))
        ? proveedor.categoria!
        : (categoriasValidas.contains('Carnes')
              ? 'Carnes'
              : categoriasValidas.first);
    String contacto = proveedor?.contacto ?? '';
    String telefono = proveedor?.telefono ?? '';
    String email = proveedor?.email ?? '';
    String cuit = proveedor?.cuit ?? '';
    // #220: con qué se le transfiere. Los dos opcionales: un proveedor al que
    // se le paga en efectivo no tiene por qué tenerlos.
    String aliasBancario = proveedor?.aliasBancario ?? '';
    String cbu = proveedor?.cbu ?? '';
    String plazoPago =
        (proveedor?.plazoPago != null && plazos.contains(proveedor!.plazoPago))
        ? proveedor.plazoPago!
        : 'Contado';
    String? error;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                top: 16,
                left: 20,
                right: 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      esEdicion ? 'Editar Proveedor' : 'Nuevo Proveedor',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      initialValue: nombre,
                      inputFormatters: FormatosEntrada.texto(
                        maxLongitud: SanitizadorTexto.maxLongitudNombre,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Nombre de la empresa *',
                      ),
                      style: const TextStyle(color: Colors.black),
                      onChanged: (v) => nombre = v,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      // #215: sin esto el dropdown se mide por su ítem más ancho e
                      // ignora el ancho disponible: desborda en pantalla de teléfono.
                      isExpanded: true,
                      initialValue: rubro,
                      decoration: const InputDecoration(
                        labelText: 'Rubro / Categoría *',
                      ),
                      items: _categorias
                          .where((c) => c != 'Todos')
                          .map(
                            (c) => DropdownMenuItem(value: c, child: Text(c)),
                          )
                          .toList(),
                      onChanged: (v) =>
                          setModalState(() => rubro = v ?? 'Otros'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: contacto,
                      inputFormatters: FormatosEntrada.texto(
                        maxLongitud: SanitizadorTexto.maxLongitudNombre,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Nombre de contacto (opcional)',
                      ),
                      style: const TextStyle(color: Colors.black),
                      onChanged: (v) => contacto = v,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: telefono,
                      keyboardType: TextInputType.phone,
                      // Dígitos y los separadores que ValidadorDatos.validarTelefono
                      // ya tolera: nada de letras en un número de teléfono.
                      inputFormatters: FormatosEntrada.telefono(),
                      decoration: const InputDecoration(
                        labelText: 'Teléfono *',
                      ),
                      style: const TextStyle(color: Colors.black),
                      onChanged: (v) => telefono = v,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: email,
                      keyboardType: TextInputType.emailAddress,
                      inputFormatters: FormatosEntrada.email(),
                      decoration: const InputDecoration(
                        labelText: 'Correo electrónico (opcional)',
                      ),
                      style: const TextStyle(color: Colors.black),
                      onChanged: (v) => email = v,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: cuit,
                      keyboardType: TextInputType.number,
                      // El CUIT son 11 dígitos exactos: el campo no admite más.
                      inputFormatters: FormatosEntrada.soloDigitos(largo: 11),
                      decoration: const InputDecoration(
                        labelText: 'CUIT (11 dígitos, opcional)',
                      ),
                      style: const TextStyle(color: Colors.black),
                      onChanged: (v) => cuit = v,
                    ),
                    const SizedBox(height: 12),
                    // #220: eran un campo MUERTO que decía "Disponible
                    // próximamente". Ahora se cargan de verdad, y con ellos la
                    // pantalla de pago deja de mandar al admin a buscarlos
                    // afuera de la app.
                    TextFormField(
                      initialValue: aliasBancario,
                      decoration: const InputDecoration(
                        labelText: 'Alias de pago (opcional)',
                        hintText: 'mi.alias.mp',
                      ),
                      style: const TextStyle(color: Colors.black),
                      onChanged: (v) => aliasBancario = v,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: cbu,
                      keyboardType: TextInputType.number,
                      // 22 dígitos justos: el formateador impide tipear de más
                      // antes de que la validación tenga que rechazarlo.
                      inputFormatters: FormatosEntrada.soloDigitos(largo: 22),
                      decoration: const InputDecoration(
                        labelText: 'CBU / CVU (22 dígitos, opcional)',
                      ),
                      style: const TextStyle(color: Colors.black),
                      onChanged: (v) => cbu = v,
                    ),

                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      // #215: sin esto el dropdown se mide por su ítem más ancho e
                      // ignora el ancho disponible: desborda en pantalla de teléfono.
                      isExpanded: true,
                      initialValue: plazoPago,
                      decoration: const InputDecoration(
                        labelText: 'Plazo de pago',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'Contado',
                          child: Text('Contado'),
                        ),
                        DropdownMenuItem(
                          value: '7 días',
                          child: Text('7 días'),
                        ),
                        DropdownMenuItem(
                          value: '15 días',
                          child: Text('15 días'),
                        ),
                        DropdownMenuItem(
                          value: '30 días',
                          child: Text('30 días'),
                        ),
                      ],
                      onChanged: (v) =>
                          setModalState(() => plazoPago = v ?? 'Contado'),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        error!,
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () async {
                        if (nombre.trim().isEmpty ||
                            rubro.isEmpty ||
                            telefono.trim().isEmpty) {
                          setModalState(
                            () => error =
                                'Los campos marcados con (*) son requeridos.',
                          );
                          return;
                        }
                        if (!ValidadorDatos.validarTelefono(telefono)) {
                          setModalState(
                            () => error =
                                'El teléfono debe tener al menos 6 dígitos.',
                          );
                          return;
                        }
                        if (email.isNotEmpty &&
                            !ValidadorDatos.validarEmail(email)) {
                          setModalState(
                            () => error = 'El formato de correo es incorrecto.',
                          );
                          return;
                        }
                        if (cuit.isNotEmpty &&
                            !ValidadorDatos.validarCuit(cuit)) {
                          setModalState(
                            () => error =
                                'CUIT inválido. Debe tener 11 dígitos y estructura correcta.',
                          );
                          return;
                        }

                        // HU-137: se normaliza ANTES de chequear duplicados, para
                        // que " Distribuidora Sur " no entre como un proveedor
                        // distinto de "Distribuidora Sur".
                        nombre = SanitizadorTexto.limpiar(
                          nombre,
                          maxLongitud: SanitizadorTexto.maxLongitudNombre,
                        );
                        contacto = SanitizadorTexto.limpiar(contacto);
                        email = SanitizadorTexto.limpiar(email);
                        cuit = ValidadorDatos.soloDigitos(cuit);

                        final navigator = Navigator.of(context);
                        final ctrl = context.read<ControladorProveedores>();

                        // En edición no aplica la detección de duplicados por nombre:
                        // el CUIT único (excluyendo el propio) se valida en el controlador.
                        if (esEdicion) {
                          await ctrl.editarProveedor(
                            id: proveedor.id,
                            nombre: nombre,
                            categoria: rubro,
                            contacto: contacto,
                            email: email,
                            telefono: telefono,
                            plazoPago: plazoPago,
                            cuit: cuit,
                            aliasBancario: aliasBancario,
                            cbu: cbu,
                            alCompletar: () => navigator.pop(),
                            mostrarError: (err) =>
                                setModalState(() => error = err),
                          );
                          return;
                        }

                        // Detección de duplicados (HU-007): CUIT exacto bloquea
                        // (único por negocio); nombre repetido solo advierte.
                        final dup = ctrl.chequearDuplicados(
                          nombre: nombre,
                          cuit: cuit,
                        );
                        if (dup.cuitDuplicado) {
                          setModalState(
                            () => error =
                                'Ya existe un proveedor con ese CUIT en este negocio.',
                          );
                          return;
                        }
                        if (dup.nombreDuplicado) {
                          final continuar = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: Colors.white,
                              title: const Text(
                                'Posible duplicado',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87,
                                ),
                              ),
                              content: Text(
                                'Ya existe un proveedor llamado "${nombre.trim()}". ¿Crear de todos modos?',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.black87,
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text(
                                    'Cancelar',
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text(
                                    'Crear igual',
                                    style: TextStyle(
                                      color: InsumaColors.primaryBlue,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                          if (continuar != true) return;
                        }

                        await ctrl.crearProveedor(
                          nombre: nombre,
                          categoria: rubro,
                          contacto: contacto,
                          email: email,
                          telefono: telefono,
                          plazoPago: plazoPago,
                          cuit: cuit,
                          aliasBancario: aliasBancario,
                          cbu: cbu,
                          alCompletar: () => navigator.pop(),
                          mostrarError: (err) =>
                              setModalState(() => error = err),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text(
                        esEdicion ? 'Guardar Cambios' : 'Registrar Proveedor',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Muestra la ficha de perfil completa del proveedor y sus insumos asociados.
  /// Abre la ficha del proveedor (HU-009).
  ///
  /// Antes acá vivía un `showModalBottomSheet` de ~290 líneas con los datos, las
  /// acciones y el catálogo de insumos. Se mudó entero a [FichaProveedorScreen]:
  /// con el historial de pedidos y sus filtros adentro, una hoja no daba, y
  /// mantener dos fichas parciales conviviendo era la peor salida.
  ///
  /// La pantalla devuelve una acción cuando necesita algo que sólo esta pestaña
  /// sabe hacer: el formulario de alta/edición es privado de acá, y duplicarlo
  /// allá habría sido copiar 230 líneas.
  Future<void> _mostrarFichaProveedor(Proveedore proveedor) async {
    final accion = await Navigator.of(context).push<AccionFichaProveedor>(
      MaterialPageRoute(
        builder: (_) => FichaProveedorScreen(proveedor: proveedor),
      ),
    );
    if (!mounted) return;
    if (accion == AccionFichaProveedor.editar) {
      _mostrarFormularioProveedor(proveedor);
    }
  }
}
