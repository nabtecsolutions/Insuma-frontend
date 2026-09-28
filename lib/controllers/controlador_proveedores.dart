import 'package:flutter/material.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:uuid/uuid.dart';
import '../utils/validador_datos.dart';
import '../database/database.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_sincronizacion_supabase.dart';
import '../services/servicio_descarga_negocio.dart';
import '../data/mapeadores_supabase.dart';

/// Controlador encargado de gestionar el estado y la lógica de negocio
/// de la pestaña de Proveedores de INSUMA (Patrón MVC).
class ControladorProveedores extends ChangeNotifier {
  final ServicioSesion sesion;
  final BaseDatosApp _db;
  final ServicioSincronizacionSupabase? _sync;
  final ServicioDescargaNegocio? _descarga;

  ControladorProveedores(this.sesion, this._db, [this._sync, this._descarga]);

  /// Recarga (pull) los datos del negocio desde Supabase y refresca la lista local.
  /// Para el botón de recarga: trae lo cargado por otros dispositivos del negocio.
  /// Offline-first: si falla la descarga, igual recarga lo local.
  Future<void> recargarDesdeLaNube() async {
    final negocioId = sesion.negocioId;
    if (_descarga != null && negocioId.isNotEmpty) {
      try {
        await _descarga.descargarNegocio(negocioId);
      } catch (_) {
        /* sin conexión: se muestra lo local */
      }
    }
    await cargarInfoLocalYProveedores();
  }

  String _busqueda = '';
  String _categoriaSeleccionada = 'Todos';
  String _negocioId = '';
  String _usuarioRol = 'cocinero';
  List<Proveedore> _proveedores = [];
  bool _cargando = true;
  bool _verInactivos = false;

  // Getters para exponer a la Vista
  String get busqueda => _busqueda;
  String get categoriaSeleccionada => _categoriaSeleccionada;
  String get negocioId => _negocioId;
  String get usuarioRol => _usuarioRol;
  List<Proveedore> get proveedores => _proveedores;
  bool get cargando => _cargando;
  bool get verInactivos => _verInactivos;

  List<Proveedore> get proveedoresFiltrados {
    return _proveedores.where((p) {
      final coincideBusqueda =
          p.nombre.toLowerCase().contains(_busqueda.toLowerCase()) ||
          (p.contacto?.toLowerCase().contains(_busqueda.toLowerCase()) ??
              false);
      final coincideCategoria =
          _categoriaSeleccionada == 'Todos' ||
          p.categoria == _categoriaSeleccionada;
      return coincideBusqueda && coincideCategoria;
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

  /// Alterna entre ver proveedores activos (vista normal) y los desactivados
  /// (para poder reactivarlos, HU-008). Recarga la lista acorde al modo elegido.
  void alternarVerInactivos() {
    _verInactivos = !_verInactivos;
    cargarInfoLocalYProveedores();
  }

  /// Carga la información de sesión y consulta los proveedores locales asociados al negocio.
  Future<void> cargarInfoLocalYProveedores() async {
    final negocioId = sesion.negocioId;
    if (negocioId.isEmpty) return;

    final usuarioRol = sesion.usuarioRol;

    // Según el modo, se listan los activos (vista normal) o los desactivados.
    final lista =
        await (_db.select(_db.proveedores)..where(
              (p) =>
                  p.negocioId.equals(negocioId) &
                  p.activo.equals(!_verInactivos),
            ))
            .get();

    _negocioId = negocioId;
    _usuarioRol = usuarioRol;
    _proveedores = lista;
    _cargando = false;
    notifyListeners();
  }

  /// Desactiva (baja lógica, RN-003) el proveedor: lo marca inactivo, desvincula
  /// sus insumos y conserva todo el histórico. No borra físicamente nada.
  Future<bool> desactivarProveedor({
    required Proveedore proveedor,
    required void Function() alCompletar,
    required void Function(String error) mostrarError,
  }) async {
    try {
      // Marcamos proveedor como inactivo (baja lógica, RN-003)
      await (_db.update(
        _db.proveedores,
      )..where((p) => p.id.equals(proveedor.id))).write(
        ProveedoresCompanion(
          activo: const Value(false),
          version: Value(proveedor.version + 1), // HU-028
          estadoSync: const Value('pendiente'),
          fechaActualizacion: Value(DateTime.now()),
        ),
      );
      await _sync?.encolarMutacion(
        nombreTabla: 'proveedores',
        registroId: proveedor.id,
        accion: 'UPDATE',
        datos: {'id': proveedor.id, 'activo': false},
        versionBase: proveedor.version,
      );

      // Desvinculamos insumos asociados al proveedor (y los encolamos para sync)
      final insumosAfectados = await (_db.select(
        _db.insumos,
      )..where((i) => i.proveedorId.equals(proveedor.id))).get();
      await (_db.update(
        _db.insumos,
      )..where((i) => i.proveedorId.equals(proveedor.id))).write(
        InsumosCompanion(
          proveedorId: const Value(null),
          estadoSync: const Value('pendiente'),
          fechaActualizacion: Value(DateTime.now()),
        ),
      );
      for (final ins in insumosAfectados) {
        // HU-028: cada insumo lleva su propio contador (update masivo → se
        // incrementa fila por fila para que el token sea el de cada registro).
        await (_db.update(_db.insumos)..where((i) => i.id.equals(ins.id)))
            .write(InsumosCompanion(version: Value(ins.version + 1)));
        await _sync?.encolarMutacion(
          nombreTabla: 'insumos',
          registroId: ins.id,
          accion: 'UPDATE',
          datos: {'id': ins.id, 'proveedor_id': null},
          versionBase: ins.version,
        );
      }

      await cargarInfoLocalYProveedores();
      alCompletar();
      return true;
    } catch (e) {
      mostrarError('Error al eliminar: $e');
      return false;
    }
  }

  /// Normaliza un CUIT a solo dígitos (quita guiones/espacios) para comparar y
  /// almacenar de forma consistente; '' si está vacío.
  static String _normalizarCuit(String cuit) =>
      cuit.replaceAll(RegExp(r'[-\s]'), '');

  /// Detección de posibles duplicados al crear un proveedor (HU-007): CUIT exacto
  /// (único por negocio) y nombre comercial (case-insensitive). Se evalúa contra
  /// los proveedores activos ya cargados.
  ({bool cuitDuplicado, bool nombreDuplicado}) chequearDuplicados({
    required String nombre,
    required String cuit,
  }) {
    final nombreNorm = nombre.trim().toLowerCase();
    final cuitNorm = _normalizarCuit(cuit);
    final cuitDuplicado =
        cuitNorm.isNotEmpty &&
        _proveedores.any((p) => _normalizarCuit(p.cuit ?? '') == cuitNorm);
    final nombreDuplicado =
        nombreNorm.isNotEmpty &&
        _proveedores.any((p) => p.nombre.trim().toLowerCase() == nombreNorm);
    return (cuitDuplicado: cuitDuplicado, nombreDuplicado: nombreDuplicado);
  }

  /// Registra un nuevo proveedor local.
  Future<bool> crearProveedor({
    required String nombre,
    required String categoria,
    required String contacto,
    required String email,
    required String telefono,
    required String plazoPago,
    String cuit = '',
    String aliasBancario = '',
    String cbu = '',
    required void Function() alCompletar,
    required void Function(String error) mostrarError,
  }) async {
    if (nombre.trim().isEmpty) {
      mostrarError('El nombre del proveedor es obligatorio.');
      return false;
    }

    final cuitNorm = _normalizarCuit(cuit);

    // #220: los datos bancarios son OPCIONALES —a un proveedor al que se le
    // paga en efectivo no hay por qué cargárselos— pero si se carga el CBU
    // tiene que ser un CBU. Un dígito de menos se copia igual y la
    // transferencia se cae recién en el homebanking.
    //
    // Se reusa `ValidadorDatos.validarCbuCvu`: 22 dígitos tolerando guiones y
    // espacios. Ya existía en el proyecto y no la usaba nadie.
    final aliasNorm = aliasBancario.trim();
    final cbuNorm = cbu.trim();
    if (cbuNorm.isNotEmpty && !ValidadorDatos.validarCbuCvu(cbuNorm)) {
      mostrarError('El CBU/CVU tiene que tener 22 dígitos.');
      return false;
    }

    try {
      // Backstop de unicidad de CUIT por negocio (defensa en profundidad): cubre
      // también proveedores inactivos, que no están en la lista cargada.
      if (cuitNorm.isNotEmpty) {
        final delNegocio = await (_db.select(
          _db.proveedores,
        )..where((p) => p.negocioId.equals(_negocioId))).get();
        final existe = delNegocio.any(
          (p) => _normalizarCuit(p.cuit ?? '') == cuitNorm,
        );
        if (existe) {
          mostrarError('Ya existe un proveedor con ese CUIT en este negocio.');
          return false;
        }
      }

      final nuevoId = const Uuid().v4();
      await _db
          .into(_db.proveedores)
          .insert(
            ProveedoresCompanion.insert(
              id: nuevoId,
              negocioId: _negocioId,
              nombre: nombre.trim(),
              categoria: Value(categoria),
              contacto: Value(
                contacto.trim().isNotEmpty ? contacto.trim() : null,
              ),
              email: Value(email.trim().isNotEmpty ? email.trim() : null),
              telefono: Value(
                telefono.trim().isNotEmpty ? telefono.trim() : null,
              ),
              cuit: Value(cuitNorm.isNotEmpty ? cuitNorm : null),
              plazoPago: Value(plazoPago.isNotEmpty ? plazoPago : null),
              // #220: vacío se guarda como NULL, no como ''. NULL significa
              // "sin cargar" y es lo que hace que la fila salga en gris
              // diciéndolo; una cadena vacía se vería como un dato cargado que
              // no dice nada.
              aliasBancario: Value(aliasNorm.isNotEmpty ? aliasNorm : null),
              cbu: Value(cbuNorm.isNotEmpty ? cbuNorm : null),
              activo: const Value(true),
              fechaCreacion: Value(DateTime.now()),
            ),
          );

      final creado = await (_db.select(
        _db.proveedores,
      )..where((p) => p.id.equals(nuevoId))).getSingle();
      await _sync?.encolarMutacion(
        nombreTabla: 'proveedores',
        registroId: nuevoId,
        accion: 'INSERT',
        datos: MapeadoresSupabase.proveedor(creado),
      );

      await cargarInfoLocalYProveedores();
      alCompletar();
      return true;
    } catch (e) {
      mostrarError('Error al crear proveedor: $e');
      return false;
    }
  }

  /// Edita los datos de un proveedor existente (HU-008). Solo actualiza los campos
  /// editables (no toca id/negocioId/activo), re-encola para sync y recarga la lista.
  Future<bool> editarProveedor({
    required String id,
    required String nombre,
    required String categoria,
    required String contacto,
    required String email,
    required String telefono,
    required String plazoPago,
    String cuit = '',
    String aliasBancario = '',
    String cbu = '',
    required void Function() alCompletar,
    required void Function(String error) mostrarError,
  }) async {
    if (nombre.trim().isEmpty) {
      mostrarError('El nombre del proveedor es obligatorio.');
      return false;
    }

    final cuitNorm = _normalizarCuit(cuit);

    // #220: los datos bancarios son OPCIONALES —a un proveedor al que se le
    // paga en efectivo no hay por qué cargárselos— pero si se carga el CBU
    // tiene que ser un CBU. Un dígito de menos se copia igual y la
    // transferencia se cae recién en el homebanking.
    //
    // Se reusa `ValidadorDatos.validarCbuCvu`: 22 dígitos tolerando guiones y
    // espacios. Ya existía en el proyecto y no la usaba nadie.
    final aliasNorm = aliasBancario.trim();
    final cbuNorm = cbu.trim();
    if (cbuNorm.isNotEmpty && !ValidadorDatos.validarCbuCvu(cbuNorm)) {
      mostrarError('El CBU/CVU tiene que tener 22 dígitos.');
      return false;
    }

    try {
      // Unicidad de CUIT por negocio, excluyendo el propio proveedor (cubre inactivos).
      if (cuitNorm.isNotEmpty) {
        final delNegocio =
            await (_db.select(_db.proveedores)..where(
                  (p) => p.negocioId.equals(_negocioId) & p.id.equals(id).not(),
                ))
                .get();
        final existe = delNegocio.any(
          (p) => _normalizarCuit(p.cuit ?? '') == cuitNorm,
        );
        if (existe) {
          mostrarError(
            'Ya existe otro proveedor con ese CUIT en este negocio.',
          );
          return false;
        }
      }

      // HU-028: `version` previa como token de concurrencia del push.
      final previo = await (_db.select(
        _db.proveedores,
      )..where((p) => p.id.equals(id))).getSingle();
      await (_db.update(_db.proveedores)..where((p) => p.id.equals(id))).write(
        ProveedoresCompanion(
          nombre: Value(nombre.trim()),
          categoria: Value(categoria),
          contacto: Value(contacto.trim().isNotEmpty ? contacto.trim() : null),
          email: Value(email.trim().isNotEmpty ? email.trim() : null),
          telefono: Value(telefono.trim().isNotEmpty ? telefono.trim() : null),
          cuit: Value(cuitNorm.isNotEmpty ? cuitNorm : null),
          plazoPago: Value(plazoPago.isNotEmpty ? plazoPago : null),
          // #220: vaciar el campo BORRA el dato (queda NULL), no lo conserva.
          // Es lo que corresponde: si alguien limpia el alias es porque ese
          // proveedor dejó de tenerlo, y dejar el viejo haría transferir a una
          // cuenta que ya no va.
          aliasBancario: Value(aliasNorm.isNotEmpty ? aliasNorm : null),
          cbu: Value(cbuNorm.isNotEmpty ? cbuNorm : null),
          version: Value(previo.version + 1), // HU-028
          estadoSync: const Value('pendiente'),
          fechaActualizacion: Value(DateTime.now()),
        ),
      );

      final actualizado = await (_db.select(
        _db.proveedores,
      )..where((p) => p.id.equals(id))).getSingle();
      await _sync?.encolarMutacion(
        nombreTabla: 'proveedores',
        registroId: id,
        accion: 'UPDATE',
        datos: MapeadoresSupabase.proveedor(actualizado),
        versionBase: previo.version,
      );

      await cargarInfoLocalYProveedores();
      alCompletar();
      return true;
    } catch (e) {
      mostrarError('Error al editar proveedor: $e');
      return false;
    }
  }

  /// Evalúa los vínculos vivos de un proveedor para advertir antes de desactivarlo
  /// (HU-008): pedidos sin cerrar, facturas impagas y saldo de cuenta corriente.
  Future<({int pedidosAbiertos, int facturasPendientes, double saldo})>
  evaluarVinculos(String proveedorId) async {
    final pedidosAbiertos =
        await (_db.select(_db.pedidos)..where(
              (p) =>
                  p.proveedorId.equals(proveedorId) &
                  p.estado.isIn(const ['borrador', 'enviado', 'parcial']),
            ))
            .get();

    final facturasPendientes =
        await (_db.select(_db.facturas)..where(
              (f) =>
                  f.proveedorId.equals(proveedorId) &
                  f.estado.isIn(const ['pendiente', 'parcial']),
            ))
            .get();

    // HU-083 (C5): el saldo es DERIVADO = SUM(monto) de los movimientos, no el `saldo`
    // guardado del último (que divergía entre dispositivos en la cadena append-only).
    final sumaMonto = _db.movimientosCuentaCorriente.monto.sum();
    final filaSaldo =
        await (_db.selectOnly(_db.movimientosCuentaCorriente)
              ..addColumns([sumaMonto])
              ..where(
                _db.movimientosCuentaCorriente.proveedorId.equals(proveedorId),
              ))
            .getSingle();
    final saldo = filaSaldo.read(sumaMonto) ?? 0.0;

    return (
      pedidosAbiertos: pedidosAbiertos.length,
      facturasPendientes: facturasPendientes.length,
      saldo: saldo,
    );
  }

  /// Reactiva un proveedor previamente desactivado (HU-008): vuelve a marcarlo
  /// activo y lo re-encola para sync. El historial nunca se perdió.
  Future<bool> reactivarProveedor({
    required Proveedore proveedor,
    required void Function() alCompletar,
    required void Function(String error) mostrarError,
  }) async {
    try {
      await (_db.update(
        _db.proveedores,
      )..where((p) => p.id.equals(proveedor.id))).write(
        ProveedoresCompanion(
          activo: const Value(true),
          version: Value(proveedor.version + 1), // HU-028
          estadoSync: const Value('pendiente'),
          fechaActualizacion: Value(DateTime.now()),
        ),
      );
      await _sync?.encolarMutacion(
        nombreTabla: 'proveedores',
        registroId: proveedor.id,
        accion: 'UPDATE',
        datos: {'id': proveedor.id, 'activo': true},
        versionBase: proveedor.version,
      );

      await cargarInfoLocalYProveedores();
      alCompletar();
      return true;
    } catch (e) {
      mostrarError('Error al reactivar: $e');
      return false;
    }
  }
}
