import 'package:flutter/material.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:uuid/uuid.dart';
import '../database/database.dart';
import '../services/servicio_permisos.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_sincronizacion_supabase.dart';
import '../services/servicio_descarga_negocio.dart';
import '../data/mapeadores_supabase.dart';
import '../services/servicio_costos_receta.dart';

/// Controlador encargado de gestionar el estado y la lógica de negocio
/// del catálogo de Recetas y fórmulas de INSUMA (Patrón MVC).
class ControladorRecetas extends ChangeNotifier {
  final ServicioSesion sesion;
  final BaseDatosApp _db;
  final ServicioSincronizacionSupabase? _sync;
  final ServicioDescargaNegocio? _descarga;

  /// HU-152: resuelve el costo CON mano de obra. El controlador ya no le pide
  /// el costo al DAO directamente: el DAO sólo sabe de insumos.
  final ServicioCostosReceta _costos;

  ControladorRecetas(
    this.sesion,
    this._db,
    this._costos, [
    this._sync,
    this._descarga,
  ]) {
    // Recargar si cambia el rol efectivo (elevación por PIN de HU-043 o su
    // re-bloqueo), para mostrar u ocultar las columnas de costo/margen.
    sesion.addListener(_reaccionarAElevacion);
  }

  void _reaccionarAElevacion() {
    if (sesion.usuarioRol != _usuarioRol) cargarDatos();
  }

  @override
  void dispose() {
    sesion.removeListener(_reaccionarAElevacion);
    super.dispose();
  }

  List<Receta> _recetas = [];
  List<Insumo> _insumosDisponibles = [];
  List<Proveedore> _proveedoresDisponibles = [];
  bool _cargando = true;
  String _busqueda = '';
  String _categoriaSeleccionada = 'Todos';
  bool _mostrarArchivadas = false;
  String _negocioId = '';
  String _usuarioRol = 'cocinero';

  // Caché local para evitar recalcular costos recurrentemente en la UI
  final Map<String, CostoRecetaDesglosado> _costosCache = {};

  // Getters para exponer a la Vista
  List<Receta> get recetas => _recetas;
  List<Insumo> get insumosDisponibles => _insumosDisponibles;
  List<Proveedore> get proveedoresDisponibles => _proveedoresDisponibles;
  bool get cargando => _cargando;
  String get busqueda => _busqueda;
  String get categoriaSeleccionada => _categoriaSeleccionada;
  bool get mostrarArchivadas => _mostrarArchivadas;
  String get negocioId => _negocioId;
  String get usuarioRol => _usuarioRol;
  Map<String, CostoRecetaDesglosado> get costosCache => _costosCache;

  /// HU-022: las recetas archivadas (inactivas) son gestión del catálogo, no
  /// parte del recetario OPERATIVO. Solo quien gestiona recetas puede listarlas;
  /// para el cocinero el filtro es fail-closed (nunca las ve, aunque el flag
  /// quedara prendido por un cambio de rol).
  bool get puedeVerArchivadas =>
      Permisos.puede(_usuarioRol, Permiso.gestionarRecetas);

  List<Receta> get recetasFiltradas {
    final verArchivadas = _mostrarArchivadas && puedeVerArchivadas;
    return _recetas.where((r) {
      final coincideBusqueda = r.nombre.toLowerCase().contains(
        _busqueda.toLowerCase(),
      );
      final coincideCategoria =
          _categoriaSeleccionada == 'Todos' ||
          r.categoria == _categoriaSeleccionada;
      final coincideArchivo = r.archivada == verArchivadas;
      return coincideBusqueda && coincideCategoria && coincideArchivo;
    }).toList();
  }

  void actualizarBusqueda(String valor) {
    _busqueda = valor;
    notifyListeners();
  }

  void actualizarCategoriaSeleccionada(String valor) {
    _categoriaSeleccionada = valor;
    notifyListeners();
  }

  Future<void> conmutarMostrarArchivadas(bool valor) async {
    // HU-022: sin permiso de gestión no se puede activar el listado de archivadas.
    if (valor && !puedeVerArchivadas) return;
    _mostrarArchivadas = valor;
    _cargando = true;
    notifyListeners();
    await cargarDatos();
  }

  /// Carga recetas, insumos y proveedores de la base de datos local
  Future<void> cargarDatos() async {
    final negocioId = sesion.negocioId;
    if (negocioId.isEmpty) return;

    final usuarioRol = sesion.usuarioRol;

    // Cargar recetas
    final listaRecetas = await (_db.select(
      _db.recetas,
    )..where((r) => r.negocioId.equals(negocioId))).get();

    // Cargar insumos
    final listaInsumos =
        await (_db.select(_db.insumos)..where(
              (i) => i.negocioId.equals(negocioId) & i.activo.equals(true),
            ))
            .get();

    // Cargar proveedores
    final listaProveedores =
        await (_db.select(_db.proveedores)..where(
              (p) => p.negocioId.equals(negocioId) & p.activo.equals(true),
            ))
            .get();

    _negocioId = negocioId;
    _usuarioRol = usuarioRol;
    _recetas = listaRecetas;
    _insumosDisponibles = listaInsumos;
    _proveedoresDisponibles = listaProveedores;

    // Calcular costos de recetas y cachearlos
    await calcularCostosRecetas();

    _cargando = false;
    notifyListeners();
  }

  /// Recarga (pull) los datos del negocio desde Supabase y refresca el catálogo
  /// local. Para el botón de recarga: trae lo cargado por otros dispositivos del
  /// negocio. Offline-first: si falla la descarga, igual recarga lo local.
  Future<void> recargarDesdeLaNube() async {
    final negocioId = sesion.negocioId;
    if (_descarga != null && negocioId.isNotEmpty) {
      try {
        await _descarga.descargarNegocio(negocioId);
      } catch (_) {
        /* sin conexión: se muestra lo local */
      }
    }
    await cargarDatos();
  }

  /// Calcula y cachea de forma reactiva el costo a fecha de hoy de todas las recetas
  Future<void> calcularCostosRecetas() async {
    _costosCache.clear();
    final hoy = DateTime.now();
    for (final receta in _recetas) {
      final costoObj = await _costos.desglosar(receta, fecha: hoy);
      _costosCache[receta.id] = costoObj;
    }
  }

  /// Alterna el estado archivada de una receta.
  Future<void> archivarReceta(Receta receta) async {
    final nuevoValor = !receta.archivada;
    await (_db.update(_db.recetas)..where((r) => r.id.equals(receta.id))).write(
      RecetasCompanion(
        archivada: Value(nuevoValor),
        version: Value(receta.version + 1), // HU-028
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    await _sync?.encolarMutacion(
      nombreTabla: 'recetas',
      registroId: receta.id,
      accion: 'UPDATE',
      datos: {'id': receta.id, 'archivada': nuevoValor},
      versionBase: receta.version,
    );
    await cargarDatos();
  }

  // #239: `crearInsumoEnCaliente` se ELIMINÓ. El alta rápida desde recetas
  // pasa a usar `FormularioInsumoModal` como los otros tres caminos: un solo
  // formulario, un solo comportamiento (proveedor obligatorio, guarda de rol
  // #172, aviso de duplicados). Este método además evadía todo eso y escribía
  // insumos sueltos directo contra la base.

  /// Indica si ya existe una receta con ese [nombre] en el negocio (sin distinguir
  /// mayúsculas), excluyendo opcionalmente [excluirId] (para edición). HU-019.
  Future<bool> existeRecetaConNombre(String nombre, {String? excluirId}) async {
    final objetivo = nombre.trim().toLowerCase();
    final recetas = await (_db.select(
      _db.recetas,
    )..where((r) => r.negocioId.equals(_negocioId))).get();
    return recetas.any(
      (r) => r.id != excluirId && r.nombre.trim().toLowerCase() == objetivo,
    );
  }

  /// Crea o edita una receta y sus ingredientes asociados dentro de una transacción Drift.
  Future<bool> guardarReceta({
    required Receta? recetaAEditar,
    required String nombre,
    required String categoria,
    required double porciones,
    required double? precioVenta,
    required double? margenDeseado,
    required double? tiempoElaboracionMinutos,
    required List<Map<String, dynamic>> ingredientesSeleccionados,
  }) async {
    try {
      final uuid = const Uuid();
      final esNuevo = recetaAEditar == null;
      final recetaId = recetaAEditar?.id ?? uuid.v4();

      // Capturamos los ingredientes previos (para encolar sus DELETE al sincronizar).
      final viejosIngredientes = esNuevo
          ? <RecetaIngrediente>[]
          : await (_db.select(
              _db.recetaIngredientes,
            )..where((ri) => ri.recetaId.equals(recetaId))).get();

      await _db.transaction(() async {
        // 1. Inserción o actualización de la receta principal
        if (esNuevo) {
          await _db
              .into(_db.recetas)
              .insert(
                RecetasCompanion.insert(
                  id: recetaId,
                  negocioId: _negocioId,
                  nombre: nombre.trim(),
                  porciones: Value(porciones),
                  precioVentaCarta: Value(precioVenta),
                  margenDeseadoPorcentaje: Value(margenDeseado),
                  // HU-152: null = la receta no declara tiempo, distinto de cero.
                  tiempoElaboracionMinutos: Value(tiempoElaboracionMinutos),
                  categoria: Value(categoria),
                  archivada: const Value(false),
                  fechaCreacion: Value(DateTime.now()),
                ),
              );
        } else {
          await (_db.update(
            _db.recetas,
          )..where((r) => r.id.equals(recetaId))).write(
            RecetasCompanion(
              nombre: Value(nombre.trim()),
              porciones: Value(porciones),
              precioVentaCarta: Value(precioVenta),
              margenDeseadoPorcentaje: Value(margenDeseado),
              tiempoElaboracionMinutos: Value(tiempoElaboracionMinutos),
              categoria: Value(categoria),
              estadoSync: const Value('pendiente'),
              fechaActualizacion: Value(DateTime.now()),
            ),
          );
          // Eliminar ingredientes antiguos para re-escribir
          await (_db.delete(
            _db.recetaIngredientes,
          )..where((ri) => ri.recetaId.equals(recetaId))).go();
        }

        // 2. Registrar nuevos ingredientes
        for (final ing in ingredientesSeleccionados) {
          await _db
              .into(_db.recetaIngredientes)
              .insert(
                RecetaIngredientesCompanion.insert(
                  id: uuid.v4(),
                  negocioId: _negocioId,
                  recetaId: recetaId,
                  insumoId: ing['insumoId'] as String,
                  cantidadNeta: (ing['cantidadNeta'] as num).toDouble(),
                  unidadCantidad: Value(ing['unidadCantidad'] as String?),
                  // La columna es NOT NULL con default 0.0: si el mapa no
                  // trae el dato, se deja ausente y decide la base, en vez
                  // de repetir el 0.0 acá y que queden dos fuentes.
                  desperdicioPorcentaje: switch (ing['desperdicioPorcentaje']) {
                    final num n => Value(n.toDouble()),
                    _ => const Value.absent(),
                  },
                ),
              );
        }
      });

      // 3. Encolar sincronización DESPUÉS de confirmar la transacción.
      final recetaRow = await (_db.select(
        _db.recetas,
      )..where((r) => r.id.equals(recetaId))).getSingle();
      await _sync?.encolarMutacion(
        nombreTabla: 'recetas',
        registroId: recetaId,
        accion: esNuevo ? 'INSERT' : 'UPDATE',
        datos: MapeadoresSupabase.receta(recetaRow),
      );
      for (final viejo in viejosIngredientes) {
        await _sync?.encolarMutacion(
          nombreTabla: 'receta_ingredientes',
          registroId: viejo.id,
          accion: 'DELETE',
          datos: {'id': viejo.id},
        );
      }
      final nuevosIngredientes = await (_db.select(
        _db.recetaIngredientes,
      )..where((ri) => ri.recetaId.equals(recetaId))).get();
      for (final nuevo in nuevosIngredientes) {
        await _sync?.encolarMutacion(
          nombreTabla: 'receta_ingredientes',
          registroId: nuevo.id,
          accion: 'INSERT',
          datos: MapeadoresSupabase.recetaIngrediente(nuevo),
        );
      }

      await cargarDatos();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Recupera ingredientes e insumos asociados a una receta (para fichas de detalle)
  Future<List<Map<String, dynamic>>> obtenerIngredientesConInsumo(
    String recetaId,
  ) async {
    final filas = await (_db.select(_db.recetaIngredientes).join([
      innerJoin(
        _db.insumos,
        _db.insumos.id.equalsExp(_db.recetaIngredientes.insumoId),
      ),
    ])..where(_db.recetaIngredientes.recetaId.equals(recetaId))).get();

    return filas.map((f) {
      final ing = f.readTable(_db.recetaIngredientes);
      final ins = f.readTable(_db.insumos);
      return {'ingrediente': ing, 'insumo': ins};
    }).toList();
  }
}
