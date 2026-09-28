import 'package:flutter/material.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:uuid/uuid.dart';
import '../database/database.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_sincronizacion_supabase.dart';
import '../services/servicio_precios.dart';
import '../services/servicio_descarga_negocio.dart';
import '../data/mapeadores_supabase.dart';
import '../data/repositorios/repositorio_auditoria.dart';
import '../services/servicio_permisos.dart';

/// Controlador del catálogo de Insumos (HU-003/004/005), separado de
/// [ControladorRecetas] para aislar la lógica de negocio del insumo
/// (alta, edición, baja lógica y detección de duplicados) — Patrón MVC.
///
/// #262: el insumo ya no cuelga de un proveedor. Pertenece a una **Categoría**
/// (entidad de primera clase); el alta exige `categoriaId`, no un proveedor.
class ControladorInsumos extends ChangeNotifier {
  final ServicioSesion sesion;
  final BaseDatosApp _db;
  final ServicioSincronizacionSupabase? _sync;
  final ServicioPrecios? _precios;
  final RepositorioAuditoria? _auditoria;
  final ServicioDescargaNegocio? _descarga;

  ControladorInsumos(
    this.sesion,
    this._db, [
    this._sync,
    this._precios,
    this._auditoria,
    this._descarga,
  ]);

  /// Recarga (pull) los datos del negocio desde Supabase y refresca la lista local.
  /// Pensado para el botón de recarga de la pantalla: trae lo cargado por otros
  /// dispositivos del negocio. Offline-first: si falla la descarga, igual recarga
  /// lo local.
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

  List<Insumo> _insumos = [];
  bool _cargando = true;
  String _negocioId = '';

  // Getters para la Vista.
  List<Insumo> get insumosDisponibles => _insumos;
  bool get cargando => _cargando;
  String get negocioId => _negocioId;

  /// Carga los insumos del negocio.
  ///
  /// Trae ACTIVOS E INACTIVOS (HU-006): el filtro de estado de la pantalla
  /// necesita los dados de baja en memoria para poder ofrecerlos, y traerlos con
  /// una consulta aparte sólo cuando se piden agregaría un camino más. La
  /// pantalla sigue mostrando únicamente los activos por defecto.
  Future<void> cargarDatos() async {
    final negocioId = sesion.negocioId;
    if (negocioId.isEmpty) return;

    final listaInsumos = await (_db.select(
      _db.insumos,
    )..where((i) => i.negocioId.equals(negocioId))).get();

    _negocioId = negocioId;
    _insumos = listaInsumos;
    _cargando = false;
    notifyListeners();
  }

  /// Detecta un posible duplicado: mismo negocio + nombre (case/espacios-insensible)
  /// + misma unidad. Es una advertencia NO bloqueante (HU-003); la confirmación
  /// final es responsabilidad de la UI. [excluirId] permite ignorar el propio
  /// registro al editar.
  bool existeInsumoDuplicado(
    String nombre,
    String unidad, {
    String? excluirId,
  }) {
    final objetivo = nombre.trim().toLowerCase();
    return _insumos.any(
      (i) =>
          // Sólo contra los ACTIVOS, explícitamente: desde HU-006 la lista incluye
          // los dados de baja, y advertir por un duplicado que ya no se usa sería
          // un cambio de comportamiento que nadie pidió.
          i.activo &&
          i.id != excluirId &&
          i.nombre.trim().toLowerCase() == objetivo &&
          i.unidad == unidad,
    );
  }

  /// HU-060: el rol de la sesión puede ver costos, márgenes e historial de precios.
  bool get puedeVerFinanzas =>
      Permisos.puede(sesion.usuarioRol, Permiso.verFinanzas);

  /// Política de autorización del ALTA de insumos, en forma PURA.
  ///
  /// Exige AMBOS permisos y no sólo [Permiso.gestionarRecetas], porque el alta
  /// de un insumo es también una operación FINANCIERA: el costo es obligatorio
  /// (`costo > 0`) y se escribe en `historial_precios`, que es la fuente de
  /// verdad del FoodCost. Un rol que no puede ver costos no puede cargar uno
  /// válido, y dejarlo crear con costo 0 metería un precio falso en el costeo
  /// de toda receta que use ese insumo — peor que negarle el alta.
  ///
  /// Se expone como función pura, y no sólo como getter, para que los tests
  /// puedan ejercitar la combinación que HOY ningún rol tiene —gestionar sin
  /// ver finanzas— que es justamente la que motiva el AND. Yendo por el rol,
  /// borrar el `&&` dejaría la suite igual de verde.
  static bool politicaAltaInsumo({
    required bool gestionaRecetas,
    required bool veFinanzas,
  }) => gestionaRecetas && veFinanzas;

  /// Indica si el rol de la sesión puede dar de alta un insumo.
  bool get puedeCrearInsumos => politicaAltaInsumo(
    gestionaRecetas: Permisos.puede(
      sesion.usuarioRol,
      Permiso.gestionarRecetas,
    ),
    veFinanzas: puedeVerFinanzas,
  );

  /// Crea un insumo desde cero (HU-003). La CATEGORÍA es obligatoria (#262).
  ///
  /// Aplica las validaciones de la HU (nombre obligatorio, costo > 0), persiste
  /// en local, encola el INSERT para Supabase (Outbox), registra el precio
  /// inicial en `historial_precios` (fuente de verdad) y deja traza de auditoría.
  /// La detección de duplicados es responsabilidad de la UI (ver
  /// [existeInsumoDuplicado]): aquí no se bloquea por nombre repetido.
  ///
  /// La autorización se valida ACÁ y no sólo en la UI (#172): este método tiene
  /// tres puntos de entrada —el catálogo, la ficha del proveedor y el armado del
  /// pedido (HU-139)— y basta que uno olvide la guarda para que el permiso se
  /// evada por completo. Delega la decisión en [Permisos], única fuente de
  /// verdad del RBAC.
  ///
  /// Desde #239 el alta NO recibe costo: un insumo nace a $0 y su precio entra
  /// por la primera recepción procesada, o a mano por la EDICIÓN (asiento
  /// 'ajuste_manual') o el precio de lista de la ficha (HU-138). Dos
  /// consecuencias deliberadas, decididas con el PO:
  ///  - las recetas que lo usen marcan "costeo incompleto" hasta esa primera
  ///    compra (la red se construyó ANTES de quitar el campo);
  ///  - la PRIMERA alerta de desviación rige recién desde la SEGUNDA compra:
  ///    ya no hay precio sembrado contra el que comparar la primera.
  ///
  /// (El viejo `ControladorRecetas.crearInsumoEnCaliente`, que evadía estas
  /// guardas, se eliminó también con #239: todos los caminos de alta pasan por
  /// acá vía `FormularioInsumoModal`. [actualizarInsumo] y [eliminarInsumo]
  /// siguen con su guarda solo en UI — #173.)
  Future<ResultadoCrearInsumo> crearInsumo({
    required String nombre,
    required String categoria,
    required String categoriaId,
    required String tipo,
    required String unidad,
  }) async {
    if (!puedeCrearInsumos) {
      return ResultadoCrearInsumo.error(
        'Tu rol no tiene permiso para crear insumos.',
      );
    }

    final nombreLimpio = nombre.trim();
    if (nombreLimpio.isEmpty) {
      return ResultadoCrearInsumo.error('El nombre del insumo es obligatorio.');
    }
    if (categoriaId.trim().isEmpty) {
      return ResultadoCrearInsumo.error('Debe seleccionar una categoría.');
    }

    final negocioId = sesion.negocioId;
    if (negocioId.isEmpty) {
      return ResultadoCrearInsumo.error(
        'No hay un negocio activo en la sesión.',
      );
    }

    try {
      final nuevoId = const Uuid().v4();
      final usuarioId = sesion.usuarioId.isEmpty ? null : sesion.usuarioId;

      final nuevoInsumo = InsumosCompanion.insert(
        id: nuevoId,
        negocioId: negocioId,
        nombre: nombreLimpio,
        // #262: `categoria` (texto) queda como copia DENORMALIZADA del nombre de
        // la categoría; la fuente de verdad es `categoriaId`.
        categoria: categoria,
        categoriaId: Value(categoriaId),
        // #239: sin costo inicial — costoPorUnidad queda en su default (0.0) y
        // historial_precios queda VACÍO: el primer asiento lo escribe la
        // primera recepción procesada, que es una compra real.
        unidad: unidad,
        tipo: Value(tipo),
        activo: const Value(true),
        fechaCreacion: Value(DateTime.now()),
      );

      await _db.into(_db.insumos).insert(nuevoInsumo);

      final creado = await (_db.select(
        _db.insumos,
      )..where((i) => i.id.equals(nuevoId))).getSingle();

      await _sync?.encolarMutacion(
        nombreTabla: 'insumos',
        registroId: nuevoId,
        accion: 'INSERT',
        datos: MapeadoresSupabase.insumo(creado),
      );

      // #262: el insumo ya NO se vincula a un proveedor al nacer (ese eje se
      // retiró). Pertenece a la categoría elegida (`categoriaId`).

      // Auditoría inmutable del alta (HU-030).
      await _auditoria?.registrar(
        negocioId: negocioId,
        usuarioId: usuarioId,
        tablaAfectada: 'insumos',
        registroId: nuevoId,
        accion: 'INSERT',
        datosAntes: null,
        datosDespues: MapeadoresSupabase.insumo(creado),
      );

      await cargarDatos();
      return ResultadoCrearInsumo.exito(creado);
    } catch (e) {
      return ResultadoCrearInsumo.error('No se pudo crear el insumo: $e');
    }
  }

  /// Desactiva (baja lógica) un insumo: marca `activo = false` para que deje de
  /// aparecer en nuevas selecciones, sin borrar el registro ni su trazabilidad
  /// histórica (sigue visible en las recetas que lo usan) — HU-005.
  Future<void> eliminarInsumo(Insumo insumo) async {
    await (_db.update(_db.insumos)..where((i) => i.id.equals(insumo.id))).write(
      InsumosCompanion(
        activo: const Value(false),
        // HU-028: contador de concurrencia (antes quedaba siempre en 0).
        version: Value(insumo.version + 1),
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    await _sync?.encolarMutacion(
      nombreTabla: 'insumos',
      registroId: insumo.id,
      accion: 'UPDATE',
      datos: {'id': insumo.id, 'activo': false},
      versionBase: insumo.version,
    );

    // Auditoría inmutable de la baja (HU-030): quién la hizo, con foto antes/después.
    final despues = await (_db.select(
      _db.insumos,
    )..where((i) => i.id.equals(insumo.id))).getSingle();
    await _auditoria?.registrar(
      negocioId: insumo.negocioId,
      usuarioId: sesion.usuarioId.isEmpty ? null : sesion.usuarioId,
      tablaAfectada: 'insumos',
      registroId: insumo.id,
      accion: 'UPDATE',
      datosAntes: MapeadoresSupabase.insumo(insumo),
      datosDespues: MapeadoresSupabase.insumo(despues),
    );

    await cargarDatos();
  }

  /// Cuenta cuántas RECETAS (distintas) utilizan un insumo, vía la tabla
  /// intermedia receta_ingredientes. Alimenta la confirmación/bloqueo del
  /// cambio de unidad (HU-004) y la advertencia de la baja lógica (HU-005).
  Future<int> contarRecetasQueUsanInsumo(String insumoId) async {
    final filas = await (_db.select(
      _db.recetaIngredientes,
    )..where((ri) => ri.insumoId.equals(insumoId))).get();
    return filas.map((f) => f.recetaId).toSet().length;
  }

  /// Familias de unidades convertibles (deben coincidir con [ConversorUnidades]).
  /// Las unidades discretas (u, paq, atado, otro) no tienen familia: cada una es
  /// su propia "familia", por lo que cambiar entre ellas se considera cruce.
  static const Map<String, String> _familiaPorUnidad = {
    'kg': 'masa',
    'g': 'masa',
    'gr': 'masa',
    'lt': 'volumen',
    'l': 'volumen',
    'ml': 'volumen',
    'cc': 'volumen',
  };

  /// Indica si dos unidades pertenecen a la misma familia convertible (kg↔g,
  /// lt↔ml). Si alguna no está en una familia conocida, se compara por nombre.
  static bool mismaFamiliaUnidad(String a, String b) {
    final fa =
        _familiaPorUnidad[a.trim().toLowerCase()] ?? a.trim().toLowerCase();
    final fb =
        _familiaPorUnidad[b.trim().toLowerCase()] ?? b.trim().toLowerCase();
    return fa == fb;
  }

  /// Edita un insumo existente (HU-004) aplicando las reglas de negocio:
  ///  • Cambios NO financieros (nombre, categoría, tipo, unidad) →
  ///    UPDATE directo de `insumos`, sin tocar el historial de precios.
  ///  • Cambio de COSTO → se registra en `historial_precios` (fuente de verdad):
  ///    crea historial, refresca la caché, genera alerta de desviación y dispara
  ///    el recálculo del costo de las recetas afectadas (vía [cargarDatos]).
  ///  • Cambio de UNIDAD con el insumo usado en recetas → solo se permite dentro
  ///    de la misma familia (kg↔g, lt↔ml); el cruce de familias se BLOQUEA aquí
  ///    (defensa en profundidad) para no romper el costeo ya cargado.
  ///  • Todo cambio queda trazado en `registros_auditoria` (datos antes/después).
  ///
  /// La confirmación del cambio de unidad (misma familia) es responsabilidad de
  /// la UI; este método solo aplica el bloqueo duro del cruce de familias.
  Future<ResultadoEdicionInsumo> actualizarInsumo({
    required Insumo original,
    required String nombre,
    required String categoria,
    required String categoriaId,
    required String tipo,
    required String unidad,
    required double nuevoCosto,
  }) async {
    final nombreLimpio = nombre.trim();

    final cambioNombre = nombreLimpio != original.nombre;
    // #262: la categoría cambia como par (texto denormalizado + id). Alcanza con
    // mirar el id: el texto es su copia.
    final cambioCategoria = categoriaId != original.categoriaId;
    final cambioTipo = tipo != original.tipo;
    final cambioUnidad = unidad != original.unidad;
    final cambioCosto = (nuevoCosto - original.costoPorUnidad).abs() > 0.0001;

    // #239: la edición es el ÚNICO camino de corrección manual del costo, y la
    // doble validación "costo > 0" que vivía en el alta se MUDA acá (solo
    // cuando el costo CAMBIÓ: sin eso, un insumo nacido a $0 no podría guardar
    // ni un cambio de nombre). Un ajuste a $0 tiraría a cero el costeo de
    // todas las recetas que lo usan.
    if (cambioCosto && nuevoCosto <= 0) {
      return ResultadoEdicionInsumo.error('El costo debe ser mayor a 0.');
    }

    if (!cambioNombre &&
        !cambioCategoria &&
        !cambioTipo &&
        !cambioUnidad &&
        !cambioCosto) {
      return ResultadoEdicionInsumo.sinCambios();
    }

    // Bloqueo duro: cambio de unidad a otra familia con el insumo en uso.
    if (cambioUnidad) {
      final usos = await contarRecetasQueUsanInsumo(original.id);
      if (usos > 0 && !mismaFamiliaUnidad(original.unidad, unidad)) {
        return ResultadoEdicionInsumo.error(
          'No se puede cambiar la unidad de "${original.nombre}" de ${original.unidad} a $unidad: '
          'rompería el costo de $usos receta(s) que lo usan. Solo se permiten cambios dentro '
          'de la misma familia (kg↔g, lt↔ml).',
        );
      }
    }

    final hayCambioNoFinanciero =
        cambioNombre || cambioCategoria || cambioTipo || cambioUnidad;

    // 1) Cambios NO financieros → UPDATE directo (sin historial). Solo se escriben
    //    los campos que efectivamente cambiaron; el trigger de Supabase actualiza updated_at.
    if (hayCambioNoFinanciero) {
      await (_db.update(
        _db.insumos,
      )..where((i) => i.id.equals(original.id))).write(
        InsumosCompanion(
          nombre: cambioNombre ? Value(nombreLimpio) : const Value.absent(),
          // #262: categoría = texto denormalizado + id, se escriben juntos.
          categoria: cambioCategoria ? Value(categoria) : const Value.absent(),
          categoriaId: cambioCategoria
              ? Value(categoriaId)
              : const Value.absent(),
          tipo: cambioTipo ? Value(tipo) : const Value.absent(),
          unidad: cambioUnidad ? Value(unidad) : const Value.absent(),
          version: Value(original.version + 1), // HU-028
          estadoSync: const Value('pendiente'),
          fechaActualizacion: Value(DateTime.now()),
        ),
      );

      final datos = <String, dynamic>{'id': original.id};
      if (cambioNombre) datos['nombre'] = nombreLimpio;
      if (cambioCategoria) {
        datos['categoria'] = categoria;
        datos['categoria_id'] = categoriaId;
      }
      if (cambioTipo) datos['tipo'] = tipo;
      if (cambioUnidad) datos['unidad'] = unidad;
      await _sync?.encolarMutacion(
        nombreTabla: 'insumos',
        registroId: original.id,
        accion: 'UPDATE',
        datos: datos,
        versionBase: original.version,
      );
    }

    // 2) Cambio de costo → historial de precios (fuente de verdad; refresca caché,
    //    genera alerta y conserva valor anterior/nuevo + origen).
    if (cambioCosto) {
      final usuarioId = sesion.usuarioId.isEmpty ? null : sesion.usuarioId;
      // #262: el ajuste manual de costo desde la ficha del insumo ya no lleva
      // proveedor (los insumos no cuelgan de uno). El historial guarda el asiento
      // sin proveedor asociado.
      if (_precios != null) {
        await _precios.registrar(
          insumoId: original.id,
          nuevoPrecio: nuevoCosto,
          origen: 'ajuste_manual',
          proveedorId: null,
          referenciaId: null,
          usuarioId: usuarioId,
        );
      } else {
        await _db.registrarPrecioInsumo(
          insumoId: original.id,
          nuevoPrecio: nuevoCosto,
          origen: 'ajuste_manual',
          proveedorId: null,
          referenciaId: null,
          usuarioId: usuarioId,
        );
      }
    }

    // 3) Auditoría inmutable (HU-030): quién cambió qué, con foto antes/después.
    final despues = await (_db.select(
      _db.insumos,
    )..where((i) => i.id.equals(original.id))).getSingle();
    await _auditoria?.registrar(
      negocioId: original.negocioId,
      usuarioId: sesion.usuarioId.isEmpty ? null : sesion.usuarioId,
      tablaAfectada: 'insumos',
      registroId: original.id,
      accion: 'UPDATE',
      datosAntes: MapeadoresSupabase.insumo(original),
      datosDespues: MapeadoresSupabase.insumo(despues),
    );

    await cargarDatos();
    return ResultadoEdicionInsumo.exito();
  }
}

/// Resultado de [ControladorInsumos.crearInsumo]: éxito (con el insumo creado)
/// o error con mensaje para mostrar al usuario.
class ResultadoCrearInsumo {
  final bool ok;
  final Insumo? insumo;
  final String? error;

  const ResultadoCrearInsumo._(this.ok, this.insumo, this.error);

  factory ResultadoCrearInsumo.exito(Insumo insumo) =>
      ResultadoCrearInsumo._(true, insumo, null);
  factory ResultadoCrearInsumo.error(String mensaje) =>
      ResultadoCrearInsumo._(false, null, mensaje);
}

/// Resultado de [ControladorInsumos.actualizarInsumo]: distingue éxito, sin
/// cambios y bloqueo de negocio (con mensaje para mostrar al usuario).
class ResultadoEdicionInsumo {
  final bool ok;
  final bool sinCambios;
  final String? error;

  const ResultadoEdicionInsumo._(this.ok, this.sinCambios, this.error);

  factory ResultadoEdicionInsumo.exito() =>
      const ResultadoEdicionInsumo._(true, false, null);
  factory ResultadoEdicionInsumo.sinCambios() =>
      const ResultadoEdicionInsumo._(true, true, null);
  factory ResultadoEdicionInsumo.error(String mensaje) =>
      ResultadoEdicionInsumo._(false, false, mensaje);
}
