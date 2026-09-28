import '../data/repositorios/repositorio_configuracion.dart';
import '../database/database.dart';
import '../utils/calculadora_costos.dart';

/// Parámetros del negocio que entran en el costeo de una receta (#197).
///
/// Viajan JUNTOS y no de a uno porque salen de la misma fila: pedirlos por
/// separado serían tres consultas —o tres formas distintas de resolver el caso
/// "el negocio no configuró nada"— para responder lo mismo.
class ParametrosCosteo {
  const ParametrosCosteo({
    required this.costoHoraEmpleado,
    required this.verdeMax,
    required this.amarilloMax,
  });

  /// Costo de la hora de trabajo (HU-152). `null` = sin configurar, que es
  /// DISTINTO de cero: con null la app avisa por qué la mano de obra dio 0.
  final double? costoHoraEmpleado;

  /// Umbrales del semáforo de FoodCost. Nunca null: las columnas son NOT NULL
  /// con default, y sin fila se usan los de [CalculadoraCostos].
  final double verdeMax;
  final double amarilloMax;

  /// Lo que aplica a un negocio que todavía no configuró nada.
  static const sinConfigurar = ParametrosCosteo(
    costoHoraEmpleado: null,
    verdeMax: CalculadoraCostos.umbralVerdePorDefecto,
    amarilloMax: CalculadoraCostos.umbralAmarilloPorDefecto,
  );

  /// Construye los parámetros validando el par de umbrales, y cayendo a los
  /// defaults si no tiene sentido.
  ///
  /// Los umbrales son FRACCIONES (0,30 = 30%) y tienen que cumplir
  /// `0 < verde <= amarillo <= 1`. Sin este chequeo, un par inválido no falla:
  /// pinta mal en silencio, que es peor. Los dos casos concretos:
  ///  - alguien guarda `30` y `35` en vez de `0,30` y `0,35` (la pantalla para
  ///    editarlos todavía no existe, así que el formato aún no está fijado por
  ///    ninguna UI) → TODA receta queda en verde para siempre;
  ///  - un `0` que se cuela por cualquier vía → TODA receta queda en rojo.
  /// En los dos casos el semáforo deja de informar y nadie se entera.
  ///
  /// `verde == amarillo` se acepta: es un negocio que no quiere zona amarilla.
  factory ParametrosCosteo.validando({
    required double? costoHoraEmpleado,
    required double verdeMax,
    required double amarilloMax,
  }) {
    final coherentes =
        verdeMax > 0 && verdeMax <= amarilloMax && amarilloMax <= 1.0;
    return ParametrosCosteo(
      costoHoraEmpleado: costoHoraEmpleado,
      verdeMax: coherentes ? verdeMax : CalculadoraCostos.umbralVerdePorDefecto,
      amarilloMax: coherentes
          ? amarilloMax
          : CalculadoraCostos.umbralAmarilloPorDefecto,
    );
  }
}

/// Servicio de configuración por negocio (HU-031): umbral de alerta, moneda y
/// umbrales del semáforo de FoodCost.
///
/// **Sin caché en memoria, a propósito (#203).** La tenía, y sólo se refrescaba
/// al guardar en ESTE dispositivo: nada la invalidaba cuando el pull traía una
/// fila más nueva —`invalidar()` existía pero no lo llamaba nadie—, así que la
/// app seguía usando los valores viejos hasta reiniciarse. Lo que ahorraba era
/// un SELECT por id sobre una tabla local de una sola fila; lo que costaba era
/// que la pantalla de configuración mostrara un valor viejo y, al guardar,
/// pisara en silencio el cambio hecho en otro equipo.
class ServicioConfiguracionNegocio {
  final RepositorioConfiguracion _repo;

  ServicioConfiguracionNegocio(this._repo);

  /// Devuelve la configuración del negocio, **creándola si no existe**.
  ///
  /// Tiene efecto de ESCRITURA: `obtenerOCrear` inserta y encola un INSERT hacia
  /// Supabase. Por eso es sólo para la pantalla que administra la configuración,
  /// donde el usuario ya es admin. Cualquier LECTURA usa [parametrosCosteo] o
  /// [umbralAlerta], que no crean nada.
  Future<ConfiguracionNegocioData> obtener(String negocioId) =>
      _repo.obtenerOCrear(negocioId);

  /// La fila completa SIN crearla. `null` = el negocio todavía no tiene una.
  ///
  /// Es lo que usa la pantalla para MOSTRAR. Abrir una pantalla no puede dar de
  /// alta una fila: `obtenerOCrear` acuña un uuid del lado del cliente, y si el
  /// servidor ya tiene la suya sin haberse bajado todavía (instalación nueva,
  /// offline, un primer pull que falló) las dos chocan contra el UNIQUE de
  /// `negocio_id` — el push muere y, peor, el pull queda trabado para siempre
  /// contra ese índice. Que la fila nazca sólo cuando el usuario decide guardar
  /// achica esa ventana a un acto deliberado.
  Future<ConfiguracionNegocioData?> leer(String negocioId) =>
      _repo.obtenerSiExiste(negocioId);

  /// Parámetros del negocio para costear una receta: costo por hora (HU-152) y
  /// umbrales del semáforo de FoodCost (#197).
  ///
  /// Usa [RepositorioConfiguracion.obtenerSiExiste] y NO [obtener]: esto lo
  /// consulta el costeo de recetas para CUALQUIER rol, y `obtener` crearía la
  /// fila y encolaría un INSERT que la RLS le rechaza al cocinero — dejando
  /// además una fila fantasma con un id distinto del que tiene el servidor.
  ///
  Future<ParametrosCosteo> parametrosCosteo(String negocioId) async {
    final config = await _repo.obtenerSiExiste(negocioId);
    if (config == null) return ParametrosCosteo.sinConfigurar;
    return ParametrosCosteo.validando(
      costoHoraEmpleado: config.costoHoraEmpleado,
      verdeMax: config.foodcostVerdeMax,
      amarilloMax: config.foodcostAmarilloMax,
    );
  }

  /// Umbral de variación de precio para generar alerta (HU-018), por defecto 10%.
  ///
  /// Lee SIN crear la fila (#203). Antes pasaba por `obtener`, o sea por
  /// `obtenerOCrear`, y esto lo llama `ServicioRecepciones.registrar` — que NO
  /// está gateado por rol, porque recepcionar mercadería es tarea del cocinero.
  /// Resultado: un cocinero recepcionando insertaba una fila de configuración y
  /// encolaba un INSERT que la policy `admin_edit_configuracion` le rechaza
  /// (`current_user_rol() = 'admin'`), y encima con un id propio distinto del
  /// que tiene el servidor — y como `negocio_id` es UNIQUE, el día que a ese
  /// usuario lo asciendan a admin el pull choca contra ese índice.
  ///
  /// ⚠️ Sin fila devuelve el default, y en un dispositivo de COCINERO eso es
  /// permanente: el pull operativo no baja `configuracion_negocio` (vive dentro
  /// del bloque `if (!soloOp)` de `servicio_descarga_negocio`, porque la RLS de
  /// las tablas financieras es admin-only, HU-044). O sea que un negocio que
  /// configuró su umbral en 25% igual dispara las alertas de recepción al 10%
  /// en cada equipo de cocina. NO es una regresión —con la fila fantasma que se
  /// creaba antes pasaba lo mismo, porque nacía con el default— pero sí un
  /// hueco funcional de HU-018 que este arreglo hace explícito. Va aparte.
  Future<double> umbralAlerta(String negocioId) async =>
      (await _repo.obtenerSiExiste(negocioId))?.umbralAlertaDesviacion ??
      umbralAlertaPorDefecto;

  /// Default de la columna `umbral_alerta_desviacion` (HU-018): 10%.
  ///
  /// Referenciada desde el `withDefault` de la columna y desde el fallback del
  /// pull, para que el camino "sin fila" y el camino "con fila" no puedan
  /// divergir sin que nada falle. Mismo criterio que los umbrales del semáforo
  /// en [CalculadoraCostos] — y con la misma advertencia: está CONGELADA por el
  /// esquema (el baseline de Supabase y el DDL de cada SQLite ya instalado
  /// tienen su propia copia), así que cambiar el número exige migración.
  static const double umbralAlertaPorDefecto = 0.10;

  Future<ConfiguracionNegocioData> guardar(ConfiguracionNegocioData config) =>
      _repo.guardar(config);
}
