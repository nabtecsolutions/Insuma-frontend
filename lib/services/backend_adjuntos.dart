import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/repositorios/repositorio_adjuntos.dart';
import '../database/database.dart';
import '../utils/adjuntos/codificador_adjuntos.dart';
import '../utils/adjuntos/contenido_archivo.dart';
import '../utils/adjuntos/tipo_adjunto.dart';

/// Contrato del backend de almacenamiento de los BYTES de un adjunto (HU-066).
///
/// Es el PUNTO DE SWAP del backend de bytes: hoy los bytes viven en la propia tabla
/// `adjuntos` (BLOB local + base64 sincronizado por Outbox) mediante
/// [BackendAdjuntosBlob]; mañana podría ser Supabase Storage sin tocar el Service,
/// el Controlador ni la Vista, que solo dependen de esta interfaz.
abstract class BackendAdjuntos {
  /// Guarda el archivo y devuelve su metadato persistido. El padre es
  /// EXACTAMENTE UNO: [recepcionId] o [pagoId] (#238 — el comprobante de la
  /// transferencia cuelga del pago). [tipo] distingue remito (HU-066) de
  /// comprobante de pago (HU-069) y factura (HU-147).
  Future<Adjunto> guardar(
    ContenidoArchivo contenido, {
    required String negocioId,
    String? recepcionId,
    String? pagoId,
    String tipo,
  });

  /// Lista los COMPROBANTES colgados de un pago (#238).
  Future<List<Adjunto>> listarComprobantesPorPago(String pagoId);

  /// COMPROBANTES de los pagos que imputaron facturas del pedido (#240).
  Future<List<Adjunto>> listarComprobantesDePagosDelPedido(String pedidoId);

  /// COMPROBANTES de los pagos que imputaron la factura de la recepción (#240).
  Future<List<Adjunto>> listarComprobantesDePagosDeRecepcion(
    String recepcionId,
  );

  /// COMPROBANTES de las recepciones cuyas facturas imputó el pago (#244).
  Future<List<Adjunto>> listarComprobantesDeRecepcionesDelPago(String pagoId);

  /// Recupera los bytes de un adjunto (para previsualizar/abrir el remito).
  Future<Uint8List> obtenerContenido(String adjuntoId);

  /// Lista los REMITOS de una recepción.
  Future<List<Adjunto>> listarPorRecepcion(String recepcionId);

  /// Lista los REMITOS de TODAS las recepciones de un pedido (HU-067).
  Future<List<Adjunto>> listarPorPedido(String pedidoId);

  /// Lista los adjuntos de UN tipo exacto de todas las recepciones de un
  /// pedido (#234). El gating por rol vive en el Service.
  Future<List<Adjunto>> listarPorPedidoDeTipo(String pedidoId, String tipo);

  /// Lista los COMPROBANTES de pago de una recepción (HU-069).
  Future<List<Adjunto>> listarComprobantesPorRecepcion(String recepcionId);

  /// Lista las FACTURAS del proveedor de una recepción (HU-147).
  Future<List<Adjunto>> listarFacturasPorRecepcion(String recepcionId);
}

/// Implementación MVP: los bytes viven en la tabla `adjuntos` (BLOB local). La
/// sincronización multi-dispositivo la resuelve el Outbox del repositorio.
class BackendAdjuntosBlob implements BackendAdjuntos {
  final RepositorioAdjuntos _repo;

  /// #248: de dónde salen los bytes que NO están en el caché local. Null =
  /// solo local (tests, o dispositivo sin Supabase): un contenido no bajado
  /// da error claro en vez de red.
  final ObtenedorRemotoAdjuntos? _remoto;

  /// El mismo codificador del repositorio: acá se decodifica lo que llega
  /// del fetch bajo demanda (único otro punto además del pull).
  final CodificadorAdjuntos _codificador;

  const BackendAdjuntosBlob(
    this._repo, {
    this._remoto,
    this._codificador = const CodificadorAdjuntosBase64(),
  });

  @override
  Future<Adjunto> guardar(
    ContenidoArchivo contenido, {
    required String negocioId,
    String? recepcionId,
    String? pagoId,
    String tipo = TipoAdjunto.remito,
  }) => _repo.crear(
    contenido: contenido,
    negocioId: negocioId,
    recepcionId: recepcionId,
    pagoId: pagoId,
    tipo: tipo,
  );

  @override
  Future<List<Adjunto>> listarComprobantesPorPago(String pagoId) =>
      _repo.listarComprobantesPorPago(pagoId);

  @override
  Future<List<Adjunto>> listarComprobantesDePagosDelPedido(String pedidoId) =>
      _repo.listarComprobantesDePagosDelPedido(pedidoId);

  @override
  Future<List<Adjunto>> listarComprobantesDePagosDeRecepcion(
    String recepcionId,
  ) => _repo.listarComprobantesDePagosDeRecepcion(recepcionId);

  @override
  Future<List<Adjunto>> listarComprobantesDeRecepcionesDelPago(String pagoId) =>
      _repo.listarComprobantesDeRecepcionesDelPago(pagoId);

  @override
  Future<Uint8List> obtenerContenido(String adjuntoId) async {
    final adj = await _repo.porId(adjuntoId);
    if (adj == null) {
      throw StateError('Adjunto inexistente: $adjuntoId');
    }
    // Caché local primero (#248): los adjuntos creados en este dispositivo y
    // los ya vistos alguna vez tienen sus bytes acá — cero red, cero decode.
    final locales = adj.contenido;
    if (locales != null) return locales;

    // Contenido no bajado: el pull trae solo metadatos desde #248, así que la
    // PRIMERA vista de una foto ajena la pide al servidor y la deja cacheada
    // — las siguientes (incluso offline) salen del caché de arriba.
    final remoto = _remoto;
    if (remoto == null) {
      throw StateError(
        'El adjunto $adjuntoId no está en este dispositivo y no hay conexión '
        'con el servidor para bajarlo.',
      );
    }
    final base64Texto = await remoto.contenidoBase64(adjuntoId);
    if (base64Texto == null || base64Texto.isEmpty) {
      throw StateError(
        'El servidor no tiene contenido para el adjunto $adjuntoId.',
      );
    }
    final bytes = _codificador.decodificar(base64Texto);
    await _repo.guardarContenido(adjuntoId, bytes);
    return bytes;
  }

  @override
  Future<List<Adjunto>> listarPorRecepcion(String recepcionId) =>
      _repo.listarPorRecepcion(recepcionId);

  @override
  Future<List<Adjunto>> listarPorPedido(String pedidoId) =>
      _repo.listarPorPedido(pedidoId);

  @override
  Future<List<Adjunto>> listarPorPedidoDeTipo(String pedidoId, String tipo) =>
      _repo.listarPorPedidoDeTipo(pedidoId, tipo);

  @override
  Future<List<Adjunto>> listarComprobantesPorRecepcion(String recepcionId) =>
      _repo.listarComprobantesPorRecepcion(recepcionId);

  @override
  Future<List<Adjunto>> listarFacturasPorRecepcion(String recepcionId) =>
      _repo.listarFacturasPorRecepcion(recepcionId);
}

/// #248: la fuente REMOTA de los bytes de un adjunto cuyo contenido todavía
/// no está en este dispositivo. Interfaz aparte porque es la ÚNICA pieza del
/// backend que habla red: los tests inyectan una falsa y el resto sigue
/// siendo local puro.
abstract class ObtenedorRemotoAdjuntos {
  /// El `contenido_base64` del adjunto en el servidor, o null si no existe
  /// (o la RLS no lo deja ver).
  Future<String?> contenidoBase64(String adjuntoId);
}

/// Implementación PostgREST: pide UNA columna de UNA fila — exactamente la
/// foto que el visor está por mostrar, nada más. La RLS `see_adjuntos` /
/// `superadmin_read_adjuntos` autoriza igual que autorizaba al pull.
class ObtenedorRemotoAdjuntosSupabase implements ObtenedorRemotoAdjuntos {
  final SupabaseClient _supabase;

  const ObtenedorRemotoAdjuntosSupabase(this._supabase);

  @override
  Future<String?> contenidoBase64(String adjuntoId) async {
    final fila = await _supabase
        .from('adjuntos')
        .select('contenido_base64')
        .eq('id', adjuntoId)
        .maybeSingle();
    return fila?['contenido_base64'] as String?;
  }
}
