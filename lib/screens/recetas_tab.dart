import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../database/database.dart';
import '../controllers/controlador_recetas.dart';
import '../services/servicio_costos_receta.dart';
import '../services/servicio_permisos.dart';
import '../constants/categorias.dart';
import '../theme/insuma_colors.dart';
import '../utils/calculadora_costos.dart';
import 'recetas/widgets/formulario_receta_modal.dart';

/// Pestaña del Recetario y Costeo (Food Cost).
/// Permite listar recetas, filtrarlas por categoría, archivarlas,
/// y gestionar sus ingredientes con cálculo automático de costos.
class PestanaRecetas extends StatefulWidget {
  const PestanaRecetas({super.key});

  @override
  State<PestanaRecetas> createState() => _PestanaRecetasState();
}

class _PestanaRecetasState extends State<PestanaRecetas> {
  ControladorRecetas get _ctrl =>
      Provider.of<ControladorRecetas>(context, listen: false);

  String get _categoriaSeleccionada =>
      Provider.of<ControladorRecetas>(context).categoriaSeleccionada;
  set _categoriaSeleccionada(String v) =>
      _ctrl.actualizarCategoriaSeleccionada(v);

  bool get _mostrarArchivadas =>
      Provider.of<ControladorRecetas>(context).mostrarArchivadas;
  set _mostrarArchivadas(bool v) {
    _ctrl.conmutarMostrarArchivadas(v);
  }

  bool get _cargando => Provider.of<ControladorRecetas>(context).cargando;
  List<Receta> get _recetasFiltradas =>
      Provider.of<ControladorRecetas>(context).recetasFiltradas;
  String get _negocioId => Provider.of<ControladorRecetas>(context).negocioId;
  String get _rolUsuario => Provider.of<ControladorRecetas>(context).usuarioRol;

  final List<String> _categorias = CategoriasApp.categoriasReceta;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cargarDatos();
    });
  }

  void _cargarDatos() {
    _ctrl.cargarDatos();
  }

  @override
  Widget build(BuildContext context) {
    final puedeGestionar = Permisos.puede(
      _rolUsuario,
      Permiso.gestionarRecetas,
    );

    if (_cargando) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      body: Column(
        children: [
          // Barra de búsqueda y selector de archivados
          _buildBarraFiltros(),

          // Selector horizontal de categorías
          _buildCategoriasRow(),

          // Catálogo de recetas
          Expanded(child: _buildCatalogoRecetas()),
        ],
      ),
      floatingActionButton: puedeGestionar
          ? FloatingActionButton(
              onPressed: () => _abrirFormularioReceta(),
              backgroundColor: InsumaColors.primaryBlue,
              foregroundColor: Colors.white,
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.add_card_outlined),
            )
          : null,
    );
  }

  /// Barra superior para búsqueda y visualización de archivados.
  Widget _buildBarraFiltros() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              style: const TextStyle(color: Colors.black87),
              decoration: InputDecoration(
                hintText: 'Buscar receta...',
                hintStyle: TextStyle(color: Colors.grey[400]),
                prefixIcon: Icon(Icons.search, color: Colors.grey[400]),
                fillColor: Colors.grey[50],
                filled: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) => _ctrl.actualizarBusqueda(v),
            ),
          ),
          const SizedBox(width: 8),
          // HU-022: las archivadas son gestión del catálogo — el chip solo existe
          // para quien puede gestionar recetas (el cocinero no lo ve; el
          // controlador además lo ignora fail-closed).
          if (Permisos.puede(_rolUsuario, Permiso.gestionarRecetas)) ...[
            FilterChip(
              label: const Text('Archivadas', style: TextStyle(fontSize: 12)),
              selected: _mostrarArchivadas,
              onSelected: (val) => setState(() => _mostrarArchivadas = val),
              selectedColor: Colors.grey[300],
              backgroundColor: Colors.grey[100],
              labelStyle: TextStyle(
                color: _mostrarArchivadas ? Colors.black87 : Colors.grey[600],
                fontWeight: _mostrarArchivadas
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
              side: BorderSide.none,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(width: 4),
          ],
          IconButton(
            tooltip: 'Recargar desde la nube',
            onPressed: _recargarDesdeLaNube,
            icon: Icon(Icons.refresh, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  /// Descarga del negocio desde Supabase y refresca el catálogo (botón de recarga).
  Future<void> _recargarDesdeLaNube() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Sincronizando…')));
    await _ctrl.recargarDesdeLaNube();
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(content: Text('Recetas actualizadas.')),
    );
  }

  /// Selector de categorías tipo chip horizontal.
  Widget _buildCategoriasRow() {
    return Container(
      height: 48,
      color: Colors.white,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _categorias.length,
        itemBuilder: (context, index) {
          final cat = _categorias[index];
          final seleccionada = _categoriaSeleccionada == cat;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: ChoiceChip(
              label: Text(cat),
              selected: seleccionada,
              onSelected: (val) {
                if (val) setState(() => _categoriaSeleccionada = cat);
              },
              selectedColor: InsumaColors.primaryBlue,
              backgroundColor: Colors.grey[100],
              labelStyle: TextStyle(
                color: seleccionada ? Colors.white : Colors.black87,
                fontWeight: seleccionada ? FontWeight.bold : FontWeight.normal,
                fontSize: 12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              side: BorderSide.none,
              showCheckmark: false,
            ),
          );
        },
      ),
    );
  }

  /// Muestra el listado de recetas encontradas en tarjetas adaptativas.
  Widget _buildCatalogoRecetas() {
    final filtradas = _recetasFiltradas;
    if (filtradas.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.restaurant_menu, size: 48, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text(
              _mostrarArchivadas
                  ? 'No hay recetas archivadas'
                  : 'No se encontraron recetas',
              style: TextStyle(color: Colors.grey[500], fontSize: 14),
            ),
          ],
        ),
      );
    }

    final puedeVerFinanzas = Permisos.puede(_rolUsuario, Permiso.verFinanzas);

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      // #215: alto FIJO en píxeles, no una proporción del ancho.
      //
      // Con `childAspectRatio: 2.8` el alto del tile dependía del ancho de la
      // pantalla: a 360 dp daba ~120 px y el contenido necesita ~124 — la card
      // desbordaba 4 px por abajo, cortando la última línea. En Chrome, con la
      // ventana ancha, el mismo ratio daba de sobra y no se veía.
      //
      // El contenido de esta card tiene alto casi fijo (avatar + tres líneas),
      // así que atarlo al ancho nunca tuvo sentido. `mainAxisExtent` lo hace
      // predecible en cualquier pantalla, y deja aire para la tipografía
      // agrandada de HU-054 — el aviso de mano de obra de HU-152 se metió como
      // ícono en una fila existente justo por esta restricción.
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 400,
        mainAxisExtent: 132,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: filtradas.length,
      itemBuilder: (context, index) {
        final rec = filtradas[index];
        final costosCache = Provider.of<ControladorRecetas>(
          context,
        ).costosCache;
        final costoReceta = costosCache[rec.id];
        final costoPorPorcion = costoReceta?.costoPorPorcion ?? 0.0;
        final precioCarta = rec.precioVentaCarta ?? 0.0;

        final margenReal = CalculadoraCostos.margenReal(
          precioVenta: precioCarta,
          costoPorPorcion: costoPorPorcion,
        );

        // FoodCost con semáforo (RN-010 / HU-021), YA resuelto por el servicio.
        //
        // Antes se calculaba acá con `calcularFoodCost(...)` sin pasarle los
        // umbrales, así que se comía los defaults del método (30%/35%) e
        // ignoraba los que el negocio tenía configurados desde HU-031 — un
        // semáforo que no respetaba la configuración con la que el usuario
        // decide precios (#197). Ahora sale del desglose, calculado con los
        // umbrales reales: no queda ningún parámetro que se pueda olvidar.
        final foodCost =
            costoReceta?.foodCost ??
            const ResultadoFoodCost(0.0, SemaforoFoodCost.indefinido);

        return Card(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: InsumaColors.cardBorderLight),
          ),
          child: InkWell(
            onTap: () => _mostrarFichaDetalle(rec, costoReceta),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  // Avatar con letra o icono según categoría
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: InsumaColors.avatarBgNeutral,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      rec.nombre.substring(0, 1).toUpperCase(),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: InsumaColors.primaryBlue,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Información textual
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          rec.nombre,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.black87,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Porciones: ${rec.porciones.toStringAsFixed(0)} · Categ: ${rec.categoria}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 4),
                        // Costo ocultado a operadores
                        if (puedeVerFinanzas) ...[
                          Row(
                            children: [
                              // HU-152: el aviso va DENTRO de esta fila, como un
                              // ícono, y no en una fila propia. La card vive en un
                              // GridView con `childAspectRatio` fijo, así que su
                              // alto está acotado: una fila extra desborda el tile
                              // con la tipografía en "Muy grande" (HU-054). El
                              // tooltip lleva el texto completo.
                              if (costoReceta != null && costoReceta.tieneAviso)
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Tooltip(
                                    message: AvisosManoDeObra.texto(
                                      costoReceta.aviso,
                                    ),
                                    child: const Icon(
                                      Icons.info_outline,
                                      size: 12,
                                      color: Colors.orange,
                                    ),
                                  ),
                                ),
                              // #239: costeo incompleto — mismo slot EN FILA
                              // que el aviso de HU-152 (el tile del grid tiene
                              // alto acotado: una fila extra lo desborda).
                              if (costoReceta != null &&
                                  costoReceta.costeoIncompleto)
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Tooltip(
                                    message: costoReceta.avisoCosteoIncompleto,
                                    child: const Icon(
                                      Icons.warning_amber_rounded,
                                      size: 12,
                                      color: Colors.redAccent,
                                    ),
                                  ),
                                ),
                              Text(
                                'Costo/P: \$${costoPorPorcion.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black54,
                                ),
                              ),
                              if (precioCarta > 0) ...[
                                const SizedBox(width: 8),
                                Text(
                                  'Margen: ${(margenReal * 100).toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color:
                                        margenReal <
                                            (rec.margenDeseadoPorcentaje ??
                                                0.30)
                                        ? Colors.redAccent
                                        : Colors.green,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'FoodCost: ${foodCost.foodCostPorcentaje.toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: switch (foodCost.semaforo) {
                                      SemaforoFoodCost.verde => Colors.green,
                                      SemaforoFoodCost.amarillo =>
                                        Colors.orange,
                                      SemaforoFoodCost.rojo => Colors.redAccent,
                                      SemaforoFoodCost.indefinido =>
                                        Colors.grey,
                                    },
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ] else ...[
                          const Text(
                            'Detalles de preparación',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.blueGrey,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
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

  /// Muestra la ficha detallada de la receta.
  void _mostrarFichaDetalle(Receta receta, CostoRecetaDesglosado? costoReceta) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final puedeGestionar = Permisos.puede(
          _rolUsuario,
          Permiso.gestionarRecetas,
        );
        final puedeVerFinanzas = Permisos.puede(
          _rolUsuario,
          Permiso.verFinanzas,
        );

        // Consultar ingredientes de la receta
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.8,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return FutureBuilder<List<Map<String, dynamic>>>(
              future: _ctrl.obtenerIngredientesConInsumo(receta.id),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                final filas = snapshot.data ?? [];

                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20.0,
                    vertical: 16.0,
                  ),
                  child: ListView(
                    controller: scrollController,
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  receta.nombre,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                ),
                                Text(
                                  'Categoría: ${receta.categoria} · Rinde ${receta.porciones.toStringAsFixed(0)} porciones',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (puedeGestionar) ...[
                            IconButton(
                              icon: const Icon(
                                Icons.edit_outlined,
                                color: Colors.blueGrey,
                              ),
                              tooltip: 'Editar Receta',
                              onPressed: () {
                                Navigator.pop(context);
                                _abrirFormularioReceta(recetaAEditar: receta);
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                receta.archivada
                                    ? Icons.unarchive_outlined
                                    : Icons.archive_outlined,
                                color: Colors.amber[800],
                              ),
                              tooltip: receta.archivada
                                  ? 'Desarchivar'
                                  : 'Archivar',
                              onPressed: () => _confirmarCambioArchivo(receta),
                            ),
                          ],
                        ],
                      ),
                      const Divider(height: 24),

                      // Panel Financiero (Solo Administradores)
                      if (puedeVerFinanzas && costoReceta != null) ...[
                        _buildFichaFinanciera(receta, costoReceta),
                        const Divider(height: 24),
                      ],

                      // Listado de ingredientes
                      const Text(
                        'Ingredientes requeridos',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 8),

                      if (filas.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Colors.grey[50],
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Center(
                            child: Text(
                              'Esta receta no tiene ingredientes registrados.',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        )
                      else
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: filas.length,
                          itemBuilder: (context, idx) {
                            final fila = filas[idx];
                            final ing =
                                fila['ingrediente'] as RecetaIngrediente;
                            final ins = fila['insumo'] as Insumo;

                            // Mostrar cantidades y unidades
                            final cantText =
                                '${ing.cantidadNeta} ${ins.unidad}';
                            final mermaText = ing.desperdicioPorcentaje > 0
                                ? ' (merma: ${(ing.desperdicioPorcentaje * 100).toStringAsFixed(0)}%)'
                                : '';

                            final precUnit = ins.costoPorUnidad;
                            final costo = CalculadoraCostos.costoIngrediente(
                              cantidadNeta: ing.cantidadNeta,
                              desperdicioPorcentaje: ing.desperdicioPorcentaje,
                              costoPorUnidad: precUnit,
                            );

                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(
                                Icons.kitchen_outlined,
                                size: 16,
                              ),
                              title: Text(
                                ins.nombre,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87,
                                ),
                              ),
                              subtitle: Text(
                                'Cantidad: $cantText$mermaText',
                                style: const TextStyle(fontSize: 11),
                              ),
                              // #239: un ingrediente sin precio dice "sin
                              // precio" y no "$0.00" — el cero parece un costo
                              // real y es justo lo que falta.
                              trailing: puedeVerFinanzas
                                  ? (precUnit <= 0
                                        ? const Text(
                                            'sin precio',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.orange,
                                            ),
                                          )
                                        : Text(
                                            '\$${costo.toStringAsFixed(2)}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.black87,
                                            ),
                                          ))
                                  : null,
                            );
                          },
                        ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// Construye el desglose de métricas financieras de la receta.
  Widget _buildFichaFinanciera(
    Receta receta,
    CostoRecetaDesglosado costoReceta,
  ) {
    final precioVenta = receta.precioVentaCarta ?? 0.0;
    final costoPorPorcion = costoReceta.costoPorPorcion;
    final margenDeseado = receta.margenDeseadoPorcentaje ?? 0.30;

    final margenReal = CalculadoraCostos.margenReal(
      precioVenta: precioVenta,
      costoPorPorcion: costoPorPorcion,
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: InsumaColors.financialPanelBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: InsumaColors.financialPanelBorder),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMetricaFinanciera(
                'Costo Total Receta',
                '\$${costoReceta.total.toStringAsFixed(2)}',
              ),
              _buildMetricaFinanciera(
                'Costo por Porción',
                '\$${costoPorPorcion.toStringAsFixed(2)}',
              ),
            ],
          ),
          // HU-152: el costo abierto en sus dos componentes. Un costo alto por
          // insumos y uno por tiempo se corrigen de maneras distintas
          // (renegociar con el proveedor vs. cambiar el proceso), y el total
          // solo no permite distinguirlos.
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMetricaFinanciera(
                'Insumos / Porción',
                '\$${costoReceta.insumosPorPorcion.toStringAsFixed(2)}',
              ),
              _buildMetricaFinanciera(
                'Mano de Obra / Porción',
                '\$${costoReceta.manoDeObraPorPorcion.toStringAsFixed(2)}',
              ),
            ],
          ),
          // El cero no queda mudo: se dice POR QUÉ dio cero y a dónde ir.
          if (costoReceta.tieneAviso) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 14, color: Colors.orange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    AvisosManoDeObra.texto(costoReceta.aviso),
                    style: const TextStyle(fontSize: 11, color: Colors.orange),
                  ),
                ),
              ],
            ),
          ],
          // #239: el costo con huecos no pasa por costo real.
          if (costoReceta.costeoIncompleto) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 14,
                  color: Colors.redAccent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    costoReceta.avisoCosteoIncompleto,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMetricaFinanciera(
                'Precio Venta Carta',
                precioVenta > 0
                    ? '\$${precioVenta.toStringAsFixed(2)}'
                    : 'No definido',
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'Margen Financiero',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${(margenReal * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: margenReal < margenDeseado
                          ? Colors.redAccent
                          : Colors.green,
                    ),
                  ),
                  Text(
                    'Deseado: ${(margenDeseado * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 9, color: Colors.grey),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricaFinanciera(String titulo, String valor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          titulo,
          style: const TextStyle(
            fontSize: 10,
            color: Colors.grey,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          valor,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }

  /// Confirmar cambio en el estado archivada de la receta.
  Future<void> _confirmarCambioArchivo(Receta receta) async {
    final act = receta.archivada ? 'desarchivar' : 'archivar';
    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '${act.substring(0, 1).toUpperCase()}${act.substring(1)} Receta',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: Text(
          '¿Está seguro de que desea $act la receta "${receta.nombre}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.amber[900]),
            child: Text(act.substring(0, 1).toUpperCase() + act.substring(1)),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (confirmar == true) {
      try {
        await _ctrl.archivarReceta(receta);
        navigator.pop();
      } catch (e) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Error al archivar: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ─── FORMULARIO DE ALTA / EDICIÓN DE RECETA ──────────────────────────────────

  void _abrirFormularioReceta({Receta? recetaAEditar}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return FormularioRecetaModal(
          negocioId: _negocioId,
          recetaAEditar: recetaAEditar,
          alGuardar: () {
            _cargarDatos();
          },
        );
      },
    );
  }
}
