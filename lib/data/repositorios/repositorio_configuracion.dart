import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../database/database.dart';
import '../../utils/dinero.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio de Configuración por negocio (HU-031).
abstract class RepositorioConfiguracion {
  Future<ConfiguracionNegocioData> obtenerOCrear(String negocioId);

  /// Lee la configuración SIN crearla si no existe. Devuelve null cuando el
  /// negocio todavía no tiene fila local.
  ///
  /// Existe porque `obtenerOCrear` tiene un efecto de ESCRITURA —inserta y
  /// encola un INSERT hacia Supabase— y hay lecturas que no pueden permitírselo:
  /// el costeo de recetas (HU-152) consulta el costo por hora para TODOS los
  /// roles, y un cocinero ni tiene permiso de escribir esta tabla (la RLS
  /// `admin_edit_configuracion` lo rechaza) ni la baja en su pull operativo.
  Future<ConfiguracionNegocioData?> obtenerSiExiste(String negocioId);
  Future<ConfiguracionNegocioData> guardar(ConfiguracionNegocioData config);
}

/// Implementación local (Drift) con encolado de sincronización.
class RepositorioConfiguracionDrift extends RepositorioSincronizable
    implements RepositorioConfiguracion {
  RepositorioConfiguracionDrift(super.db, super.sync);

  static const String _tabla = 'configuracion_negocio';

  @override
  Future<ConfiguracionNegocioData> obtenerOCrear(String negocioId) async {
    final existente = await (db.select(
      db.configuracionNegocio,
    )..where((c) => c.negocioId.equals(negocioId))).getSingleOrNull();
    if (existente != null) return existente;

    final id = const Uuid().v4();
    await db
        .into(db.configuracionNegocio)
        .insert(
          ConfiguracionNegocioCompanion.insert(
            id: id,
            negocioId: negocioId,
            fechaCreacion: Value(DateTime.now()),
            fechaActualizacion: Value(DateTime.now()),
          ),
        );
    final creada = await (db.select(
      db.configuracionNegocio,
    )..where((c) => c.id.equals(id))).getSingle();
    await encolarInsert(_tabla, id, _aMapa(creada));
    return creada;
  }

  @override
  Future<ConfiguracionNegocioData?> obtenerSiExiste(String negocioId) =>
      (db.select(
        db.configuracionNegocio,
      )..where((c) => c.negocioId.equals(negocioId))).getSingleOrNull();

  @override
  Future<ConfiguracionNegocioData> guardar(
    ConfiguracionNegocioData config,
  ) async {
    await (db.update(
      db.configuracionNegocio,
    )..where((c) => c.id.equals(config.id))).write(
      ConfiguracionNegocioCompanion(
        umbralAlertaDesviacion: Value(config.umbralAlertaDesviacion),
        moneda: Value(config.moneda),
        simboloMoneda: Value(config.simboloMoneda),
        pais: Value(config.pais),
        idioma: Value(config.idioma),
        foodcostVerdeMax: Value(config.foodcostVerdeMax),
        foodcostAmarilloMax: Value(config.foodcostAmarilloMax),
        // HU-152: sin esta línea el costo por hora se editaba en pantalla y nunca
        // se persistía — el Companion sólo escribe los campos que enumera.
        costoHoraEmpleado: Value(config.costoHoraEmpleado),
        version: Value(config.version + 1),
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    final actualizada = await (db.select(
      db.configuracionNegocio,
    )..where((c) => c.id.equals(config.id))).getSingle();
    // HU-028: la versión previa es la del argumento (ya se incrementó arriba).
    await encolarUpdate(
      _tabla,
      config.id,
      _aMapa(actualizada),
      versionBase: config.version,
    );
    return actualizada;
  }

  /// Mapeo a snake_case para Supabase.
  Map<String, dynamic> _aMapa(ConfiguracionNegocioData c) => {
    'id': c.id,
    'negocio_id': c.negocioId,
    'umbral_alerta_desviacion': c.umbralAlertaDesviacion,
    'moneda': c.moneda,
    'simbolo_moneda': c.simboloMoneda,
    'pais': c.pais,
    'idioma': c.idioma,
    'foodcost_verde_max': c.foodcostVerdeMax,
    'foodcost_amarillo_max': c.foodcostAmarilloMax,
    // HU-152: ES DINERO → viaja redondeado a 2 decimales (HU-081), y null
    // se preserva como null: es "sin configurar", no cero.
    'costo_hora_empleado': c.costoHoraEmpleado == null
        ? null
        : Dinero.redondear(c.costoHoraEmpleado!),
    'version': c.version,
  };
}
