import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../controllers/controlador_insumos.dart';
import '../../../constants/unidades.dart';
import '../../../controllers/controlador_recibir.dart';
import '../../../database/database.dart';
import '../../../models/insumo_ofrecido.dart';
import '../../../services/servicio_permisos.dart';
import '../../../utils/validador_datos.dart';
import '../../insumos/widgets/formulario_insumo_modal.dart';
import '../../widgets/campo_numerico.dart';

/// Desplegable para elegir qué insumos entran al pedido.
///
/// #262: el modelo es ESTRICTO por categoría — se muestra UN desplegable por cada
/// categoría que suministra el proveedor del pedido, con sus insumos. Para pedir
/// algo de otra categoría, primero hay que asignársela al proveedor en su ficha.
/// Crear un insumo al vuelo (HU-139) sigue disponible: su categoría se restringe
/// a las que suministra el proveedor, así el insumo creado es pedible al toque.
///
/// Depende de [ControladorRecibir] y de [ControladorInsumos] (alta al vuelo).
/// Ambos están en el árbol global de `main.dart`.
class SelectorInsumosPedido extends StatefulWidget {
  const SelectorInsumosPedido({super.key});

  /// Abre el selector como diálogo modal.
  static Future<void> mostrar(BuildContext context) => showDialog(
    context: context,
    builder: (_) => const SelectorInsumosPedido(),
  );

  @override
  State<SelectorInsumosPedido> createState() => _SelectorInsumosPedidoState();
}

class _SelectorInsumosPedidoState extends State<SelectorInsumosPedido> {
  String _query = '';

  /// Insumos marcados y su cantidad, mientras se arma la selección (HU-140).
  ///
  /// Viven en el State y NO en la lista filtrada, así buscar, marcar y limpiar
  /// la búsqueda no pierde lo ya elegido.
  final Set<String> _marcados = {};
  final Map<String, TextEditingController> _cantidades = {};

  /// El future se cachea en el State para poder REEMPLAZARLO cuando la lista
  /// cambie —lo que HU-139 necesita al crear un insumo desde acá.
  late Future<List<GrupoCategoriaOfrecida>> _futureGrupos;

  /// #176: hay una carga en vuelo (marcados o insumo nuevo).
  bool _ocupado = false;

  ControladorRecibir get _ctrl =>
      Provider.of<ControladorRecibir>(context, listen: false);

  /// HU-060: el cocinero no ve costos.
  bool get _puedeVerFinanzas =>
      Permisos.puede(_ctrl.sesion.usuarioRol, Permiso.verFinanzas);

  @override
  void initState() {
    super.initState();
    _futureGrupos = _ctrl.obtenerOfertaInsumos();
  }

  @override
  void dispose() {
    for (final c in _cantidades.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Marca o desmarca un insumo, creando su campo de cantidad la primera vez.
  void _alternar(String insumoId) {
    setState(() {
      if (_marcados.remove(insumoId)) return;
      _marcados.add(insumoId);
      _cantidades.putIfAbsent(insumoId, () => TextEditingController(text: '1'));
    });
  }

  @override
  Widget build(BuildContext context) {
    final hayProveedor = _ctrl.proveedorSeleccionadoId != null;
    final itemsPedido = _ctrl.itemsPedido;

    // #172: el armado del pedido es accesible al cocinero, así que este botón
    // —punto de entrada al alta de insumos— necesita la misma guarda de rol.
    final puedeCrearInsumos = context
        .read<ControladorInsumos>()
        .puedeCrearInsumos;

    return AlertDialog(
      backgroundColor: Colors.white,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Expanded(
            child: Text(
              'Agregar Insumo al Pedido',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ),
          // HU-139: dar de alta un insumo sin abandonar el armado del pedido.
          // Gateado por rol desde #172, y sólo con proveedor elegido (#262: la
          // categoría del insumo nuevo se restringe a las que él suministra).
          if (puedeCrearInsumos && hayProveedor)
            TextButton.icon(
              // #176: dos toques abrían dos formularios de alta encimados.
              onPressed: _ocupado ? null : _crearInsumo,
              icon: const Icon(Icons.add_circle_outline, size: 16),
              label: const Text('Insumo nuevo', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            TextField(
              decoration: InputDecoration(
                hintText: 'Buscar insumo...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder<List<GrupoCategoriaOfrecida>>(
                future: _futureGrupos,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(child: Text('Error: ${snap.error}'));
                  }
                  final grupos = snap.data ?? const <GrupoCategoriaOfrecida>[];

                  if (!hayProveedor) {
                    return const Center(
                      child: Text(
                        'Elegí primero el proveedor del pedido.',
                        style: TextStyle(fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  if (grupos.isEmpty) {
                    return const Center(
                      child: Text(
                        'Este proveedor no suministra ninguna categoría. '
                        'Asignale una en su ficha.',
                        style: TextStyle(fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    );
                  }

                  // Filtra por texto DENTRO de cada categoría y esconde las que
                  // quedan sin coincidencias.
                  final visibles = [
                    for (final g in grupos)
                      (categoria: g.categoria, insumos: _filtrar(g.insumos)),
                  ].where((g) => g.insumos.isNotEmpty).toList();

                  if (visibles.isEmpty) {
                    return const Center(
                      child: Text(
                        'No hay insumos que coincidan.',
                        style: TextStyle(fontSize: 12),
                      ),
                    );
                  }

                  return ListView(
                    children: [
                      for (final g in visibles)
                        ExpansionTile(
                          // Con búsqueda activa se abren solas para mostrar los
                          // resultados; sin búsqueda arrancan colapsadas.
                          key: ValueKey(
                            'cat_${g.categoria.id}_${_query.isNotEmpty}',
                          ),
                          initiallyExpanded: _query.isNotEmpty,
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: EdgeInsets.zero,
                          title: Text(
                            g.categoria.nombre,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          children: [
                            for (final o in g.insumos) _fila(o, itemsPedido),
                          ],
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
        ElevatedButton(
          // Deshabilitado sin nada marcado: no hay nada que cargar. Y apagado
          // mientras carga (#176): el doble toque metía los ítems dos veces.
          onPressed: (_marcados.isEmpty || _ocupado)
              ? null
              : _agregarSeleccionados,
          child: Text(
            _ocupado
                ? 'Agregando…'
                : 'Agregar seleccionados (${_marcados.length})',
          ),
        ),
      ],
    );
  }

  List<InsumoOfrecido> _filtrar(List<InsumoOfrecido> lista) => lista
      .where(
        (o) => o.insumo.nombre.toLowerCase().contains(_query.toLowerCase()),
      )
      .toList();

  Widget _fila(
    InsumoOfrecido ofrecido,
    List<Map<String, dynamic>> itemsPedido,
  ) {
    final ins = ofrecido.insumo;
    final yaAgregado = itemsPedido.any((e) => e['insumoId'] == ins.id);

    final marcado = _marcados.contains(ins.id);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: yaAgregado ? true : marcado,
          // Los que ya están en el pedido no se vuelven a agregar: se ajustan
          // en la lista del pedido.
          onChanged: yaAgregado ? null : (_) => _alternar(ins.id),
          title: Text(
            ins.nombre,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          subtitle: Text(
            yaAgregado
                ? 'Ya está en el pedido — ajustá la cantidad en la lista'
                // Se dice DE DÓNDE sale el precio: uno de referencia del
                // historial es orientativo (mostrarlo como firme induce a pedir
                // a ciegas).
                : (_puedeVerFinanzas
                      ? 'Unidad: ${ins.unidad} · ${ofrecido.etiquetaPrecio(_money)}'
                      : 'Unidad: ${ins.unidad}'),
            style: TextStyle(
              fontSize: 11,
              color: yaAgregado ? Colors.orange.shade800 : null,
            ),
          ),
        ),
        // La cantidad aparece recién al marcar: hasta entonces no hay nada que
        // decidir y ocuparía lugar en una lista larga.
        if (marcado && !yaAgregado)
          Padding(
            padding: const EdgeInsets.only(left: 52, right: 8, bottom: 8),
            child: SizedBox(
              // #214: ensanchado por legibilidad: los dos botones de paso se comen
              // 64 px y al campo le quedaban menos de 80.
              width: 210,
              child: CampoNumerico(
                key: ValueKey('sel_cant_${ins.id}'),
                controlador: _cantidades[ins.id],
                etiqueta: 'Cantidad',
                sufijo: ins.unidad,
                decimales: decimalesDeCantidad(
                  ins.unidad,
                  ValidadorDatos.parsearNumero(_cantidades[ins.id]?.text),
                ),
                paso: 1,
                obligatorio: false,
                permitirCero: true,
                denso: true,
                estilo: const TextStyle(fontSize: 12, color: Colors.black87),
                alCambiar: (_) {},
              ),
            ),
          ),
      ],
    );
  }

  String _money(double v) => '\$${v.toStringAsFixed(2)}';

  /// Da de alta un insumo y lo agrega al pedido, sin cerrar el selector (HU-139).
  ///
  /// #262: el formulario se abre con las categorías del proveedor como únicas
  /// opciones, así el insumo nace en una categoría que él suministra y aparece
  /// de inmediato en la lista.
  Future<void> _crearInsumo() async {
    // #176: el flag se prende ANTES del primer `await` —el cuerpo de un async
    // corre síncrono hasta ahí—, así el segundo toque del mismo frame ya lo
    // encuentra prendido.
    if (_ocupado) return;
    setState(() => _ocupado = true);
    try {
      await _crearInsumoInterno();
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _crearInsumoInterno() async {
    final messenger = ScaffoldMessenger.of(context);
    // Categorías que suministra el proveedor: son las únicas que el insumo nuevo
    // puede tener bajo el modelo estricto.
    final grupos = await _futureGrupos;
    if (!mounted) return;
    final categoriasPermitidas = [for (final g in grupos) g.categoria];
    if (categoriasPermitidas.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Asignale al menos una categoría al proveedor antes de crear un '
            'insumo desde acá.',
          ),
        ),
      );
      return;
    }

    final creado = await _mostrarAltaInsumo(categoriasPermitidas);
    if (!mounted || creado == null) return;

    final resultado = await _ctrl.agregarInsumoNuevo(creado);
    if (!mounted) return;

    // El selector NO se cierra: se refresca la oferta para que el insumo nuevo
    // aparezca ya marcado como agregado.
    setState(() => _futureGrupos = _ctrl.obtenerOfertaInsumos());
    if (!resultado.ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(resultado.error!),
          backgroundColor: Colors.orange.shade800,
        ),
      );
    }
  }

  Future<Insumo?> _mostrarAltaInsumo(List<Categoria> categoriasPermitidas) =>
      FormularioInsumoModal.mostrar(
        context,
        categoriasPermitidas: categoriasPermitidas,
      );

  /// Carga TODOS los marcados de una sola vez, con su cantidad (HU-140).
  Future<void> _agregarSeleccionados() async {
    // #176: el flag se prende antes del primer `await`.
    if (_ocupado) return;
    setState(() => _ocupado = true);
    try {
      await _agregarSeleccionadosInterno();
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _agregarSeleccionadosInterno() async {
    final messenger = ScaffoldMessenger.of(context);
    final grupos = await _futureGrupos;
    final todos = [for (final g in grupos) ...g.insumos];

    final seleccion = <({InsumoOfrecido ofrecido, double cantidad})>[];
    for (final id in _marcados) {
      final ofrecido = todos.where((o) => o.insumo.id == id).firstOrNull;
      if (ofrecido == null) continue;
      final texto = _cantidades[id]?.text ?? '';
      seleccion.add((
        ofrecido: ofrecido,
        cantidad: ValidadorDatos.parsearNumero(texto) ?? 0,
      ));
    }

    final resultado = await _ctrl.agregarSeleccion(seleccion);
    if (!mounted) return;

    if (!resultado.ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(resultado.error!),
          backgroundColor: Colors.orange.shade800,
        ),
      );
      return;
    }

    Navigator.pop(context);
  }
}
