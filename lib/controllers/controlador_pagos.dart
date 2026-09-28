import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart';
import '../utils/dinero.dart';
import '../database/database.dart';
import '../models/recepcion_facturable.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_pagos.dart';
import '../services/servicio_permisos.dart';
import '../services/servicio_recepciones_admin.dart';
import '../utils/adjuntos/tipo_adjunto.dart';
import 'controlador_adjuntos.dart';

/// Controlador del módulo Pagos (HU-023 facturas / HU-024 pagos).
///
/// Lee el estado (proveedores, pedidos facturables, facturas y saldos) desde la
/// base local y delega las escrituras en los servicios de dominio
/// [ServicioFacturacion] y [ServicioPagos], que ya resuelven cuenta corriente,
/// imputaciones, anticipos, idempotencia y auditoría.
class ControladorPagos extends ChangeNotifier {
  final ServicioSesion sesion;
  final BaseDatosApp _db;
  final ServicioPagos _pagos;
  final ServicioRecepcionesAdmin _recepcionesAdmin;

  ControladorPagos(this.sesion, this._db, this._pagos, this._recepcionesAdmin);

  static const List<String> metodosPago = [
    'efectivo',
    'transferencia',
    'cheque',
  ];

  String _negocioId = '';
  bool _cargando = true;

  // HU-128 (patrón HU-089): suscripciones watch() que mantienen la pantalla al
  // día con la DB real (recepciones nuevas desde Recibir, filas que llegan por
  // sync) sin depender de un cargar() manual.
  StreamSubscription<Object?>? _subRecepciones;
  StreamSubscription<Object?>? _subFacturas;

  // HU-136: guarda de reentrancia — colapsa RÁFAGAS de emisiones watch() (p. ej.
  // el pull post-login insertando cientos de filas) en una relectura. _leer() es
  // una foto idempotente: leer UNA vez al final de la ráfaga produce el mismo
  // estado que leer N veces (y evita N×(gets+SUMs) solapados, medido: 53
  // relecturas por cada 100 filas sin la guarda).
  bool _relecturaEnVuelo = false;
  bool _relecturaPendiente = false;

  /// Lecturas completas ejecutadas — visible para el test de colapso (HU-136).
  @visibleForTesting
  int lecturasRealizadas = 0;

  Future<void> _programarRelectura(String negocioId) async {
    if (_relecturaEnVuelo) {
      _relecturaPendiente = true;
      return;
    }
    _relecturaEnVuelo = true;
    try {
      do {
        _relecturaPendiente = false;
        await _leer(negocioId);
      } while (_relecturaPendiente);
    } catch (e) {
      // Relectura de FONDO disparada por watch(): si la DB se cerró a mitad de
      // camino (shutdown/teardown), no hay nada que mostrar ni a quién notificar.
      debugPrint('[PAGOS] Relectura reactiva abortada: $e');
    } finally {
      _relecturaEnVuelo = false;
    }
  }

  List<Proveedore> _proveedores = [];
  List<RecepcionFacturable> _recepcionesFacturables = [];
  List<Factura> _facturas = [];
  final Map<String, double> _saldos = {};
  final Map<String, double> _imputado = {};

  bool get cargando => _cargando;
  List<Proveedore> get proveedores => _proveedores;

  /// Recepciones pendientes de facturar (una fila por remito). Se factura contra
  /// remito por lo recibido (HU-067).
  List<RecepcionFacturable> get recepcionesFacturables =>
      _recepcionesFacturables;

  double saldo(String proveedorId) => _saldos[proveedorId] ?? 0.0;

  /// El proveedor entero, para lo que necesita más que el nombre — sus datos
  /// bancarios al momento de pagarle (#220). Null si no está en la lista
  /// cargada (por ejemplo, si está inactivo).
  Proveedore? proveedorPorId(String? proveedorId) {
    if (proveedorId == null) return null;
    for (final p in _proveedores) {
      if (p.id == proveedorId) return p;
    }
    return null;
  }

  String nombreProveedor(String? proveedorId) {
    if (proveedorId == null) return 'Sin proveedor';
    for (final p in _proveedores) {
      if (p.id == proveedorId) return p.nombre;
    }
    return 'Proveedor';
  }

  /// Facturas del proveedor que aún no están saldadas (pendiente/parcial).
  /// Todas las facturas del negocio (#229): la pantalla de procesar valida
  /// contra ellas el número duplicado por proveedor.
  List<Factura> get facturasDelNegocio => List.unmodifiable(_facturas);

  /// Facturas del proveedor sin cancelar, LA MÁS VENCIDA PRIMERO (HU-149).
  ///
  /// El orden no es cosmético: el formulario de pago arma las imputaciones
  /// recorriendo esta lista, y `ServicioPagos.registrarPago` reparte el monto
  /// hasta agotarlo. Si el pago no alcanza para todas las tildadas, lo que
  /// quede impago tiene que ser lo MENOS urgente — no lo que la base devuelva
  /// primero.
  ///
  /// Antes salía en el orden de `_facturas`, que se carga con un `select` sin
  /// `orderBy`: o sea, orden de inserción. Que `facturasDe` (acá abajo) ordene
  /// a mano es la señal de que eso ya se sabía; a esta le faltaba.
  List<Factura> facturasPendientesDe(String proveedorId) {
    final lista =
        _facturas
            .where((f) => f.proveedorId == proveedorId && f.estado != 'pagada')
            .toList()
          ..sort((a, b) => a.fechaVencimiento.compareTo(b.fechaVencimiento));
    return lista;
  }

  /// Todas las facturas del proveedor, ordenadas por vencimiento (HU-025).
  List<Factura> facturasDe(String proveedorId) {
    final lista = _facturas.where((f) => f.proveedorId == proveedorId).toList()
      ..sort((a, b) => a.fechaVencimiento.compareTo(b.fechaVencimiento));
    return lista;
  }

  /// Una factura está vencida si pasó su vencimiento y aún tiene saldo (HU-025).
  bool facturaVencida(Factura f) {
    if (f.estado == 'pagada' || f.estado == 'anulada') return false;
    final hoy = DateTime.now();
    final hoySinHora = DateTime(hoy.year, hoy.month, hoy.day);
    return f.fechaVencimiento.isBefore(hoySinHora);
  }

  /// Saldo remanente de una factura (total bruto menos lo ya imputado).
  double saldoFactura(Factura f) => f.totalBruto - (_imputado[f.id] ?? 0.0);

  /// Lo que falta pagar, sumando el saldo de TODAS las facturas sin cancelar.
  ///
  /// Es el número que el administrador mira antes de salir a pagarle a los
  /// proveedores: cuánta plata juntar.
  ///
  /// ⚠ NO coincide con la suma de los "Debe $X" de las tarjetas de proveedor, y
  /// no es un bug. Son dos cálculos distintos:
  ///
  ///  • `saldo(proveedorId)` suma TODOS los movimientos de la cuenta corriente:
  ///    las facturas suman y los pagos restan, estén imputados o no.
  ///  • Esto suma `saldoFactura` = `totalBruto − imputado`, o sea mira SÓLO lo
  ///    imputado.
  ///
  /// La diferencia son los pagos ya entregados pero todavía sin imputar a una
  /// factura. Con una factura de $10.000 y un adelanto de $3.000 sin imputar, el
  /// "Debe" dice $7.000 y esto dice $10.000. Que ese caso existe lo confirma
  /// [anticipoDe], que calcula justamente ese saldo a favor.
  ///
  /// El PO eligió el total de facturas ABIERTAS: responde "cuánto papel queda
  /// sin cancelar", no "cuánto neto le debo".
  ///
  /// Sin consulta: `_facturas` y `_imputado` ya están en memoria desde `cargar`.
  double get totalPendienteDePago {
    var total = 0.0;
    for (final f in _facturas) {
      if (f.estado == 'pagada' || f.estado == 'anulada') continue;
      total += saldoFactura(f);
    }
    return Dinero.redondear(total);
  }

  /// Saldo a favor (anticipo) del proveedor, como valor positivo (HU-025).
  Future<double> anticipoDe(String proveedorId) =>
      _pagos.anticipoProveedor(proveedorId);

  /// Resumen de cuenta corriente del proveedor acotado a un período (HU-025).
  Future<ResumenCuentaCorriente> resumenCuenta(
    String proveedorId, {
    required DateTime desde,
    required DateTime hasta,
  }) => _pagos.resumenPeriodo(proveedorId, desde: desde, hasta: hasta);

  /// HU-143: escribe (o borra, con [nuevoTotal] null) el total recibido manual
  /// de una recepción y refresca el listado. Devuelve `null` si salió bien o un
  /// mensaje de error listo para mostrar.
  Future<String?> editarTotalRecibido(
    RecepcionFacturable recepcion, {
    double? nuevoTotal,
  }) async {
    try {
      await _recepcionesAdmin.editarTotalRecibido(
        recepcion: recepcion.recepcion,
        nuevoTotal: nuevoTotal,
        usuarioId: sesion.usuarioId.isEmpty ? null : sesion.usuarioId,
        usuarioNombre: sesion.usuarioNombre.isEmpty
            ? null
            : sesion.usuarioNombre,
      );
      await cargar();
      return null;
    } on ArgumentError {
      return 'El total recibido no puede ser negativo.';
    } on StateError catch (e) {
      // HU-143: recepción ya facturada — reintentar no lo arregla.
      return e.message;
    } catch (_) {
      return 'No se pudo guardar el total. Intentá de nuevo.';
    }
  }

  /// Carga los datos SÓLO si todavía no se cargaron.
  ///
  /// Hasta HU-009, `cargar()` se llamaba únicamente desde el `initState` de la
  /// pantalla de Pagos. Al abrir el formulario de pago desde OTRA pantalla —la
  /// ficha del proveedor— ese `initState` nunca corrió, así que el formulario
  /// mostraría "sin facturas pendientes" y saldo $0 EN SILENCIO: no un error, un
  /// dato falso.
  Future<void> asegurarCargado() async {
    if (!_cargando && _negocioId.isNotEmpty) return;
    await cargar();
  }

  /// La factura de una recepción, o `null` si esa recepción no se facturó.
  ///
  /// El puente recepción → factura vive ACÁ y no en la ficha del proveedor: si
  /// mañana cambia la relación entre las dos, cambia el módulo de Pagos y la
  /// ficha ni se entera. Es la misma razón por la que el formulario de pago se
  /// extrajo a un widget compartido.
  Factura? facturaDeRecepcion(String recepcionId) {
    for (final f in _facturas) {
      if (f.recepcionId == recepcionId) return f;
    }
    return null;
  }

  Future<void> cargar() async {
    final negocioId = sesion.negocioId;
    if (negocioId.isEmpty) {
      _cargando = false;
      notifyListeners();
      return;
    }
    _negocioId = negocioId;
    await _leer(negocioId);

    // HU-128 (patrón HU-089, ver controlador_dashboard): re-leer ante cambios en
    // recepciones o facturas de la DB. Guarda de re-suscripción: si cargar() se
    // llama de nuevo (otro negocio), se cancela la suscripción anterior.
    final subRecAnterior = _subRecepciones;
    _subRecepciones =
        (_db.select(_db.recepciones)
              ..where((r) => r.negocioId.equals(negocioId)))
            .watch()
            .listen((_) => _programarRelectura(negocioId));
    await subRecAnterior?.cancel();

    final subFacAnterior = _subFacturas;
    _subFacturas =
        (_db.select(_db.facturas)..where((f) => f.negocioId.equals(negocioId)))
            .watch()
            .listen((_) => _programarRelectura(negocioId));
    await subFacAnterior?.cancel();
  }

  /// Lectura de estado (foto de la DB) + notifyListeners. La invocan cargar(),
  /// las suscripciones watch() y las escrituras del propio controlador (que ya
  /// tienen suscripción activa y no deben re-suscribirse).
  Future<void> _leer(String negocioId) async {
    lecturasRealizadas++;
    _proveedores =
        await (_db.select(_db.proveedores)..where(
              (p) => p.negocioId.equals(negocioId) & p.activo.equals(true),
            ))
            .get();

    _recepcionesFacturables = await _recepcionesAdmin
        .listarPendientesDeFacturar(negocioId);

    _facturas = await (_db.select(
      _db.facturas,
    )..where((f) => f.negocioId.equals(negocioId))).get();

    final imps = await (_db.select(
      _db.imputacionesPago,
    )..where((i) => i.negocioId.equals(negocioId))).get();
    _imputado.clear();
    for (final i in imps) {
      _imputado[i.facturaId] =
          (_imputado[i.facturaId] ?? 0.0) + i.montoImputado;
    }

    _saldos.clear();
    for (final p in _proveedores) {
      _saldos[p.id] = await _pagos.saldoProveedor(p.id);
    }

    _cargando = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _subRecepciones?.cancel();
    _subFacturas?.cancel();
    super.dispose();
  }

  // #229: `registrarFacturaDeRecepcion` vivía acá, con ocho pasos de lógica
  // de negocio (una violación vieja de CLAUDE.md que no valía la pena seguir
  // alimentando). Su sucesor es `ControladorProcesarRecepcion` +
  // `ServicioProcesarRecepcion`: la pantalla de tres pasos, con costos por
  // ítem (IVA incluido) y el pago del efectivo asentado en la misma
  // transacción. La validación de "difiere ⇒ justificación" murió con él:
  // el detalle por renglón ES la justificación.

  /// Adjunta la FACTURA del proveedor a una recepción ya cerrada (HU-147).
  ///
  /// Es el caso corriente de que la mercadería llegue un día y la factura otro:
  /// hasta ahora ese papel se quedaba sin respaldo digital porque sólo se podía
  /// adjuntar durante la recepción.
  ///
  /// NO reemplaza nada: los adjuntos son filas, así que cargar una factura nueva
  /// deja la anterior en su lugar y el rastro queda entero (el visor muestra la
  /// más reciente).
  ///
  /// El "quién y cuándo" va a `registros_auditoria` (HU-030) y no a columnas de
  /// `adjuntos`: es el mecanismo que el proyecto ya tiene para eso, y duplicarlo
  /// crearía un segundo registro que se desincroniza del primero.
  Future<({bool ok, String? error})> adjuntarFactura({
    required RecepcionFacturable recepcion,
    required ControladorAdjuntos facturas,
  }) async {
    if (!facturas.tieneAdjuntos) {
      return (ok: false, error: 'Elegí el archivo de la factura.');
    }
    // Defensa en profundidad: la RLS ya lo bloquea (create_adjuntos, HU-114
    // extendida por HU-147), pero un cliente sin permiso no debería siquiera
    // encolar la mutación — terminaría en dead-letter y el usuario creería que
    // se guardó.
    if (!Permisos.puede(sesion.usuarioRol, Permiso.verFinanzas)) {
      return (ok: false, error: 'Sólo un administrador puede cargar facturas.');
    }

    // #227: validar y comprimir ANTES de escribir. Acá no hay transacción que
    // revertir (HU-147 es un alta suelta sobre una recepción ya cerrada), así
    // que el pre-flight es lo único que separa "el archivo no sirve, avisame"
    // de "auditar una factura que no se guardó".
    final errorAdjunto = await facturas.prepararTodo();
    if (errorAdjunto != null) return (ok: false, error: errorAdjunto);

    try {
      await facturas.persistirEn(
        negocioId: _negocioId,
        recepcionId: recepcion.recepcionId,
        tipo: TipoAdjunto.factura,
      );
      await _recepcionesAdmin.auditarFacturaAdjunta(
        negocioId: _negocioId,
        recepcionId: recepcion.recepcionId,
        usuarioId: sesion.usuarioId.isEmpty ? null : sesion.usuarioId,
      );
      await _leer(_negocioId);
      return (ok: true, error: null);
    } catch (e) {
      return (ok: false, error: 'No se pudo cargar la factura: $e');
    }
  }

  /// Registra un pago a un proveedor (HU-024). El servicio resuelve idempotencia,
  /// imputación a facturas, excedente como anticipo y auditoría.
  ///
  /// [comprobantes] (#238): los archivos staged del comprobante de la
  /// transferencia. Contrato anti-fallo-silencioso de #227: `prepararTodo()`
  /// corre ANTES del servicio (un archivo inválido corta el flujo con CERO
  /// filas escritas) y la escritura va DENTRO de la transacción del pago,
  /// ligada al pago por `pagoId`.
  Future<({bool ok, String? error})> registrarPago({
    required String proveedorId,
    required double monto,
    required String metodo,
    DateTime? fecha,
    String? referenciaExterna,
    String? nota,
    List<SolicitudImputacion> imputaciones = const [],
    ControladorAdjuntos? comprobantes,
  }) async {
    if (monto <= 0) {
      return (ok: false, error: 'El monto debe ser mayor a cero.');
    }
    if (!metodosPago.contains(metodo)) {
      return (ok: false, error: 'Método de pago inválido.');
    }

    final adjuntaComprobante =
        comprobantes != null && comprobantes.tieneAdjuntos;
    if (adjuntaComprobante) {
      final errorAdjunto = await comprobantes.prepararTodo();
      if (errorAdjunto != null) return (ok: false, error: errorAdjunto);
    }

    try {
      await _pagos.registrarPago(
        negocioId: _negocioId,
        proveedorId: proveedorId,
        monto: monto,
        metodo: metodo,
        referenciaExterna:
            (referenciaExterna != null && referenciaExterna.trim().isNotEmpty)
            ? referenciaExterna.trim()
            : null,
        fechaPago: fecha,
        nota: nota,
        usuarioId: sesion.usuarioId.isEmpty ? null : sesion.usuarioId,
        imputaciones: imputaciones,
        adjuntarEnTransaccion: adjuntaComprobante
            ? (pagoId) async {
                await comprobantes.persistirEn(
                  negocioId: _negocioId,
                  pagoId: pagoId,
                  tipo: TipoAdjunto.comprobante,
                );
              }
            : null,
      );
      await _leer(_negocioId); // sin re-suscribir: los watch() ya están activos
      return (ok: true, error: null);
    } catch (e) {
      return (ok: false, error: 'Error al registrar el pago: $e');
    }
  }
}
