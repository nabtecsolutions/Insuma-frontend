import 'dart:typed_data';

import '../database/database.dart';
import '../utils/adjuntos/contenido_archivo.dart';
import '../utils/adjuntos/procesador_imagenes.dart';
import '../utils/adjuntos/tipo_adjunto.dart';
import 'backend_adjuntos.dart';

/// Resultado de adjuntar: éxito con el adjunto persistido, o un mensaje de error de
/// validación listo para mostrar en la UI.
class ResultadoAdjunto {
  final Adjunto? adjunto;
  final String? error;

  const ResultadoAdjunto._(this.adjunto, this.error);
  factory ResultadoAdjunto.ok(Adjunto a) => ResultadoAdjunto._(a, null);
  factory ResultadoAdjunto.error(String mensaje) =>
      ResultadoAdjunto._(null, mensaje);

  bool get esOk => adjunto != null;
}

/// El archivo no pasa las reglas del adjunto (#227).
///
/// Es una EXCEPCIÓN y no un `ResultadoAdjunto.error` porque marca el camino
/// nuevo: [ServicioAdjuntos.preparar] se corre ANTES de abrir la transacción,
/// donde un error tiene que cortar el flujo, no viajar en un campo que el
/// llamador puede ignorar — que es exactamente cómo nació este bug.
class AdjuntoInvalidoException implements Exception {
  final String mensaje;

  /// Nombre del archivo, para que el mensaje diga CUÁL falló cuando hay varios.
  final String nombreArchivo;

  const AdjuntoInvalidoException(this.mensaje, this.nombreArchivo);

  @override
  String toString() => '$nombreArchivo: $mensaje';
}

/// Los CONTEXTOS desde los que la UI pide adjuntos (#244).
///
/// Cada botón/visor de la app corresponde a una de estas filas, y la política
/// de qué tipos junta, qué puentes usa y cómo degrada sin permiso de finanzas
/// vive en UN solo lugar: [ServicioAdjuntos.listarAdjuntos]. Antes cada vista
/// componía su unión a mano, y así se escaparon cuatro huecos del mismo patrón
/// (#209, #238, #240 y el efectivo de #244) — siempre en producción, de a uno.
enum ContextoAdjuntos {
  /// Los remitos de una recepción (HU-066/067). Sin datos financieros: es la
  /// única fila que el cocinero ve completa.
  remitosDeRecepcion,

  /// Los papeles de una entrega (#209, ampliado en #244): remitos → facturas
  /// → comprobantes de esa recepción. El tercer grupo cierra dos huecos: las
  /// facturas del wizard viejo (guardadas como tipo 'comprobante') y el papel
  /// del efectivo, visibles al ir a pagar.
  documentosDeRecepcion,

  /// El respaldo financiero de una recepción (#238): facturas → comprobantes
  /// propios → comprobantes de los pagos que imputaron su factura (#240).
  respaldoFinancieroDeRecepcion,

  /// Los comprobantes de un pago (#238/#244): los colgados del pago MÁS los
  /// de las recepciones cuyas facturas imputó (el efectivo).
  comprobantesDelPago,

  /// Todos los papeles de un pedido (#234): remitos de cada entrega y, con
  /// permiso, facturas y comprobantes (de recepciones y de pagos).
  adjuntosDelPedido,
}

/// Servicio de negocio de adjuntos/remitos (HU-066).
///
/// Concentra la lógica: validación de tipo/tamaño y optimización de imágenes, y
/// delega el "dónde viven los bytes" en [BackendAdjuntos]. NO toca la base de datos
/// ni (de)codifica bytes: orquesta interfaces. La regla "remito obligatorio cuando
/// el desenlace es Recibido" la aplica su consumidor (HU-064), no este servicio.
class ServicioAdjuntos {
  final BackendAdjuntos _backend;
  final ProcesadorImagenes _procesador;

  ServicioAdjuntos(this._backend, this._procesador);

  /// Valida [contenido], optimiza si es imagen y lo persiste contra [recepcionId].
  /// [tipo] distingue remito (HU-066, por defecto) de comprobante de pago (HU-069).
  ///
  /// Se conserva con su contrato intacto —devuelve [ResultadoAdjunto] en vez de
  /// lanzar— porque HU-147 (adjuntar la factura a una recepción cerrada) lo usa
  /// así. Internamente ya es la composición de [preparar] + [guardarPreparado].
  Future<ResultadoAdjunto> adjuntar({
    required ContenidoArchivo contenido,
    required String negocioId,
    String? recepcionId,
    String? pagoId,
    String tipo = TipoAdjunto.remito,
  }) async {
    final ContenidoArchivo listo;
    try {
      listo = await preparar(contenido);
    } on AdjuntoInvalidoException catch (e) {
      return ResultadoAdjunto.error(e.mensaje);
    }
    final adj = await guardarPreparado(
      listo,
      negocioId: negocioId,
      recepcionId: recepcionId,
      pagoId: pagoId,
      tipo: tipo,
    );
    return ResultadoAdjunto.ok(adj);
  }

  /// TODO lo que puede fallar POR EL ARCHIVO, sin tocar la base (#227).
  ///
  /// Valida, comprime si es imagen y vuelve a validar. Devuelve el contenido
  /// listo para escribir, o lanza [AdjuntoInvalidoException].
  ///
  /// Existe separado para que el llamador pueda correrlo ANTES de abrir la
  /// transacción de la recepción. Adentro sólo puede quedar el INSERT: comprimir
  /// una imagen de varios MB con una transacción de escritura abierta es
  /// sostener el único escritor de SQLite durante un trabajo que no lo necesita
  /// —y en Flutter Web, sin isolates, es peor todavía—. Y una revalidación que
  /// rechaza el archivo COMPRIMIDO no puede hacer fracasar el registro de una
  /// entrega física que ya ocurrió.
  Future<ContenidoArchivo> preparar(ContenidoArchivo contenido) async {
    final error = validar(contenido);
    if (error != null) {
      throw AdjuntoInvalidoException(error, contenido.nombreArchivo);
    }

    final optimizado = await _procesador.optimizar(contenido);

    // Revalida tras comprimir (defensa en profundidad: el resultado nunca debería
    // crecer, pero el tope se controla igual).
    final errorPost = validar(optimizado);
    if (errorPost != null) {
      throw AdjuntoInvalidoException(errorPost, contenido.nombreArchivo);
    }
    return optimizado;
  }

  /// Escribe un contenido YA preparado. Es lo único que corre dentro de la
  /// transacción: si falla, falló la base de verdad, y ahí revertir es correcto.
  Future<Adjunto> guardarPreparado(
    ContenidoArchivo preparado, {
    required String negocioId,
    String? recepcionId,
    String? pagoId,
    String tipo = TipoAdjunto.remito,
  }) => _backend.guardar(
    preparado,
    negocioId: negocioId,
    recepcionId: recepcionId,
    pagoId: pagoId,
    tipo: tipo,
  );

  /// Fachada de [listarAdjuntos] para el clip del movimiento del pago. Las
  /// pantallas que la llaman viven detrás de `GuardiaPermiso(verFinanzas)`.
  Future<List<Adjunto>> listarComprobantesDePago(String pagoId) =>
      listarAdjuntos(
        ContextoAdjuntos.comprobantesDelPago,
        pagoId,
        puedeVerFinanzas: true,
      );

  // ── La política de agregación, en UN lugar (#244) ─────────────────────────

  /// El punto único de agregación: la UI pide por CONTEXTO y la política
  /// resuelve qué tipos junta, qué puentes usa y cómo degrada por rol.
  ///
  /// El gating vive ACÁ para TODOS los contextos —lo que el docstring de #234
  /// prometía y solo el pedido cumplía—: sin permiso de finanzas los
  /// contextos financieros degradan (a solo remitos, o a vacío) sin depender
  /// de que cada botón se acuerde de ocultarse. Es el espejo local de las RLS
  /// de HU-110/114/147.
  ///
  /// El ORDEN de cada fila es el de la operación real (#209): qué llegó
  /// (remitos) → qué te cobran (facturas) → cómo lo pagaste (comprobantes),
  /// cada grupo cronológico. Las fuentes de cada unión son disjuntas por la
  /// regla exactamente-uno (recepción XOR pago): no hay duplicados posibles.
  Future<List<Adjunto>> listarAdjuntos(
    ContextoAdjuntos contexto,
    String id, {
    required bool puedeVerFinanzas,
  }) {
    switch (contexto) {
      case ContextoAdjuntos.remitosDeRecepcion:
        return _backend.listarPorRecepcion(id);
      case ContextoAdjuntos.documentosDeRecepcion:
        if (!puedeVerFinanzas) return _backend.listarPorRecepcion(id);
        return _documentosDeRecepcion(id);
      case ContextoAdjuntos.respaldoFinancieroDeRecepcion:
        if (!puedeVerFinanzas) return Future.value(const []);
        return _respaldoFinancieroDeRecepcion(id);
      case ContextoAdjuntos.comprobantesDelPago:
        if (!puedeVerFinanzas) return Future.value(const []);
        return _comprobantesDelPago(id);
      case ContextoAdjuntos.adjuntosDelPedido:
        if (!puedeVerFinanzas) return _backend.listarPorPedido(id);
        return _todoElPedido(id);
    }
  }

  /// #238/#244: transferencia de "Registrar pago" + el efectivo colgado de
  /// las recepciones cuyas facturas este pago imputó (puente inverso a #240).
  Future<List<Adjunto>> _comprobantesDelPago(String pagoId) async {
    final listas = await Future.wait([
      _backend.listarComprobantesPorPago(pagoId),
      _backend.listarComprobantesDeRecepcionesDelPago(pagoId),
    ]);
    return [...listas[0], ...listas[1]];
  }

  /// Reglas de negocio del adjunto: tipo permitido y tope de tamaño. Devuelve el
  /// mensaje de error, o `null` si es válido. Es pública para que el controlador
  /// valide la captura ANTES de hacer staging, siempre a través del servicio.
  String? validar(ContenidoArchivo c) {
    if (!kTiposRemitoPermitidos.contains(c.mimeType)) {
      return 'Tipo de archivo no permitido. Adjuntá un PDF, JPG o PNG.';
    }
    if (c.tamanioBytes <= 0) {
      return 'El archivo está vacío.';
    }
    if (c.tamanioBytes > kMaxBytesRemito) {
      return 'El archivo supera el tamaño máximo permitido (5 MB).';
    }
    return null;
  }

  Future<List<Adjunto>> listarPorRecepcion(String recepcionId) =>
      _backend.listarPorRecepcion(recepcionId);

  /// Remitos de todas las recepciones de un pedido (HU-067): para verlos desde el
  /// historial de pedidos, no sólo desde una recepción puntual.
  Future<List<Adjunto>> listarPorPedido(String pedidoId) =>
      _backend.listarPorPedido(pedidoId);

  /// Comprobantes de pago de una recepción/factura (HU-069).
  Future<List<Adjunto>> listarComprobantes(String recepcionId) =>
      _backend.listarComprobantesPorRecepcion(recepcionId);

  /// Facturas del proveedor adjuntas a una recepción (HU-147), en orden
  /// cronológico: la última es la vigente.
  Future<List<Adjunto>> listarFacturas(String recepcionId) =>
      _backend.listarFacturasPorRecepcion(recepcionId);

  /// Fachada de [listarAdjuntos] para los botones "Documentos" (#209): las
  /// pantallas que la llaman viven detrás de `GuardiaPermiso(verFinanzas)`.
  Future<List<Adjunto>> listarDocumentos(String recepcionId) => listarAdjuntos(
    ContextoAdjuntos.documentosDeRecepcion,
    recepcionId,
    puedeVerFinanzas: true,
  );

  /// #209, ampliado en #244: remitos → facturas → comprobantes de la entrega.
  ///
  /// El tercer grupo es el cambio de #244 y cierra dos huecos de una: las
  /// facturas del wizard viejo (guardadas como tipo 'comprobante', invisibles
  /// justo bajo un botón que prometía "la factura y el remito") y el papel
  /// del efectivo, que quien va a pagar necesita ver.
  Future<List<Adjunto>> _documentosDeRecepcion(String recepcionId) async {
    final listas = await Future.wait([
      _backend.listarPorRecepcion(recepcionId),
      _backend.listarFacturasPorRecepcion(recepcionId),
      _backend.listarComprobantesPorRecepcion(recepcionId),
    ]);
    return [...listas[0], ...listas[1], ...listas[2]];
  }

  /// FACTURA(s) y COMPROBANTE(s) de pago de una recepción, juntos (#238).
  ///
  /// Existe porque el wizard de procesar guardó HISTÓRICAMENTE todo como
  /// 'comprobante', y desde #238 la transferencia guarda 'factura': la cuenta
  /// corriente tiene que mostrar los dos mundos bajo un solo botón, sin perder
  /// lo viejo. Orden operativo: la deuda (factura) antes que su pago
  /// (comprobante) — mismo criterio que [listarDocumentos] (#209).
  ///
  /// El tercer grupo (#240) son los comprobantes que cuelgan de los PAGOS que
  /// imputaron la factura de esta recepción: lo adjuntado en "Registrar pago"
  /// tiene recepción NULL, y sin el puente por imputaciones era invisible
  /// justo en el botón que promete mostrar cómo se pagó.
  ///
  /// Fachada de [listarAdjuntos]; su pantalla vive tras `GuardiaPermiso`.
  Future<List<Adjunto>> listarRespaldosFinancieros(String recepcionId) =>
      listarAdjuntos(
        ContextoAdjuntos.respaldoFinancieroDeRecepcion,
        recepcionId,
        puedeVerFinanzas: true,
      );

  Future<List<Adjunto>> _respaldoFinancieroDeRecepcion(
    String recepcionId,
  ) async {
    final listas = await Future.wait([
      _backend.listarFacturasPorRecepcion(recepcionId),
      _backend.listarComprobantesPorRecepcion(recepcionId),
      _backend.listarComprobantesDePagosDeRecepcion(recepcionId),
    ]);
    return [...listas[0], ...listas[1], ...listas[2]];
  }

  /// TODOS los adjuntos de un pedido (#234): los remitos de cada entrega y,
  /// SOLO con permiso de finanzas, las facturas y los comprobantes de pago.
  ///
  /// El gating vive ACÁ y no en la pantalla: comprobante y factura son
  /// información financiera (HU-110/114/147, con RLS espejo en el backend), y
  /// una vista que los una tiene que degradar a solo-remitos para el cocinero
  /// sin depender de que cada botón se acuerde de ocultarse.
  ///
  /// El ORDEN extiende el criterio operativo de [listarDocumentos] (#209) al
  /// pedido entero: qué llegó (remitos) → qué te cobran (facturas) → cómo lo
  /// pagaste (comprobantes), cada grupo cronológico.
  ///
  /// "Cómo lo pagaste" son DOS fuentes (#240): los comprobantes colgados de
  /// las recepciones (wizard de procesar, HU-069) y los colgados de los PAGOS
  /// que imputaron facturas del pedido (#238, "Registrar pago"). Los segundos
  /// tienen recepción NULL, así que el join por recepción no los trae: sin el
  /// puente por imputaciones desaparecían de esta vista.
  /// Fachada de [listarAdjuntos]: la única que transporta el flag de la
  /// pantalla, porque el historial lo abren los dos roles.
  Future<List<Adjunto>> listarAdjuntosDePedido(
    String pedidoId, {
    required bool puedeVerFinanzas,
  }) => listarAdjuntos(
    ContextoAdjuntos.adjuntosDelPedido,
    pedidoId,
    puedeVerFinanzas: puedeVerFinanzas,
  );

  Future<List<Adjunto>> _todoElPedido(String pedidoId) async {
    final listas = await Future.wait([
      _backend.listarPorPedido(pedidoId),
      _backend.listarPorPedidoDeTipo(pedidoId, TipoAdjunto.factura),
      _backend.listarPorPedidoDeTipo(pedidoId, TipoAdjunto.comprobante),
      _backend.listarComprobantesDePagosDelPedido(pedidoId),
    ]);
    return [...listas[0], ...listas[1], ...listas[2], ...listas[3]];
  }

  Future<Uint8List> obtenerContenido(String adjuntoId) =>
      _backend.obtenerContenido(adjuntoId);
}
