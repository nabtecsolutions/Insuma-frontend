import 'package:drift/drift.dart' show Value;

import '../database/database.dart';
import '../data/repositorios/repositorio_factura_items.dart';
import '../utils/dinero.dart';
import '../utils/estados_pedido.dart';
import '../utils/iva.dart';
import '../utils/adjuntos/tipo_adjunto.dart';
import '../utils/origen_precio.dart';
import '../utils/transiciones_pedido.dart';
import 'servicio_configuracion_negocio.dart';
import 'servicio_facturacion.dart';
import 'servicio_pagos.dart';
import 'servicio_precios.dart';
import 'servicio_sincronizacion_supabase.dart';
import '../data/transaccionador.dart';

/// Lo que quedó registrado al procesar una recepción.
class ResultadoProcesamiento {
  final Factura factura;

  /// El pago, SÓLO cuando se pagó en efectivo al recibir. En el resto de los
  /// casos la factura queda pendiente y se paga después, desde Pagos.
  final Pago? pago;

  /// Cuántos insumos actualizaron su costo. Es el número que dice si el FoodCost
  /// se movió, y por eso vuelve: un procesamiento que factura pero no costea es
  /// el modo de falla silencioso de #229.
  final int insumosCosteados;

  const ResultadoProcesamiento({
    required this.factura,
    required this.insumosCosteados,
    this.pago,
  });
}

/// Procesar una recepción: cargarle los costos y dejar la plata asentada (#229).
///
/// Es el Service que reemplaza al costeo que vivía DENTRO de la recepción. Antes,
/// el precio se capturaba al recibir y un bucle en `ServicioRecepciones` lo
/// registraba ahí mismo. Ahora la recepción maneja sólo cantidades y el costo se
/// carga acá, cuando el admin procesa contra el comprobante.
///
/// ── Por qué es un Service nuevo y no crece `ControladorPagos` ────────────────
/// Ese controlador ya carga ocho pasos de lógica de negocio en
/// `registrarFacturaDeRecepcion` —normalización, validaciones, duplicados,
/// delegación, relectura—, que es una violación preexistente de CLAUDE.md.
/// Agregarle el costeo y el pago la haría estructural. El controlador queda de
/// pasamanos.
///
/// ── Todo pasa o no pasa nada ────────────────────────────────────────────────
/// Factura, renglones, costeo y pago van en UNA transacción. `enTransaccion`
/// lleva un contador de anidamiento, así que envolver a `registrarFactura` y
/// `registrarPago` —que abren la suya— es seguro y el Outbox drena una sola vez,
/// al final. Llamarlos en secuencia sin envolver dejaría el caso que más duele:
/// la factura registrada y el pago no, o sea una deuda que ya se pagó.
class ServicioProcesarRecepcion {
  final BaseDatosApp _db;

  /// #269: la regla de atomicidad vive en UN solo lugar. Ver
  /// `Transaccionador`: el ternario que estaba acá se repetia en seis
  /// services, y escribirlo al revés no tiene sintoma.
  late final Transaccionador _tx = Transaccionador(_db, _sync);
  final ServicioFacturacion _facturacion;
  final ServicioPagos _pagos;
  final ServicioPrecios _precios;
  final RepositorioFacturaItems _items;
  final ServicioConfiguracionNegocio _config;
  final ServicioSincronizacionSupabase? _sync;

  ServicioProcesarRecepcion(
    this._db,
    this._facturacion,
    this._pagos,
    this._precios,
    this._items,
    this._config, [
    this._sync,
  ]);

  /// Número de factura que se guarda cuando el proveedor no dio ninguna.
  ///
  /// En efectivo es el caso típico —te dejan el remito y listo— y el PO decidió
  /// que no puede trabar el procesamiento. Pero `facturas.numero_factura` es NOT
  /// NULL y hay una validación de duplicados por proveedor, así que hace falta
  /// un valor: se arma con el id de la recepción, que es único.
  ///
  /// "S/F" y no un número inventado que parezca real: quien mire la lista de
  /// facturas tiene que poder distinguir de un vistazo cuáles tienen respaldo
  /// fiscal y cuáles no.
  static String numeroSinFactura(String recepcionId) =>
      'S/F ${recepcionId.substring(0, recepcionId.length >= 8 ? 8 : recepcionId.length)}';

  /// #238 — Con qué TIPO se guarda lo adjuntado al procesar la recepción.
  ///
  /// El dominio distingue 'factura' (el documento de la deuda) de
  /// 'comprobante' (la prueba de que YO pagué), pero el wizard lo guardaba
  /// absolutamente todo como comprobante — aun sin pago. La regla es del
  /// switch:
  ///
  ///  - transferencia (típico): acá no se paga nada; lo que se adjunta ES la
  ///    factura del proveedor → 'factura'. El comprobante de la transferencia
  ///    se adjunta donde el pago ocurre, en "Registrar pago".
  ///  - efectivo: hubo pago al recibir; el papel prueba ese pago →
  ///    'comprobante', colgado de la recepción, donde la cuenta corriente lo
  ///    busca desde HU-069.
  ///
  /// Las filas HISTÓRICAS quedan como están (append-only): la cuenta corriente
  /// muestra los dos mundos juntos vía `listarRespaldosFinancieros`.
  static String tipoAdjuntoRecepcion({required bool pagadoEnEfectivo}) =>
      pagadoEnEfectivo ? TipoAdjunto.comprobante : TipoAdjunto.factura;

  /// Procesa la recepción.
  ///
  /// [lineas] es el detalle cargado en la pantalla: un renglón por insumo, con
  /// su precio neto unitario y su alícuota.
  ///
  /// [totalManual] es el total escrito a mano (HU-143). Si viene, PISA el total
  /// de la factura —que es lo que se le debe al proveedor— pero **no toca el
  /// costeo**: cada insumo queda con el precio de su renglón. La diferencia
  /// suele ser flete, percepciones o redondeos, y eso no es costo de mercadería:
  /// meterlo en el FoodCost encarecería las recetas por algo que no se comió.
  ///
  /// Como consecuencia buscada, `total_neto + iva_total` puede no dar
  /// `total_bruto`. Es la decisión del PO —el detalle y el total pueden decir
  /// cosas distintas— y es más honesto que inflar el IVA para que cierre: el
  /// IVA es un dato fiscal, no un cajón donde meter la diferencia.
  ///
  /// [pagadoEnEfectivo] hace que además se registre el pago, imputado a esta
  /// factura y con [fechaRecepcion] como fecha: es cuándo salió la plata de
  /// verdad, no cuándo se cargó.
  Future<ResultadoProcesamiento> procesar({
    required String negocioId,
    required String recepcionId,
    String? pedidoId,
    String? proveedorId,
    required List<LineaCosto> lineas,
    required DateTime fechaVencimiento,
    String? numeroFactura,
    double? totalManual,
    bool pagadoEnEfectivo = false,
    DateTime? fechaRecepcion,
    bool marcarPedidoFacturado = true,
    String origenPrecio = OrigenPrecio.compraManual,
    // HU-144: origen POR INSUMO — `compra_ocr` para las líneas cuya sugerencia
    // del escaneo quedó intacta, `compra_manual` para las editadas. Lo que no
    // esté en el mapa cae en [origenPrecio].
    Map<String, String> origenPorInsumo = const {},
    String? comprobanteUrl,
    String? comentario,
    String? usuarioId,
    Future<void> Function()? adjuntarEnTransaccion,
  }) async {
    if (lineas.isEmpty) {
      throw ArgumentError(
        'No hay ningún ítem para procesar: la factura quedaría sin detalle.',
      );
    }
    for (final l in lineas) {
      if (!esAlicuotaValida(l.alicuota)) {
        // Ataja la escala equivocada antes de que llegue a la base. Un 21 en vez
        // de 0.21 multiplicaría el IVA por cien sin que nada más lo note.
        throw ArgumentError(
          'Alícuota inválida (${l.alicuota}) en el insumo ${l.insumoId}. '
          'Se espera una fracción: 0, 0.105, 0.21 o 0.27.',
        );
      }
    }

    final resumen = ResumenIva.de(lineas);
    final totalBruto = Dinero.redondear(totalManual ?? resumen.total);
    if (totalBruto <= 0) {
      throw ArgumentError('El total de la factura debe ser mayor a cero.');
    }

    final numero = (numeroFactura ?? '').trim().isNotEmpty
        ? numeroFactura!.trim()
        : numeroSinFactura(recepcionId);

    final umbral = await _config.umbralAlerta(negocioId);

    Future<ResultadoProcesamiento> cuerpo() async {
      // 1. La factura. Nace la deuda y, si corresponde, el pedido pasa a
      //    'facturado'. Los tres importes: neto e IVA salen de los renglones;
      //    el bruto puede venir pisado a mano (ver el docstring).
      final factura = await _facturacion.registrarFactura(
        negocioId: negocioId,
        proveedorId: proveedorId,
        pedidoId: pedidoId,
        recepcionId: recepcionId,
        numeroFactura: numero,
        fechaVencimiento: fechaVencimiento,
        fechaFactura: fechaRecepcion,
        totalNeto: resumen.subtotalNeto,
        ivaTotal: resumen.iva,
        totalBruto: totalBruto,
        comprobanteUrl: comprobanteUrl,
        comentario: comentario,
        usuarioId: usuarioId,
        marcarPedidoFacturado: marcarPedidoFacturado,
      );

      // 2. El detalle. Es lo que hace verificable al trío de cabecera.
      await _items.crearLote(
        negocioId: negocioId,
        facturaId: factura.id,
        lineas: lineas,
      );

      // 3. El costeo, que es lo que se mudó desde la recepción.
      //
      //    `referenciaId` es el id de la RECEPCIÓN y no el de la factura, a
      //    propósito: mantiene la trazabilidad de siempre —el precio quedó
      //    ligado a la entrega que lo originó— y sostiene el invariante que
      //    protege esto de un doble conteo ("una recepción deja a lo sumo una
      //    fila de historial_precios por insumo con ese referenciaId").
      //
      //    La alícuota de cada línea viaja al historial: antes se guardaba
      //    siempre el 0.21 por defecto porque nadie la capturaba.
      for (final l in lineas) {
        await _precios.registrar(
          insumoId: l.insumoId,
          nuevoPrecio: l.netoUnitario,
          origen: origenPorInsumo[l.insumoId] ?? origenPrecio,
          proveedorId: proveedorId,
          referenciaId: recepcionId,
          usuarioId: usuarioId,
          ivaPorcentaje: l.alicuota,
          umbralAlerta: umbral,
        );
      }

      // 4. La plata, sólo si se pagó en mano.
      //
      //    Sin proveedor no hay a quién pagarle ni cuenta corriente donde
      //    asentarlo: la factura queda igual, pero el pago no se puede registrar.
      Pago? pago;
      if (pagadoEnEfectivo && proveedorId != null) {
        pago = await _pagos.registrarPago(
          negocioId: negocioId,
          proveedorId: proveedorId,
          monto: totalBruto,
          metodo: 'efectivo',
          // Idempotencia gratis (RN-015): si esto se reintenta, `registrarPago`
          // devuelve el pago que ya existe en vez de duplicar la salida de caja.
          referenciaExterna: 'recepcion:$recepcionId',
          fechaPago: fechaRecepcion,
          nota: 'Pago en efectivo al recibir',
          usuarioId: usuarioId,
          // Imputado a esta misma factura: el débito y el crédito quedan los dos
          // visibles en la cuenta corriente y el saldo del proveedor no se
          // mueve, que es la verdad de una compra pagada en el acto.
          imputaciones: [SolicitudImputacion(factura.id, totalBruto)],
        );
      }

      // 5. El estado final del pedido, y la corrección de la marca de efectivo.
      //
      //    `pagado` deja de ser letra muerta: la transición existía en la
      //    matriz y nadie la ejecutaba. Se escribe acá —y no en ServicioPagos—
      //    porque el alcance de #229 es SOLO el camino del efectivo; promover
      //    también a los pedidos cuya factura se salda después desde Pagos es
      //    otra decisión (la costura queda señalada allá).
      //
      //    La guarda por matriz saltea SIN error el caso parcial: si esta no
      //    era la última recepción del pedido, el estado no es 'facturado' y la
      //    transición a 'pagado' no corresponde todavía. No es un fallo, es el
      //    orden natural — no lo "arregles" con un throw.
      //
      //    Y el write-back de `tiene_efectivo`: el admin puede corregir al
      //    procesar lo que el cocinero marcó al recibir (decisión del PO,
      //    2026-08-27). Si difiere, se persiste para que el chip y el historial
      //    digan la verdad — sin esto, la lista de Pagos y la tarjeta seguirían
      //    mostrando la marca vieja.
      if (pedidoId != null) {
        final ped = await (_db.select(
          _db.pedidos,
        )..where((p) => p.id.equals(pedidoId))).getSingleOrNull();
        if (ped != null) {
          final marcarPagado =
              pago != null &&
              TransicionesPedido.puede(ped.estado, EstadosPedido.pagado);
          final corregirEfectivo = ped.tieneEfectivo != pagadoEnEfectivo;
          if (marcarPagado || corregirEfectivo) {
            await (_db.update(
              _db.pedidos,
            )..where((p) => p.id.equals(pedidoId))).write(
              PedidosCompanion(
                estado: marcarPagado
                    ? const Value(EstadosPedido.pagado)
                    : const Value.absent(),
                tieneEfectivo: corregirEfectivo
                    ? Value(pagadoEnEfectivo)
                    : const Value.absent(),
                estadoSync: const Value('pendiente'),
                fechaActualizacion: Value(DateTime.now()),
              ),
            );
            await _sync?.encolarMutacion(
              nombreTabla: 'pedidos',
              registroId: pedidoId,
              accion: 'UPDATE',
              datos: {
                'id': pedidoId,
                if (marcarPagado) 'estado': EstadosPedido.pagado,
                if (corregirEfectivo) 'tiene_efectivo': pagadoEnEfectivo,
              },
            );
          }
        }
      }

      // (#227) El comprobante, DENTRO de la transacción y ÚLTIMO. Si su
      // escritura falla, se revierten factura, renglones, costeo, pago y el
      // estado del pedido — que es lo que hace verdadero el "probá de nuevo" y
      // lo que impide la factura duplicada del segundo intento. Mismas reglas
      // que el hook de `ServicioRecepciones.registrar`: sólo escrituras cortas.
      await adjuntarEnTransaccion?.call();

      return ResultadoProcesamiento(
        factura: factura,
        pago: pago,
        insumosCosteados: lineas.length,
      );
    }

    return _tx.correr(cuerpo);
  }
}
