import '../database/database.dart';
import '../utils/calculadora_costos.dart';
import 'servicio_configuracion_negocio.dart';

/// Costo de una receta ya resuelto: abierto en insumos y mano de obra, y
/// bajado a la unidad con la que se toman las decisiones (la porción).
///
/// Existe como DTO propio y no como un `Map` porque el aviso viaja PEGADO al
/// número: quien muestra un costo tiene que poder decir por qué la mano de obra
/// dio cero sin volver a consultar nada.
class CostoRecetaDesglosado {
  const CostoRecetaDesglosado({
    required this.insumos,
    required this.manoDeObra,
    required this.porciones,
    required this.insumosPorPorcion,
    required this.manoDeObraPorPorcion,
    required this.aviso,
    required this.foodCost,
    this.insumosSinPrecio = 0,
  });

  /// #239: ingredientes que quedaron fuera de [insumos] por no tener precio
  /// todavía. Desde que el alta de insumo no pide costo, una receta puede
  /// costear con huecos hasta la primera recepción — y eso NO debe pasar por
  /// un costo real.
  final int insumosSinPrecio;

  /// ¿El costo está contado con ingredientes de menos?
  bool get costeoIncompleto => insumosSinPrecio > 0;

  /// Texto del aviso, junto al flag para que las tres pantallas que lo
  /// muestran digan LO MISMO.
  String get avisoCosteoIncompleto =>
      'Costeo incompleto: $insumosSinPrecio ingrediente(s) sin precio '
      'todavía. El costo real es más alto.';

  /// Costo de los insumos de la receta ENTERA (la tanda).
  final double insumos;

  /// Costo del trabajo de elaborar la receta ENTERA.
  final double manoDeObra;

  /// Porciones que rinde, ya normalizada a un valor usable (nunca <= 0).
  final double porciones;

  final double insumosPorPorcion;
  final double manoDeObraPorPorcion;

  /// Por qué la mano de obra dio cero, cuando dio cero.
  final AvisoManoDeObra aviso;

  /// FoodCost y semáforo YA calculados, sobre [costoPorPorcion] (o sea con la
  /// mano de obra incluida) y con los umbrales que configuró el negocio.
  ///
  /// Viene resuelto de acá y no lo calcula la pantalla a propósito (#197): el
  /// bug que este campo cierra fue justamente que el listado llamaba a
  /// `calcularFoodCost` sin pasarle los umbrales y se comía los defaults del
  /// método. Con el semáforo ya resuelto, ningún call site futuro puede volver a
  /// olvidarse de ellos — no hay parámetro que olvidar.
  final ResultadoFoodCost foodCost;

  /// Costo de la tanda completa: insumos + trabajo.
  double get total => insumos + manoDeObra;

  /// El número que se compara contra el precio de carta (HU-021). Incluye la
  /// mano de obra: ése es el cambio central de HU-152.
  double get costoPorPorcion => insumosPorPorcion + manoDeObraPorPorcion;

  /// ¿Hay algo que avisarle al usuario sobre este número?
  bool get tieneAviso => aviso != AvisoManoDeObra.ninguno;
}

/// Resuelve el costo de una receta INCLUYENDO la mano de obra (HU-152).
///
/// Es la capa que compone tres piezas que ya existían y que ninguna sabía de las
/// otras:
///  - [BaseDatosApp.obtenerCostoRecetaAFecha] → el costo de los insumos a una
///    fecha, con precios históricos y merma. El DAO **no se tocó**: sigue sin
///    saber que la mano de obra existe.
///  - [ServicioConfiguracionNegocio] → los parámetros del negocio (costo por
///    hora y umbrales del semáforo), leídos SIN crear la fila.
///  - [CalculadoraCostos.desglosarCostoReceta] → la regla pura y su aviso.
///
/// Vive en la capa de servicios y no en el DAO porque leer la configuración del
/// negocio para decidir un costo es lógica de negocio, no acceso a datos.
class ServicioCostosReceta {
  ServicioCostosReceta(this._db, this._config);

  final BaseDatosApp _db;
  final ServicioConfiguracionNegocio _config;

  /// Desglosa el costo de [receta] a [fecha] (por defecto, hoy).
  ///
  /// Toma la [Receta] ya cargada en vez de un id porque todos los llamadores
  /// (listado, métricas) están iterando sobre objetos que ya tienen en memoria:
  /// pedir el id obligaría a releer de la base una fila que ya está a mano.
  Future<CostoRecetaDesglosado> desglosar(
    Receta receta, {
    DateTime? fecha,
  }) async {
    final costoInsumos = await _db.obtenerCostoRecetaAFecha(
      receta.id,
      fecha ?? DateTime.now(),
    );
    // `parametrosCosteo` y no `obtener`: esta lectura corre para TODOS los
    // roles y no puede crear la fila de configuración como efecto colateral.
    final parametros = await _config.parametrosCosteo(receta.negocioId);

    return componer(
      costoInsumos: costoInsumos.costoTotal,
      porciones: receta.porciones,
      tiempoElaboracionMinutos: receta.tiempoElaboracionMinutos,
      precioVentaCarta: receta.precioVentaCarta,
      parametros: parametros,
      insumosSinPrecio: costoInsumos.insumosSinPrecio,
    );
  }

  /// Composición PURA, sin base de datos ni configuración.
  ///
  /// Separada de [desglosar] porque el formulario de receta calcula el costo "en
  /// caliente" sobre ingredientes que todavía no se guardaron: necesita la misma
  /// regla sin poder consultar la base. Sin este método el modal terminaría
  /// reimplementando la división por porciones, que es justo donde está el error
  /// fácil de cometer.
  ///
  /// **La mano de obra se divide por porciones igual que los insumos.** El tiempo
  /// declarado es el de la TANDA entera, pero el FoodCost se compara contra el
  /// precio de carta de UNA porción. Sumar la mano de obra sin dividir haría que
  /// una receta que rinde 10 porciones cargue 10 veces su costo de trabajo, y el
  /// semáforo se iría a rojo por un error de escala, no por un problema real.
  static CostoRecetaDesglosado componer({
    required double costoInsumos,
    required double porciones,
    required double? tiempoElaboracionMinutos,
    required double? precioVentaCarta,
    required ParametrosCosteo parametros,
    int insumosSinPrecio = 0,
  }) {
    final desglose = CalculadoraCostos.desglosarCostoReceta(
      costoInsumos: costoInsumos,
      tiempoElaboracionMinutos: tiempoElaboracionMinutos,
      costoHoraEmpleado: parametros.costoHoraEmpleado,
    );

    // Mismo criterio que el DAO (`obtenerCostoRecetaAFecha`): una receta con 0
    // porciones se trata como si rindiera 1. Devolver 0 escondería el costo y la
    // receta parecería gratis, que es peor que mostrarla como una sola porción.
    final porcionesSeguras = porciones <= 0 ? 1.0 : porciones;

    final insumosPorPorcion = CalculadoraCostos.costoPorPorcion(
      costoTotal: desglose.insumos,
      porciones: porcionesSeguras,
    );
    final manoDeObraPorPorcion = CalculadoraCostos.costoPorPorcion(
      costoTotal: desglose.manoDeObra,
      porciones: porcionesSeguras,
    );

    return CostoRecetaDesglosado(
      insumos: desglose.insumos,
      manoDeObra: desglose.manoDeObra,
      porciones: porcionesSeguras,
      insumosPorPorcion: insumosPorPorcion,
      manoDeObraPorPorcion: manoDeObraPorPorcion,
      aviso: desglose.aviso,
      insumosSinPrecio: insumosSinPrecio,
      // El FoodCost sale del costo CON mano de obra (HU-152) y con los umbrales
      // del negocio (#197). Sin precio de carta, `calcularFoodCost` ya devuelve
      // `indefinido`, así que ese caso no necesita tratamiento aparte.
      foodCost: CalculadoraCostos.calcularFoodCost(
        costoPorPorcion: insumosPorPorcion + manoDeObraPorPorcion,
        precioVenta: precioVentaCarta ?? 0.0,
        verdeMax: parametros.verdeMax,
        amarilloMax: parametros.amarilloMax,
      ),
    );
  }
}
