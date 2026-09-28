import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:drift/drift.dart' hide Column;
import '../../../database/database.dart';
import '../../../controllers/controlador_insumos.dart';
import '../../../controllers/controlador_recetas.dart';
import '../../../services/servicio_configuracion_negocio.dart';
import '../../../services/servicio_costos_receta.dart';
import '../../../constants/categorias.dart';
import '../../../theme/insuma_colors.dart';
import '../../../utils/calculadora_costos.dart';
import '../../../utils/formatos_entrada.dart';
import '../../../utils/sanitizador_texto.dart';
import '../../insumos/widgets/formulario_insumo_modal.dart';
import '../../widgets/campo_numerico.dart';

/// Modal que administra el alta y edición de una receta con sus ingredientes.
class FormularioRecetaModal extends StatefulWidget {
  final String negocioId;
  final Receta? recetaAEditar;
  final VoidCallback alGuardar;

  const FormularioRecetaModal({
    super.key,
    required this.negocioId,
    this.recetaAEditar,
    required this.alGuardar,
  });

  @override
  State<FormularioRecetaModal> createState() => _FormularioRecetaModalState();
}

class _FormularioRecetaModalState extends State<FormularioRecetaModal> {
  final _formKey = GlobalKey<FormState>();
  String _nombre = '';
  double _porciones = 1.0;
  String _categoria = 'Principal';
  double? _precioVenta;
  double? _margenDeseado = 0.30;

  /// Minutos que lleva elaborar la TANDA. Null = no declarado (HU-152).
  double? _tiempoElaboracion;

  /// Parámetros de costeo del negocio: costo por hora (HU-152) y umbrales del
  /// semáforo (#197). Se leen una vez al abrir el modal.
  ///
  /// Arranca en [ParametrosCosteo.sinConfigurar], que es lo mismo que aplica a
  /// un negocio que no configuró nada: mientras carga se ve mano de obra en cero
  /// con su aviso, que es exactamente el estado correcto hasta saber más.
  ParametrosCosteo _parametros = ParametrosCosteo.sinConfigurar;
  String? _error;

  // Lista temporal en memoria de los ingredientes seleccionados
  // Map contiene: 'insumo': Insumo, 'cantidad': double, 'merma': double
  List<Map<String, dynamic>> _ingredientesSeleccionados = [];
  bool _cargandoIngred = false;

  /// Un controlador por ingrediente, indexado por id de insumo (HU-153).
  ///
  /// Antes el campo de cantidad usaba una `ValueKey` que incluía EL VALOR, así
  /// que cada tecla destruía y recreaba el widget: el cursor volvía al inicio y
  /// escribir "125" terminaba en "521". La key con el valor estaba puesta a
  /// propósito, porque era la única forma de que el conversor de unidades
  /// pudiera reescribir la cantidad desde afuera; con un controlador propio esa
  /// escritura externa es directa y la key puede ser estable.
  ///
  /// Mismo patrón que `verificacion_recepcion_modal.dart` con sus cantidades.
  final Map<String, TextEditingController> _controllersCantidad = {};

  final List<String> _categoriasReceta = CategoriasApp.categoriasReceta
      .where((c) => c != 'Todos')
      .toList();

  @override
  void initState() {
    super.initState();
    if (widget.recetaAEditar != null) {
      final r = widget.recetaAEditar!;
      _nombre = r.nombre;
      _porciones = r.porciones;
      _categoria = r.categoria;
      _precioVenta = r.precioVentaCarta;
      _margenDeseado = r.margenDeseadoPorcentaje;
      _tiempoElaboracion = r.tiempoElaboracionMinutos;
      _cargarIngredientesExistentes();
    }
    _cargarParametros();
  }

  /// Trae los parámetros del negocio para estimar el costo en vivo, antes de
  /// guardar (HU-152 / #197).
  ///
  /// `parametrosCosteo` y no `obtener`: la lectura no puede crear la fila de
  /// configuración como efecto colateral — un cocinero no tiene permiso de
  /// escribirla y el INSERT encolado moriría en el push.
  Future<void> _cargarParametros() async {
    final ctrl = Provider.of<ControladorRecetas>(context, listen: false);
    final config = Provider.of<ServicioConfiguracionNegocio>(
      context,
      listen: false,
    );
    if (ctrl.negocioId.isEmpty) return;
    final datos = await config.parametrosCosteo(ctrl.negocioId);
    if (!mounted) return;
    setState(() => _parametros = datos);
  }

  @override
  void dispose() {
    for (final c in _controllersCantidad.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Registra el controlador de un ingrediente recién incorporado a la lista.
  void _registrarControlador(String insumoId, double cantidad) {
    _controllersCantidad[insumoId]?.dispose();
    _controllersCantidad[insumoId] = TextEditingController(
      text: CampoNumerico.textoDe(cantidad),
    );
  }

  /// Escribe la cantidad en el campo Y en el modelo, dejándolos en el mismo valor.
  ///
  /// El redondeo NO es opcional: al asignar `.text` se saltea el redondeo de
  /// presentación de [CampoNumerico], y un valor calculado como 100 g / 120 =
  /// 0,8333333333333334 dejaría el campo TRABADO — el formateador rechazaría
  /// cualquier tecla nueva por exceder los decimales admitidos.
  void _fijarCantidad(int indice, String insumoId, double cantidad) {
    final redondeada = double.parse(
      cantidad.toStringAsFixed(FormatosEntrada.decimalesCantidad),
    );
    _controllersCantidad[insumoId]?.text = CampoNumerico.textoDe(redondeada);
    setState(() => _ingredientesSeleccionados[indice]['cantidad'] = redondeada);
  }

  /// Recupera los ingredientes vinculados si es edición delegando al controlador.
  Future<void> _cargarIngredientesExistentes() async {
    setState(() => _cargandoIngred = true);
    final ctrl = Provider.of<ControladorRecetas>(context, listen: false);

    final filas = await ctrl.obtenerIngredientesConInsumo(
      widget.recetaAEditar!.id,
    );

    final List<Map<String, dynamic>> cargados = [];
    for (final f in filas) {
      final ing = f['ingrediente'] as RecetaIngrediente;
      final ins = f['insumo'] as Insumo;
      cargados.add({
        'insumo': ins,
        'cantidad': ing.cantidadNeta,
        'merma': ing.desperdicioPorcentaje,
      });
    }

    // Se reemplaza la lista entera: los controladores viejos se descartan para
    // no filtrarlos si se recarga la edición.
    for (final c in _controllersCantidad.values) {
      c.dispose();
    }
    _controllersCantidad.clear();
    for (final item in cargados) {
      _registrarControlador(
        (item['insumo'] as Insumo).id,
        item['cantidad'] as double,
      );
    }

    setState(() {
      _ingredientesSeleccionados = cargados;
      _cargandoIngred = false;
    });
  }

  /// Calcula dinámicamente el costo en caliente de la receta en memoria.
  double get _costoTotalCalculado {
    double total = 0.0;
    for (final ing in _ingredientesSeleccionados) {
      final ins = ing['insumo'] as Insumo;
      final cantidad = ing['cantidad'] as double;
      final merma = ing['merma'] as double;
      final precioUnit =
          ins.costoPorUnidad; // usando costo guardado en el insumo

      final costoIng = CalculadoraCostos.costoIngrediente(
        cantidadNeta: cantidad,
        desperdicioPorcentaje: merma,
        costoPorUnidad: precioUnit,
      );
      total += costoIng;
    }
    return total;
  }

  /// Desglose en vivo sobre lo que hay en memoria, todavía sin guardar.
  ///
  /// Reutiliza `ServicioCostosReceta.componer` —la MISMA regla que usa el
  /// listado— en vez de repetir acá la división por porciones, que es donde
  /// está el error fácil: la mano de obra es de la tanda entera y hay que
  /// bajarla a la porción igual que los insumos.
  CostoRecetaDesglosado get _desgloseCalculado => ServicioCostosReceta.componer(
    costoInsumos: _costoTotalCalculado,
    porciones: _porciones,
    tiempoElaboracionMinutos: _tiempoElaboracion,
    precioVentaCarta: _precioVenta,
    parametros: _parametros,
    // #239: mismo criterio que `_costoTotalCalculado` (el caché del insumo):
    // acá no hay base que consultar, el desglose es sobre lo que está en
    // memoria y todavía sin guardar.
    insumosSinPrecio: _ingredientesSeleccionados
        .where((ing) => (ing['insumo'] as Insumo).costoPorUnidad <= 0)
        .length,
  );

  /// Muestra una calculadora emergente para convertir de gramos/cc a la unidad del insumo.
  void _mostrarCalculadoraConversion(int index, Insumo insumo) {
    double gramos = 0.0;
    String? conversionText;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: Colors.white,
              title: Text(
                'Convertidor a ${insumo.unidad}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Insumo: ${insumo.nombre}\nUnidad base: ${insumo.unidad}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  CampoNumerico(
                    etiqueta: 'Cantidad en Gramos (g) o CC',
                    ayuda: 'Ej: 150',
                    obligatorio: false,
                    permitirCero: true,
                    decimales: FormatosEntrada.decimalesCantidad,
                    estilo: const TextStyle(color: Colors.black),
                    alCambiar: (val) {
                      final parsed = val ?? 0.0;
                      double resultado = 0.0;
                      String desc = '';

                      if (insumo.unidad == 'kg') {
                        resultado = parsed / 1000.0;
                        desc =
                            '$parsed g = ${resultado.toStringAsFixed(4)} kg (base 1kg = 1000g)';
                      } else if (insumo.unidad == 'lt') {
                        resultado = parsed / 1000.0;
                        desc =
                            '$parsed cc = ${resultado.toStringAsFixed(4)} lt (base 1lt = 1000cc)';
                      } else if (insumo.unidad == 'atado') {
                        resultado = parsed / 120.0;
                        desc =
                            '$parsed g = ${resultado.toStringAsFixed(3)} atados (promedio 1 atado = 120g)';
                      } else if (insumo.unidad == 'paq') {
                        resultado = parsed / 400.0;
                        desc =
                            '$parsed g = ${resultado.toStringAsFixed(3)} paquetes (promedio 1 paquete = 400g)';
                      } else {
                        resultado = parsed;
                        desc = '$parsed unidades';
                      }

                      setModalState(() {
                        gramos = resultado;
                        conversionText = desc;
                      });
                    },
                  ),
                  if (conversionText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      conversionText!,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: InsumaColors.primaryBlue,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (gramos > 0) {
                      // HU-153: se escribe en el controlador del campo, que es
                      // justamente lo que reemplaza a la key con el valor.
                      _fijarCantidad(index, insumo.id, gramos);
                    }
                    Navigator.pop(context);
                  },
                  child: const Text('Aplicar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final esEdicion = widget.recetaAEditar != null;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        top: 16,
        left: 20,
        right: 20,
      ),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (context, scrollController) {
          return Form(
            key: _formKey,
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
                Text(
                  esEdicion ? 'Editar Receta' : 'Nueva Receta',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 16),

                // Formulario de cabecera
                TextFormField(
                  initialValue: _nombre,
                  inputFormatters: FormatosEntrada.texto(
                    maxLongitud: SanitizadorTexto.maxLongitudNombre,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Nombre de la Receta *',
                  ),
                  style: const TextStyle(color: Colors.black),
                  validator: (v) => SanitizadorTexto.tieneContenido(v)
                      ? null
                      : 'El nombre es obligatorio',
                  // HU-137: se normaliza al guardar, así el chequeo de receta
                  // duplicada de más abajo no se saltea por un espacio de más.
                  onSaved: (v) => _nombre = SanitizadorTexto.limpiar(v),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      // Las porciones son un entero: media porción no existe.
                      child: CampoNumerico(
                        etiqueta: 'Porciones (Rinde)',
                        valorInicial: _porciones,
                        decimales: 0,
                        alGuardar: (v) => _porciones = v ?? _porciones,
                        alCambiar: (v) {
                          if (v != null && v > 0) {
                            setState(() => _porciones = v);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _categoria,
                        // #215: sin `isExpanded` el dropdown se dimensiona por
                        // su ítem más ancho e ignora el `Expanded` que lo
                        // contiene — desbordaba 19 px a 360 dp. Con esto se
                        // ajusta al ancho disponible y recorta el texto largo.
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Categoría *',
                        ),
                        items: _categoriasReceta
                            .map(
                              (c) => DropdownMenuItem(value: c, child: Text(c)),
                            )
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _categoria = v ?? 'Principal'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      // HU-019: el precio es opcional, pero si se carga debe ser > 0
                      // (es justo lo que valida CampoNumerico con obligatorio: false).
                      child: CampoNumerico(
                        etiqueta: 'Precio Venta Carta (\$)',
                        valorInicial: _precioVenta,
                        obligatorio: false,
                        alGuardar: (v) => _precioVenta = v,
                        alCambiar: (v) => setState(() => _precioVenta = v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: CampoNumerico(
                        etiqueta: 'Margen Deseado (%)',
                        valorInicial: (_margenDeseado ?? 0.30) * 100,
                        obligatorio: false,
                        permitirCero: true,
                        decimales: 0,
                        // Sin dato válido se mantiene el 30% por defecto del negocio.
                        alGuardar: (v) => _margenDeseado = (v ?? 30.0) / 100,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // HU-152: el tiempo es de la TANDA entera, no de una porción.
                // Opcional a propósito: las recetas que ya existen no lo
                // declararon, y eso NO es lo mismo que "se hace en cero minutos"
                // — por eso la columna admite null y la app avisa.
                CampoNumerico(
                  etiqueta: 'Tiempo de elaboración (min)',
                  valorInicial: _tiempoElaboracion,
                  obligatorio: false,
                  // 0 minutos es "no declarado", no un error: es exactamente lo
                  // que afirma costo_mano_de_obra_test. Sin esto, escribir 0
                  // pintaba "Debe ser mayor a 0" y bloqueaba el guardado de TODA
                  // la receta, contradiciendo al panel de abajo.
                  permitirCero: true,
                  decimales: 0,
                  sufijo: 'min',
                  ayuda: 'Cuánto lleva preparar la receta completa',
                  alGuardar: (v) => _tiempoElaboracion = v,
                  alCambiar: (v) => setState(() => _tiempoElaboracion = v),
                ),

                const Divider(height: 32),

                // Panel de costo estimado instantáneo, ABIERTO en insumos y mano
                // de obra (HU-152). El total solo no alcanza: un costo alto por
                // insumos y uno por tiempo se corrigen de maneras distintas
                // (renegociar con el proveedor vs. cambiar el proceso).
                _PanelCostoEstimado(desglose: _desgloseCalculado),
                const SizedBox(height: 16),

                // Sección de Ingredientes
                // #215: desbordaba 133 px a 360 dp. Título con SU acción, así
                // que va el patrón de #209 (Expanded + elipsis) y no el `Wrap`
                // de #180: bajar "Agregar Ingrediente" de renglón lo separaría
                // del título de la sección a la que pertenece.
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Text(
                        'Ingredientes',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.black54,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text(
                        'Agregar Ingrediente',
                        style: TextStyle(fontSize: 12),
                      ),
                      onPressed: _mostrarSeleccionadorIngredientes,
                    ),
                  ],
                ),

                if (_cargandoIngred)
                  const Center(child: CircularProgressIndicator())
                else if (_ingredientesSeleccionados.isEmpty)
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      border: Border.all(color: InsumaColors.cardBorderLight),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(
                      child: Text(
                        'No hay ingredientes. Agrega al menos uno.',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ),
                  )
                else
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _ingredientesSeleccionados.length,
                    itemBuilder: (context, idx) {
                      final item = _ingredientesSeleccionados[idx];
                      final insumo = item['insumo'] as Insumo;
                      // La cantidad ya no se lee acá: la tiene el controlador del
                      // campo (HU-153). El modelo se actualiza por `alCambiar`.
                      final merma = item['merma'] as double;

                      return Card(
                        elevation: 0,
                        color: Colors.grey[50],
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12.0,
                            vertical: 8.0,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      insumo.nombre,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    Text(
                                      'Costo base: \$${insumo.costoPorUnidad} / ${insumo.unidad}',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                flex: 3,
                                // La key incluye el valor a propósito: el conversor
                                // de unidades escribe la cantidad desde afuera y así
                                // el campo se redibuja con el resultado.
                                child: CampoNumerico(
                                  // HU-153: key ESTABLE. Antes incluía el valor,
                                  // así que cada tecla recreaba el campo y el
                                  // cursor volvía al inicio.
                                  key: ValueKey('cant_${insumo.id}'),
                                  etiqueta: 'Cant (${insumo.unidad})',
                                  controlador: _controllersCantidad[insumo.id],
                                  decimales: FormatosEntrada.decimalesCantidad,
                                  obligatorio: false,
                                  permitirCero: true,
                                  denso: true,
                                  estilo: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black87,
                                  ),
                                  iconoSufijo: IconButton(
                                    icon: const Icon(
                                      Icons.calculate_outlined,
                                      size: 16,
                                      color: Colors.blueGrey,
                                    ),
                                    tooltip: 'Conversor a ${insumo.unidad}',
                                    onPressed: () =>
                                        _mostrarCalculadoraConversion(
                                          idx,
                                          insumo,
                                        ),
                                  ),
                                  alCambiar: (v) => setState(() {
                                    _ingredientesSeleccionados[idx]['cantidad'] =
                                        v ?? 0.0;
                                  }),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 2,
                                child: CampoNumerico(
                                  etiqueta: 'Merma %',
                                  valorInicial: merma * 100,
                                  decimales: 0,
                                  obligatorio: false,
                                  permitirCero: true,
                                  denso: true,
                                  estilo: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black87,
                                  ),
                                  alCambiar: (v) => setState(() {
                                    _ingredientesSeleccionados[idx]['merma'] =
                                        (v ?? 0.0) / 100.0;
                                  }),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                  size: 20,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _controllersCantidad
                                        .remove(insumo.id)
                                        ?.dispose();
                                    _ingredientesSeleccionados.removeAt(idx);
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
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
                  onPressed: _guardarReceta,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    esEdicion ? 'Guardar Cambios' : 'Crear Receta',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Muestra el modal para buscar e incorporar un ingrediente.
  /// Incluye un trigger para crear insumos rápidamente si no se encuentran en la lista.
  void _mostrarSeleccionadorIngredientes() {
    showDialog(
      context: context,
      builder: (context) {
        String query = '';
        return StatefulBuilder(
          builder: (context, setModalState) {
            final db = Provider.of<BaseDatosApp>(context, listen: false);
            return AlertDialog(
              backgroundColor: Colors.white,
              title: const Text(
                'Agregar Ingrediente',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
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
                      onChanged: (v) => setModalState(() => query = v),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.flash_on, size: 14),
                        label: const Text(
                          'Insumo nuevo rápido',
                          style: TextStyle(fontSize: 11),
                        ),
                        onPressed: _crearInsumoDesdeSelector,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: FutureBuilder<List<Insumo>>(
                        future:
                            (db.select(db.insumos)..where(
                                  (i) =>
                                      i.negocioId.equals(widget.negocioId) &
                                      i.activo.equals(true),
                                ))
                                .get(),
                        builder: (context, snap) {
                          if (snap.connectionState == ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          if (snap.hasError) {
                            return Center(child: Text('Error: ${snap.error}'));
                          }
                          final lista = snap.data ?? [];
                          final filtrados = lista
                              .where(
                                (i) => i.nombre.toLowerCase().contains(
                                  query.toLowerCase(),
                                ),
                              )
                              .toList();

                          if (filtrados.isEmpty) {
                            return const Center(
                              child: Text(
                                'No hay insumos registrados.',
                                style: TextStyle(fontSize: 12),
                              ),
                            );
                          }

                          return ListView.builder(
                            itemCount: filtrados.length,
                            itemBuilder: (context, index) {
                              final ins = filtrados[index];
                              // Verificar si ya está seleccionado
                              final yaSeleccionado = _ingredientesSeleccionados
                                  .any(
                                    (element) =>
                                        (element['insumo'] as Insumo).id ==
                                        ins.id,
                                  );

                              return ListTile(
                                dense: true,
                                title: Text(
                                  ins.nombre,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                ),
                                subtitle: Text(
                                  'Categoría: ${ins.categoria} · Unidad: ${ins.unidad}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                trailing: yaSeleccionado
                                    ? const Icon(
                                        Icons.check,
                                        color: Colors.green,
                                      )
                                    : const Icon(Icons.add, color: Colors.grey),
                                onTap: yaSeleccionado
                                    ? null
                                    : () {
                                        setState(() {
                                          _registrarControlador(ins.id, 1.0);
                                          _ingredientesSeleccionados.add({
                                            'insumo': ins,
                                            'cantidad': 1.0,
                                            'merma': 0.0,
                                          });
                                        });
                                        Navigator.pop(context);
                                      },
                              );
                            },
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
              ],
            );
          },
        );
      },
    );
  }

  /// #239: el alta rápida desde la receta usa EL MISMO formulario que el
  /// resto de la app ([FormularioInsumoModal]). El diálogo duplicado
  /// "Creación Rápida de Insumo" se eliminó; con el formulario compartido este
  /// camino gana lo que le faltaba: proveedor obligatorio, guarda de rol
  /// (#172) y aviso de duplicados — y hereda solo cualquier cambio futuro del
  /// alta (como que el costo ya no se carga acá).
  Future<void> _crearInsumoDesdeSelector() async {
    final ctrlInsumos = context.read<ControladorInsumos>();
    // El alta exige tener los proveedores cargados (el proveedor es
    // obligatorio) — mismo preámbulo que los selectores de pedido y agenda.
    await ctrlInsumos.cargarDatos();
    if (!mounted) return;

    final creado = await FormularioInsumoModal.mostrar(context);
    if (creado == null || !mounted) return;

    setState(() {
      _registrarControlador(creado.id, 1.0);
      _ingredientesSeleccionados.add({
        'insumo': creado,
        'cantidad': 1.0,
        'merma': 0.0,
      });
    });
    // Cierra el selector de ingredientes, como hacía el camino viejo: el
    // insumo recién creado ya quedó agregado a la receta.
    Navigator.pop(context);
  }

  /// Guarda de forma atómica la receta y sus ingredientes delegando al controlador.
  Future<void> _guardarReceta() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    final ctrl = Provider.of<ControladorRecetas>(context, listen: false);

    // HU-019: aviso de nombre duplicado (no bloqueante), solo en alta o si cambió el nombre.
    final nombreCambio =
        widget.recetaAEditar == null ||
        widget.recetaAEditar!.nombre.trim().toLowerCase() !=
            _nombre.trim().toLowerCase();
    if (nombreCambio &&
        await ctrl.existeRecetaConNombre(
          _nombre,
          excluirId: widget.recetaAEditar?.id,
        )) {
      if (!mounted) return;
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
            'Ya existe una receta llamada "${_nombre.trim()}". ¿Crear de todos modos?',
            style: const TextStyle(fontSize: 13, color: Colors.black87),
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
                style: TextStyle(color: InsumaColors.primaryBlue),
              ),
            ),
          ],
        ),
      );
      if (continuar != true) return;
    }

    // HU-019: sin ingredientes se permite como borrador (incompleta, sin costeo), con aviso.
    if (_ingredientesSeleccionados.isEmpty) {
      if (!mounted) return;
      final continuar = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.white,
          title: const Text(
            'Receta sin ingredientes',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          content: const Text(
            'Se guardará como borrador (sin costeo hasta agregar ingredientes). ¿Continuar?',
            style: TextStyle(fontSize: 13, color: Colors.black87),
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
                'Guardar borrador',
                style: TextStyle(color: InsumaColors.primaryBlue),
              ),
            ),
          ],
        ),
      );
      if (continuar != true) return;
    }

    // HU-020: si hay ingredientes, cada cantidad debe ser > 0.
    if (_ingredientesSeleccionados.any(
      (it) => (it['cantidad'] as double) <= 0,
    )) {
      setState(
        () => _error =
            'Las cantidades de los ingredientes deben ser mayores a 0.',
      );
      return;
    }

    final ingMaps = _ingredientesSeleccionados.map((item) {
      final insumo = item['insumo'] as Insumo;
      return {
        'insumoId': insumo.id,
        'cantidadNeta': item['cantidad'] as double,
        'desperdicioPorcentaje': item['merma'] as double,
      };
    }).toList();

    try {
      final ok = await ctrl.guardarReceta(
        recetaAEditar: widget.recetaAEditar,
        nombre: _nombre,
        categoria: _categoria,
        porciones: _porciones,
        precioVenta: _precioVenta,
        margenDeseado: _margenDeseado,
        tiempoElaboracionMinutos: _tiempoElaboracion,
        ingredientesSeleccionados: ingMaps,
      );

      if (ok) {
        widget.alGuardar();
        if (mounted) {
          Navigator.pop(context);
        }
      } else {
        setState(() => _error = 'Error al guardar la receta.');
      }
    } catch (e) {
      setState(() => _error = 'Error al guardar la receta: $e');
    }
  }
}

/// Panel de costo estimado en vivo, abierto en insumos y mano de obra (HU-152).
///
/// Muestra los dos componentes POR SEPARADO porque un costo alto por insumos y
/// uno por tiempo se corrigen de maneras distintas —renegociar con el proveedor
/// vs. cambiar el proceso— y el total solo no permite distinguirlos.
///
/// Cuando la mano de obra da cero, el cero **no queda mudo**: se explica por qué
/// y a dónde ir a resolverlo. "Mano de obra: $0" sin aviso se lee como "no cuesta
/// nada" cuando en realidad significa "no lo cargaste".
class _PanelCostoEstimado extends StatelessWidget {
  const _PanelCostoEstimado({required this.desglose});

  final CostoRecetaDesglosado desglose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: InsumaColors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Linea(etiqueta: 'Insumos', valor: desglose.insumos),
          const SizedBox(height: 4),
          _Linea(
            etiqueta: 'Mano de obra',
            valor: desglose.manoDeObra,
            atenuado: desglose.tieneAviso,
          ),
          const Divider(height: 16),
          _Linea(
            etiqueta: 'Costo estimado',
            valor: desglose.total,
            destacado: true,
          ),
          const SizedBox(height: 4),
          _Linea(
            etiqueta: 'Por porción',
            valor: desglose.costoPorPorcion,
            destacado: true,
          ),
          if (desglose.tieneAviso) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 14, color: Colors.orange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    AvisosManoDeObra.texto(desglose.aviso),
                    style: const TextStyle(fontSize: 11, color: Colors.orange),
                  ),
                ),
              ],
            ),
          ],
          // #239: el estimado con ingredientes sin precio no pasa por real.
          if (desglose.costeoIncompleto) ...[
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
                    desglose.avisoCosteoIncompleto,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Una fila etiqueta/importe del panel.
class _Linea extends StatelessWidget {
  const _Linea({
    required this.etiqueta,
    required this.valor,
    this.destacado = false,
    this.atenuado = false,
  });

  final String etiqueta;
  final double valor;
  final bool destacado;

  /// El importe se pinta apagado cuando es un cero por falta de datos: así se
  /// distingue de un número que sí se calculó.
  final bool atenuado;

  @override
  Widget build(BuildContext context) {
    final color = atenuado
        ? Colors.grey
        : (destacado ? Colors.black87 : Colors.black54);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          etiqueta,
          style: TextStyle(
            fontSize: destacado ? 12 : 11,
            fontWeight: destacado ? FontWeight.bold : FontWeight.normal,
            color: color,
          ),
        ),
        Text(
          '\$${valor.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: destacado ? 12 : 11,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}
