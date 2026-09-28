import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../constants/unidades.dart';
import '../../../database/database.dart';
import '../../../controllers/controlador_insumos.dart';
import '../../../controllers/controlador_categorias.dart';
import '../../../constants/categorias.dart';
import '../../../theme/insuma_colors.dart';
import '../../../utils/formatos_entrada.dart';
import '../../../utils/sanitizador_texto.dart';
import '../../widgets/campo_numerico.dart';

/// Modal de ALTA y EDICIÓN de un insumo (HU-003 / HU-004).
///
/// - Si recibe [insumo], edita ese registro (delegando en
///   [ControladorInsumos.actualizarInsumo]).
/// - Si no, crea uno nuevo desde cero (delegando en
///   [ControladorInsumos.crearInsumo]).
///
/// #262: el insumo ya NO se vincula a un proveedor; pertenece a una CATEGORÍA.
/// Cuando el alta se abre desde el armado de un pedido, [categoriasPermitidas]
/// restringe el desplegable a las categorías que ese proveedor suministra (así
/// el insumo creado es inmediatamente pedible bajo el modelo estricto). En el
/// catálogo se deja `null` y se ofrecen todas las categorías activas del negocio.
///
/// Reglas de negocio aplicadas:
///  • La categoría es OBLIGATORIA.
///  • Nombre obligatorio y costo > 0.
///  • Posible duplicado (mismo nombre + unidad) → advertencia no bloqueante.
///  • Cambio de unidad con el insumo en uso → confirma (misma familia) o bloquea (cruce).
class FormularioInsumoModal extends StatefulWidget {
  /// Insumo a editar. Si es null, el formulario está en modo creación.
  final Insumo? insumo;

  /// Si viene, restringe el desplegable de categorías a estas (alta desde el
  /// selector del pedido). `null` → todas las categorías activas del negocio.
  final List<Categoria>? categoriasPermitidas;

  /// Se invoca tras un alta/edición exitosa (para que la pantalla refresque su lista).
  final VoidCallback? alGuardar;

  const FormularioInsumoModal({
    super.key,
    this.insumo,
    this.categoriasPermitidas,
    this.alGuardar,
  });

  /// Atajo para abrir el formulario como diálogo modal.
  static Future<Insumo?> mostrar(
    BuildContext context, {
    Insumo? insumo,
    List<Categoria>? categoriasPermitidas,
    VoidCallback? alGuardar,
  }) {
    return showDialog<Insumo>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FormularioInsumoModal(
        insumo: insumo,
        categoriasPermitidas: categoriasPermitidas,
        alGuardar: alGuardar,
      ),
    );
  }

  @override
  State<FormularioInsumoModal> createState() => _FormularioInsumoModalState();
}

class _FormularioInsumoModalState extends State<FormularioInsumoModal> {
  late String _nombre;

  /// #262: id de la categoría elegida (fuente de verdad). `null` hasta que hay
  /// alguna seleccionada.
  String? _categoriaId;
  late String _tipo;
  late String _unidad;

  /// HU-137: `null` significa "lo escrito no es un número" (o el campo está
  /// vacío). Antes era un `double` que el `?? 0.0` dejaba en cero, así que un
  /// costo mal tipeado se guardaba como gratis.
  double? _costo;

  String? _error;
  bool _guardando = false;

  bool get _esEdicion => widget.insumo != null;

  static const List<String> _tipos = CategoriasApp.tiposInsumo;

  /// Las unidades salen de la constante canónica (#214). Estaban escritas a mano
  /// acá Y en el modal de receta, sin ninguna fuente común: dos copias del mismo
  /// dato se desincronizan al primer cambio.
  static final List<DropdownMenuItem<String>> _unidades = [
    for (final u in unidadesDisponibles)
      DropdownMenuItem(value: u.codigo, child: Text(u.nombre)),
  ];

  @override
  void initState() {
    super.initState();
    final i = widget.insumo;
    if (i != null) {
      _nombre = i.nombre;
      _categoriaId = i.categoriaId;
      _tipo = i.tipo;
      _unidad = i.unidad;
      _costo = i.costoPorUnidad;
    } else {
      _nombre = '';
      _categoriaId = null;
      _tipo = 'ingrediente';
      _unidad = 'kg';
      _costo = null;
    }
    // #262: si el desplegable NO viene restringido (alta desde el catálogo o
    // edición), se cargan las categorías del negocio tras el primer frame.
    if (widget.categoriasPermitidas == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<ControladorCategorias>().cargar();
      });
    }
  }

  /// Categorías a ofrecer en el desplegable: las restringidas (alta desde el
  /// pedido) o las activas del negocio.
  ///
  /// [escuchar] es `true` sólo desde `build` (reactividad vía `watch`); en un
  /// callback como `_guardar` debe ser `false` (`watch` fuera de build explota).
  List<Categoria> _categoriasDisponibles(
    BuildContext context, {
    required bool escuchar,
  }) {
    final permitidas = widget.categoriasPermitidas;
    if (permitidas != null) return permitidas;
    return escuchar
        ? context.watch<ControladorCategorias>().categorias
        : context.read<ControladorCategorias>().categorias;
  }

  /// Nombre (denormalizado) de la categoría elegida, para guardar junto al id.
  String _nombreCategoria(List<Categoria> disponibles) {
    for (final c in disponibles) {
      if (c.id == _categoriaId) return c.nombre;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = Provider.of<ControladorInsumos>(context, listen: false);
    final puedeVerFinanzas = ctrl.puedeVerFinanzas;

    final categorias = _categoriasDisponibles(context, escuchar: true);
    final cargandoCategorias = widget.categoriasPermitidas == null
        ? context.watch<ControladorCategorias>().cargando
        : false;
    // El valor del desplegable sólo puede ser un id presente en la lista: si el
    // insumo apuntaba a una categoría inactiva (o nula), se pide re-elegir.
    final categoriaValida = categorias.any((c) => c.id == _categoriaId)
        ? _categoriaId
        : null;

    // #172: guarda de rol en el propio formulario. El alta tiene dos puntos de
    // entrada (catálogo y armado del pedido) y cada uno gatea por su lado;
    // ponerla también acá hace que ninguna entrada futura pueda saltearla.
    if (!_esEdicion && !ctrl.puedeCrearInsumos) {
      return _AvisoModal(
        titulo: 'Sin permiso',
        mensaje:
            'Tu rol no tiene permiso para crear insumos. '
            'Pedile a un administrador que lo dé de alta.',
      );
    }

    // #262: categoría obligatoria. Sin ninguna cargada no se puede dar de alta;
    // se remite al CRUD de categorías (reemplaza a la vieja guarda de "sin
    // proveedores", ahora que el insumo pertenece a una categoría).
    if (!_esEdicion && !cargandoCategorias && categorias.isEmpty) {
      return _AvisoModal(
        titulo: 'No hay categorías',
        mensaje:
            'Para crear un insumo primero necesitás al menos una categoría. '
            'Creá una en Administración → Categorías.',
      );
    }

    return AlertDialog(
      backgroundColor: Colors.white,
      title: Text(
        _esEdicion ? 'Editar Insumo' : 'Nuevo Insumo',
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              initialValue: _nombre,
              inputFormatters: FormatosEntrada.texto(
                maxLongitud: SanitizadorTexto.maxLongitudNombre,
              ),
              decoration: const InputDecoration(
                labelText: 'Nombre del Insumo *',
              ),
              style: const TextStyle(color: Colors.black),
              onChanged: (v) => _nombre = v,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              // #215: sin esto el dropdown se mide por su ítem más ancho e
              // ignora el ancho disponible: desborda en pantalla de teléfono.
              isExpanded: true,
              initialValue: categoriaValida,
              decoration: const InputDecoration(labelText: 'Categoría *'),
              hint: const Text('Elegí una categoría'),
              items: categorias
                  .map(
                    (c) => DropdownMenuItem(value: c.id, child: Text(c.nombre)),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _categoriaId = v),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              // #215: sin esto el dropdown se mide por su ítem más ancho e
              // ignora el ancho disponible: desborda en pantalla de teléfono.
              isExpanded: true,
              initialValue: _tipo,
              decoration: const InputDecoration(labelText: 'Tipo *'),
              items: _tipos
                  .map(
                    (t) => DropdownMenuItem(
                      value: t,
                      child: Text(_capitalizar(t)),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _tipo = v ?? _tipo),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              // #215: sin esto el dropdown se mide por su ítem más ancho e
              // ignora el ancho disponible: desborda en pantalla de teléfono.
              isExpanded: true,
              initialValue: _unidad,
              decoration: const InputDecoration(
                labelText: 'Unidad de Medida *',
              ),
              items: _unidades,
              onChanged: (v) => setState(() => _unidad = v ?? _unidad),
            ),
            // #239: el costo SOLO se muestra en EDICIÓN — es el único camino
            // de corrección manual (asiento 'ajuste_manual'). En el ALTA no se
            // pide: el precio real entra con la primera recepción procesada, y
            // pedirlo acá sembraba un número inventado como si fuera compra.
            // HU-060 / #172: además es información financiera — sin
            // verFinanzas no se renderiza, y ocultarlo conserva el costo
            // actual (`_costo` nace del insumo en initState), no lo pone en 0.
            if (_esEdicion && puedeVerFinanzas) ...[
              const SizedBox(height: 8),
              CampoNumerico(
                etiqueta: 'Costo por Unidad (\$)',
                valorInicial: _costo,
                alCambiar: (v) => _costo = v,
              ),
            ],
            // #262: el insumo ya no se vincula a un proveedor (pertenece a una
            // categoría). El form perdió el campo "Proveedor" y el editor de
            // vínculos insumo↔proveedor.
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: InsumaColors.primaryBlue,
            foregroundColor: Colors.white,
          ),
          onPressed: _guardando ? null : _guardar,
          child: _guardando
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Guardar'),
        ),
      ],
    );
  }

  Future<void> _guardar() async {
    // HU-137: el nombre se normaliza (trim + colapso de espacios) para que
    // " Tomate  perita " y "Tomate perita" no sean dos insumos distintos.
    final nombre = SanitizadorTexto.limpiar(
      _nombre,
      maxLongitud: SanitizadorTexto.maxLongitudNombre,
    );
    if (nombre.isEmpty) {
      setState(() => _error = 'El nombre del insumo es obligatorio.');
      return;
    }

    final ctrl = Provider.of<ControladorInsumos>(context, listen: false);

    // #239: el ALTA ya no pide costo (entra por recepción o por la ficha). En
    // EDICIÓN el costo se valida SOLO si cambió — sin esto, un insumo nacido a
    // $0 no podría guardar ni un cambio de nombre, porque no habría forma de
    // satisfacer "costo > 0". Con el campo vacío/mal tipeado, o sin
    // verFinanzas (que ni lo renderiza — #172), se conserva el costo actual;
    // al no cambiar de valor, `actualizarInsumo` tampoco toca
    // historial_precios. La validación de fondo vive en el controlador.
    var costo = 0.0;
    if (_esEdicion) {
      costo = _costo ?? widget.insumo!.costoPorUnidad;
      if (costo != widget.insumo!.costoPorUnidad && costo <= 0) {
        setState(
          () => _error = 'Ingresá un costo por unidad válido, mayor a 0.',
        );
        return;
      }
    }
    if (_categoriaId == null || _categoriaId!.isEmpty) {
      setState(() => _error = 'Debe seleccionar una categoría.');
      return;
    }
    // El nombre denormalizado de la categoría se resuelve del mismo origen que
    // el desplegable (categorías restringidas o las del negocio).
    final categoriaNombre = _nombreCategoria(
      _categoriasDisponibles(context, escuchar: false),
    );

    // Advertencia (no bloqueante) de posible duplicado: mismo nombre + unidad.
    final hayDuplicado = ctrl.existeInsumoDuplicado(
      nombre,
      _unidad,
      excluirId: widget.insumo?.id,
    );
    if (hayDuplicado) {
      final continuar = await _confirmarDuplicado(nombre);
      if (continuar != true) return;
    }

    if (_esEdicion) {
      await _guardarEdicion(ctrl, nombre, costo, categoriaNombre);
    } else {
      await _guardarAlta(ctrl, nombre, categoriaNombre);
    }
  }

  Future<void> _guardarAlta(
    ControladorInsumos ctrl,
    String nombre,
    String categoriaNombre,
  ) async {
    setState(() {
      _guardando = true;
      _error = null;
    });

    final resultado = await ctrl.crearInsumo(
      nombre: nombre,
      categoria: categoriaNombre,
      categoriaId: _categoriaId!,
      tipo: _tipo,
      unidad: _unidad,
    );

    if (!mounted) return;

    if (!resultado.ok) {
      setState(() {
        _guardando = false;
        _error = resultado.error ?? 'No se pudo crear el insumo.';
      });
      return;
    }

    widget.alGuardar?.call();
    // El messenger se toma ANTES del pop: después, este context ya está
    // desmontado y el aviso no llega a mostrarse.
    final messenger = ScaffoldMessenger.of(context);
    // Se devuelve el insumo creado: HU-139 lo agrega al pedido en curso.
    Navigator.pop(context, resultado.insumo);
    messenger.showSnackBar(SnackBar(content: Text('Insumo "$nombre" creado.')));
  }

  Future<void> _guardarEdicion(
    ControladorInsumos ctrl,
    String nombre,
    double costo,
    String categoriaNombre,
  ) async {
    final insumo = widget.insumo!;
    final cambioUnidad = _unidad != insumo.unidad;

    // Reglas del cambio de unidad cuando el insumo se usa en recetas (HU-004).
    if (cambioUnidad) {
      final usos = await ctrl.contarRecetasQueUsanInsumo(insumo.id);
      if (usos > 0) {
        final mismaFamilia = ControladorInsumos.mismaFamiliaUnidad(
          insumo.unidad,
          _unidad,
        );
        if (!mismaFamilia) {
          // Cruce de familia → bloqueado: rompería el costeo de las recetas.
          setState(
            () => _error =
                'No se puede cambiar la unidad de ${insumo.unidad} a $_unidad: rompería el costo de '
                '$usos receta(s) que lo usan. Solo se permite dentro de la misma familia (kg↔g, lt↔ml).',
          );
          return;
        }
        // Misma familia → pedir confirmación explícita.
        if (!mounted) return;
        final confirmar = await _confirmarCambioUnidad(usos);
        if (confirmar != true) return;
      }
    }

    setState(() {
      _guardando = true;
      _error = null;
    });

    final resultado = await ctrl.actualizarInsumo(
      original: insumo,
      nombre: nombre,
      categoria: categoriaNombre,
      categoriaId: _categoriaId!,
      tipo: _tipo,
      unidad: _unidad,
      nuevoCosto: costo,
    );

    if (!mounted) return;

    if (!resultado.ok) {
      setState(() {
        _guardando = false;
        _error = resultado.error ?? 'No se pudo guardar el insumo.';
      });
      return;
    }

    widget.alGuardar?.call();
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          resultado.sinCambios
              ? 'No había cambios para guardar.'
              : 'Insumo actualizado.',
        ),
      ),
    );
  }

  Future<bool?> _confirmarDuplicado(String nombre) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
          'Ya existe un insumo llamado "$nombre" con la unidad $_unidad en este negocio. '
          '¿Querés guardarlo de todos modos?',
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
              'Guardar igual',
              style: TextStyle(color: InsumaColors.primaryBlue),
            ),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmarCambioUnidad(int usos) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text(
          'Confirmar cambio de unidad',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        content: Text(
          'Vas a cambiar la unidad de "${widget.insumo!.nombre}" de ${widget.insumo!.unidad} a $_unidad.\n\n'
          'Este insumo se usa en $usos receta(s). El costo se reconvertirá automáticamente '
          '(misma familia de medida). ¿Confirmás?',
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
              'Confirmar',
              style: TextStyle(color: InsumaColors.primaryBlue),
            ),
          ),
        ],
      ),
    );
  }

  String _capitalizar(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

/// Diálogo de sólo lectura que explica por qué NO se puede dar de alta un insumo
/// (sin proveedores cargados, o sin permiso — #172) y ofrece únicamente cerrar.
class _AvisoModal extends StatelessWidget {
  final String titulo;
  final String mensaje;

  const _AvisoModal({required this.titulo, required this.mensaje});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      title: Text(
        titulo,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
      ),
      content: Text(
        mensaje,
        style: const TextStyle(fontSize: 13, color: Colors.black87),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Entendido',
            style: TextStyle(color: InsumaColors.primaryBlue),
          ),
        ),
      ],
    );
  }
}
