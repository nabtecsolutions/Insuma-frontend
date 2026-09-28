import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/database.dart';
import '../../utils/adjuntos/codificador_adjuntos.dart';
import '../../utils/adjuntos/contenido_archivo.dart';
import '../../utils/adjuntos/tipo_adjunto.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio de adjuntos (HU-066).
///
/// Es la ÚNICA capa que toca la persistencia de adjuntos: escribe el BLOB en el
/// store local (Drift) y encola la mutación hacia Supabase vía Outbox (los bytes
/// viajan como base64 mediante [CodificadorAdjuntos]). Nadie más codifica/decodifica
/// ni accede a la tabla.
abstract class RepositorioAdjuntos {
  /// Persiste un archivo y lo encola para sincronizar. El padre es EXACTAMENTE
  /// UNO: [recepcionId] (remitos HU-066, comprobantes HU-069, facturas HU-147)
  /// o [pagoId] (#238: el comprobante de la transferencia — un pago puede
  /// imputar varias facturas o ser un anticipo, no hay recepción única).
  /// Ambos o ninguno → [ArgumentError]; el CHECK del servidor lo espeja.
  Future<Adjunto> crear({
    required ContenidoArchivo contenido,
    required String negocioId,
    String? recepcionId,
    String? pagoId,
    String tipo,
  });

  /// COMPROBANTES colgados de un pago (#238).
  Future<List<Adjunto>> listarComprobantesPorPago(String pagoId);

  /// COMPROBANTES de los PAGOS que imputaron facturas de las recepciones de un
  /// pedido (#240). Es el puente que le faltaba a #234: el comprobante de la
  /// transferencia cuelga de `pago_id` (recepción NULL), así que el join por
  /// recepción del visor de pedido no lo veía. Cadena: adjunto → imputación →
  /// factura → recepción → pedido.
  Future<List<Adjunto>> listarComprobantesDePagosDelPedido(String pedidoId);

  /// COMPROBANTES de los PAGOS que imputaron la factura de una recepción
  /// (#240): lo que le faltaba al respaldo financiero de la cuenta corriente.
  Future<List<Adjunto>> listarComprobantesDePagosDeRecepcion(
    String recepcionId,
  );

  /// COMPROBANTES colgados de las RECEPCIONES cuyas facturas imputó un pago
  /// (#244): el espejo INVERSO del puente de #240. Existe por el efectivo —
  /// su comprobante se adjunta al procesar y cuelga de la recepción, pero el
  /// clip del movimiento pregunta por el pago. Cadena: pago → imputación →
  /// factura → recepción → adjuntos tipo 'comprobante'.
  Future<List<Adjunto>> listarComprobantesDeRecepcionesDelPago(String pagoId);

  /// REMITOS de una recepción (excluye comprobantes). Los listados de remito
  /// (recepción, historial, "tiene remito") pasan por acá.
  Future<List<Adjunto>> listarPorRecepcion(String recepcionId);

  /// REMITOS de TODAS las recepciones de un pedido (join por `recepcion.pedidoId`).
  Future<List<Adjunto>> listarPorPedido(String pedidoId);

  /// Adjuntos de UN [tipo] exacto ('factura', 'comprobante') de todas las
  /// recepciones de un pedido (#234). Mismo join que [listarPorPedido] con el
  /// predicado de tipo parametrizado; quién puede ver cada tipo lo decide el
  /// SERVICE (gating por rol), no esta capa.
  Future<List<Adjunto>> listarPorPedidoDeTipo(String pedidoId, String tipo);

  /// COMPROBANTES de pago de una recepción (HU-069). Como la recepción y su factura
  /// son 1:1 (HU-067), son los comprobantes de esa factura.
  Future<List<Adjunto>> listarComprobantesPorRecepcion(String recepcionId);

  /// FACTURAS del proveedor adjuntas a una recepción (HU-147), en orden
  /// cronológico: la última es la vigente y las anteriores quedan como rastro.
  Future<List<Adjunto>> listarFacturasPorRecepcion(String recepcionId);

  /// Devuelve un adjunto por id (o null).
  Future<Adjunto?> porId(String id);

  /// #248: escribe en el CACHÉ local los bytes recién bajados del servidor.
  /// Escritura LOCAL pura — sin Outbox: los bytes vinieron DEL servidor, no
  /// hay nada que subir. Es la única otra mutación permitida de un adjunto
  /// además de [actualizarDatosOcr], y solo rellena un `contenido` NULL.
  Future<void> guardarContenido(String adjuntoId, Uint8List bytes);

  /// HU-068: escribe (o borra, con null) el resultado del reconocimiento en
  /// `datosOcr`. ÚNICA mutación permitida de un adjunto: los bytes, el tipo y
  /// el resto de la fila siguen siendo append-only por contrato. El payload del
  /// UPDATE encolado es mínimo (`{id, datos_ocr}`). Devuelve el adjunto
  /// actualizado, o lanza [StateError] si no existe.
  Future<Adjunto> actualizarDatosOcr(String adjuntoId, String? datosOcrJson);
}

/// Implementación local (Drift) con encolado de sincronización hacia Supabase.
class RepositorioAdjuntosDrift extends RepositorioSincronizable
    implements RepositorioAdjuntos {
  /// El codificador se inyecta (por defecto base64). Es el ÚNICO lugar, junto al
  /// pull de sync, donde se (de)codifican los bytes del adjunto.
  final CodificadorAdjuntos _codificador;

  RepositorioAdjuntosDrift(
    super.db,
    super.sync, {
    this._codificador = const CodificadorAdjuntosBase64(),
  });

  static const String _tabla = 'adjuntos';

  @override
  Future<Adjunto> crear({
    required ContenidoArchivo contenido,
    required String negocioId,
    String? recepcionId,
    String? pagoId,
    String tipo = TipoAdjunto.remito,
  }) async {
    // Exactamente-uno, validado ACÁ y no como CHECK de SQLite (la migración
    // que recrea la tabla no puede fallar por una fila legado). El CHECK real
    // vive en el servidor (#238).
    if ((recepcionId == null) == (pagoId == null)) {
      throw ArgumentError(
        'Un adjunto cuelga de UNA entidad: recepcionId O pagoId.',
      );
    }
    final id = const Uuid().v4();
    await db
        .into(db.adjuntos)
        .insert(
          AdjuntosCompanion.insert(
            id: id,
            negocioId: negocioId,
            recepcionId: Value(recepcionId),
            pagoId: Value(pagoId),
            nombreArchivo: contenido.nombreArchivo,
            mimeType: contenido.mimeType,
            tamanioBytes: Value(contenido.tamanioBytes),
            contenido: Value(contenido.bytes),
            tipo: Value(tipo),
            fechaCreacion: Value(DateTime.now()),
          ),
        );
    final creado = await porId(id);
    await encolarInsert(_tabla, id, _aMapa(creado!));
    return creado;
  }

  @override
  Future<List<Adjunto>> listarComprobantesPorPago(String pagoId) {
    return (db.select(db.adjuntos)
          ..where(
            (a) =>
                a.pagoId.equals(pagoId) &
                a.tipo.equals(TipoAdjunto.comprobante),
          )
          ..orderBy([(a) => OrderingTerm(expression: a.fechaCreacion)]))
        .get();
  }

  @override
  Future<List<Adjunto>> listarComprobantesDePagosDelPedido(String pedidoId) {
    final query =
        db.select(db.adjuntos).join([
            innerJoin(
              db.imputacionesPago,
              db.imputacionesPago.pagoId.equalsExp(db.adjuntos.pagoId),
            ),
            innerJoin(
              db.facturas,
              db.facturas.id.equalsExp(db.imputacionesPago.facturaId),
            ),
            innerJoin(
              db.recepciones,
              db.recepciones.id.equalsExp(db.facturas.recepcionId),
            ),
          ])
          ..where(
            db.recepciones.pedidoId.equals(pedidoId) &
                db.adjuntos.tipo.equals(TipoAdjunto.comprobante),
          )
          ..orderBy([OrderingTerm(expression: db.adjuntos.fechaCreacion)]);
    return query
        .map((row) => row.readTable(db.adjuntos))
        .get()
        .then(_sinRepetidos);
  }

  @override
  Future<List<Adjunto>> listarComprobantesDePagosDeRecepcion(
    String recepcionId,
  ) {
    final query =
        db.select(db.adjuntos).join([
            innerJoin(
              db.imputacionesPago,
              db.imputacionesPago.pagoId.equalsExp(db.adjuntos.pagoId),
            ),
            innerJoin(
              db.facturas,
              db.facturas.id.equalsExp(db.imputacionesPago.facturaId),
            ),
          ])
          ..where(
            db.facturas.recepcionId.equals(recepcionId) &
                db.adjuntos.tipo.equals(TipoAdjunto.comprobante),
          )
          ..orderBy([OrderingTerm(expression: db.adjuntos.fechaCreacion)]);
    return query
        .map((row) => row.readTable(db.adjuntos))
        .get()
        .then(_sinRepetidos);
  }

  @override
  Future<List<Adjunto>> listarComprobantesDeRecepcionesDelPago(String pagoId) {
    final query =
        db.select(db.adjuntos).join([
            innerJoin(
              db.facturas,
              db.facturas.recepcionId.equalsExp(db.adjuntos.recepcionId),
            ),
            innerJoin(
              db.imputacionesPago,
              db.imputacionesPago.facturaId.equalsExp(db.facturas.id),
            ),
          ])
          ..where(
            db.imputacionesPago.pagoId.equals(pagoId) &
                db.adjuntos.tipo.equals(TipoAdjunto.comprobante),
          )
          ..orderBy([OrderingTerm(expression: db.adjuntos.fechaCreacion)]);
    return query
        .map((row) => row.readTable(db.adjuntos))
        .get()
        .then(_sinRepetidos);
  }

  /// El join por imputaciones puede traer el MISMO adjunto varias veces: un
  /// pago que imputa dos facturas del mismo pedido sale una vez por imputación.
  /// Se compacta por id conservando el orden (los `Map` de Dart lo garantizan).
  List<Adjunto> _sinRepetidos(List<Adjunto> filas) {
    final porId = <String, Adjunto>{};
    for (final a in filas) {
      porId.putIfAbsent(a.id, () => a);
    }
    return porId.values.toList(growable: false);
  }

  /// Predicado "es un remito": excluye TODOS los tipos financieros, no sólo el
  /// comprobante. Tolerante a null: las filas históricas / bajadas de Supabase
  /// sin `tipo` cuentan como remito.
  ///
  /// Se compara contra el conjunto [TipoAdjunto.financieros] y no contra el
  /// literal 'comprobante': con la factura de HU-147 sumada, un `!= comprobante`
  /// la habría dejado pasar como remito y se vería en el visor de remitos —y con
  /// ella, información financiera que el cocinero no debe ver.
  Expression<bool> _esRemito($AdjuntosTable a) =>
      a.tipo.isNull() | a.tipo.isIn(TipoAdjunto.financieros.toList()).not();

  @override
  Future<List<Adjunto>> listarPorRecepcion(String recepcionId) {
    return (db.select(db.adjuntos)
          ..where((a) => a.recepcionId.equals(recepcionId) & _esRemito(a))
          ..orderBy([(a) => OrderingTerm(expression: a.fechaCreacion)]))
        .get();
  }

  @override
  Future<List<Adjunto>> listarPorPedido(String pedidoId) =>
      _listarPorPedidoDonde(pedidoId, _esRemito(db.adjuntos));

  @override
  Future<List<Adjunto>> listarPorPedidoDeTipo(String pedidoId, String tipo) =>
      _listarPorPedidoDonde(pedidoId, db.adjuntos.tipo.equals(tipo));

  /// Join adjuntos → recepciones para filtrar por el pedido dueño de la
  /// recepción, con el predicado de tipo parametrizado (#234). Cronológico.
  Future<List<Adjunto>> _listarPorPedidoDonde(
    String pedidoId,
    Expression<bool> predicadoTipo,
  ) {
    final query =
        db.select(db.adjuntos).join([
            innerJoin(
              db.recepciones,
              db.recepciones.id.equalsExp(db.adjuntos.recepcionId),
            ),
          ])
          ..where(db.recepciones.pedidoId.equals(pedidoId) & predicadoTipo)
          ..orderBy([OrderingTerm(expression: db.adjuntos.fechaCreacion)]);
    return query.map((row) => row.readTable(db.adjuntos)).get();
  }

  @override
  Future<List<Adjunto>> listarComprobantesPorRecepcion(String recepcionId) {
    return (db.select(db.adjuntos)
          ..where(
            (a) =>
                a.recepcionId.equals(recepcionId) &
                a.tipo.equals(TipoAdjunto.comprobante),
          )
          ..orderBy([(a) => OrderingTerm(expression: a.fechaCreacion)]))
        .get();
  }

  @override
  Future<List<Adjunto>> listarFacturasPorRecepcion(String recepcionId) {
    return (db.select(db.adjuntos)
          ..where(
            (a) =>
                a.recepcionId.equals(recepcionId) &
                a.tipo.equals(TipoAdjunto.factura),
          )
          // Orden ascendente: la ÚLTIMA es la vigente. Cargar una factura nueva
          // no pisa la anterior —son filas—, así que el rastro queda entero.
          ..orderBy([(a) => OrderingTerm(expression: a.fechaCreacion)]))
        .get();
  }

  @override
  Future<Adjunto?> porId(String id) =>
      (db.select(db.adjuntos)..where((a) => a.id.equals(id))).getSingleOrNull();

  @override
  Future<void> guardarContenido(String adjuntoId, Uint8List bytes) async {
    await (db.update(db.adjuntos)..where((a) => a.id.equals(adjuntoId))).write(
      AdjuntosCompanion(contenido: Value(bytes)),
    );
  }

  @override
  Future<Adjunto> actualizarDatosOcr(String adjuntoId, String? datosOcrJson) {
    // Atómico (HU-079): write local + encolado en UNA transacción — un crash a
    // mitad de camino no deja una fila 'pendiente' zombi sin ítem en cola (que
    // además bloquearía para siempre el pull del OCR de esa fila).
    Future<Adjunto> cuerpo() async {
      final previo = await porId(adjuntoId);
      if (previo == null) {
        throw StateError('El adjunto $adjuntoId no existe.');
      }
      await (db.update(
        db.adjuntos,
      )..where((a) => a.id.equals(adjuntoId))).write(
        AdjuntosCompanion(
          datosOcr: Value(datosOcrJson),
          estadoSync: const Value('pendiente'),
        ),
      );
      final actualizado = await porId(adjuntoId);

      // Si el INSERT del adjunto AÚN espera en la cola, el OCR viaja fusionado
      // DENTRO de su payload: un UPDATE suelto podría adelantarse al INSERT en
      // el server (0 filas + versionBase null = "éxito" falso, A07) y perderse
      // en silencio; peor, el retry del INSERT subiría datos_ocr null y el
      // próximo pull borraría el OCR local.
      final insertPendiente =
          await (db.select(db.colaSincronizacion)..where(
                (c) =>
                    c.nombreTabla.equals(_tabla) &
                    c.registroId.equals(adjuntoId) &
                    c.accion.equals('INSERT'),
              ))
              .getSingleOrNull();
      if (insertPendiente != null) {
        final payload =
            jsonDecode(insertPendiente.payload) as Map<String, dynamic>;
        payload['datos_ocr'] = datosOcrJson;
        await (db.update(
          db.colaSincronizacion,
        )..where((c) => c.id.equals(insertPendiente.id))).write(
          ColaSincronizacionCompanion(payload: Value(jsonEncode(payload))),
        );
      } else {
        // Payload MÍNIMO: nunca re-sube los bytes (contenido_base64 intacto)
        // ni el tipo — sólo el resultado del reconocimiento.
        await encolarUpdate(_tabla, adjuntoId, {
          'id': adjuntoId,
          'datos_ocr': datosOcrJson,
        });
      }
      return actualizado!;
    }

    final s = sync;
    return s != null ? s.enTransaccion(cuerpo) : db.transaction(cuerpo);
  }

  /// Mapeo a snake_case para Supabase (Outbox). Los bytes viajan como base64 en
  /// `contenido_base64` (columna `text` remota); la (de)codificación NO sale de acá.
  Map<String, dynamic> _aMapa(Adjunto a) {
    // #248: `contenido` nullable significa "no bajado del servidor" — un
    // adjunto así JAMÁS se sube (los bytes ya viven allá). Este mapa solo lo
    // arma `crear`, cuyo contenido nunca es null; si algún día otro camino
    // llegara acá sin bytes, mejor reventar acá que subir una fila vacía que
    // el pull de otro dispositivo descartaría en silencio.
    final bytes = a.contenido;
    if (bytes == null) {
      throw StateError(
        'El adjunto ${a.id} no tiene bytes locales: no hay nada que subir.',
      );
    }
    return {
      'id': a.id,
      'negocio_id': a.negocioId,
      'recepcion_id': a.recepcionId,
      'pago_id': a.pagoId,
      'nombre_archivo': a.nombreArchivo,
      'mime_type': a.mimeType,
      'tamanio_bytes': a.tamanioBytes,
      'contenido_base64': _codificador.codificar(bytes),
      'tipo': a.tipo,
      'datos_ocr': a.datosOcr,
    };
  }
}
