import '../database/database.dart';
import '../data/repositorios/repositorio_auditoria.dart';
import '../data/repositorios/repositorio_pedidos.dart';
import '../data/repositorios/repositorio_recepciones.dart';
import '../utils/estados_pedido.dart';
import '../utils/fecha_recepcion.dart';
import '../utils/transiciones_pedido.dart';
import 'servicio_sincronizacion_supabase.dart';
import '../data/transaccionador.dart';

/// Transición de estado rechazada por la matriz o por una regla de negocio.
/// El [mensaje] está pensado para mostrarse tal cual al usuario.
class TransicionInvalidaException implements Exception {
  final String mensaje;
  const TransicionInvalidaException(this.mensaje);
  @override
  String toString() => mensaje;
}

/// Servicio de transiciones de estado de Pedidos (HU-141).
///
/// Autoridad ÚNICA para los cambios que son "solo estado" (cancelar, confirmar,
/// cerrar/descartar un parcial, eliminar un borrador): RE-LEE la fila viva (el
/// snapshot de la UI puede estar viejo si el pull depositó cambios de otro
/// dispositivo mientras el diálogo estaba abierto), valida contra la matriz
/// pura [TransicionesPedido], persiste vía [RepositorioPedidos] y deja el
/// rastro en la auditoría inmutable (HU-030). Cambio + auditoría van en UNA
/// transacción con el Outbox suspendido (HU-079): un fallo revierte todo.
///
/// Los servicios que escriben estado DENTRO de sus propias transacciones
/// (recepciones, facturación) no delegan acá su escritura: validan con la
/// matriz antes de escribir, para no romper su atomicidad.
class ServicioTransicionesPedido {
  final RepositorioPedidos _pedidos;
  final RepositorioRecepciones _recepciones;
  final RepositorioAuditoria _auditoria;

  /// #269: este service ya NO guarda la base. Su unico uso de Drift era el
  /// ternario de la transaccion, que ahora vive en [Transaccionador]. La firma
  /// del constructor no cambia —sigue recibiendo la base y el sync— para no
  /// tocar sus nueve sitios de construccion.
  final Transaccionador _tx;

  ServicioTransicionesPedido(
    BaseDatosApp db,
    this._pedidos,
    this._recepciones,
    this._auditoria, [
    ServicioSincronizacionSupabase? sync,
  ]) : _tx = Transaccionador(db, sync);

  /// Aplica `estado actual → nuevoEstado` sobre la fila VIVA si la matriz lo
  /// permite; si no, lanza [TransicionInvalidaException]. Audita el cambio con
  /// antes/después reales y un [motivo] opcional que explica el "cómo"
  /// (p. ej. 'descarte_parcial').
  Future<void> transicionar(
    Pedido pedido,
    String nuevoEstado, {
    String? usuarioId,
    String? motivo,
  }) {
    return _enTransaccion(() async {
      final vivo = await _pedidoVivo(pedido.id);
      await _aplicar(vivo, nuevoEstado, usuarioId: usuarioId, motivo: motivo);
    });
  }

  /// Cancela un pedido (HU-141). Desde `en_espera` SOLO si todavía no tiene
  /// recepciones registradas: con mercadería ya recibida el camino correcto es
  /// cerrar la recepción, no cancelar (quedaría evidencia colgando de un
  /// pedido cancelado). Las reglas se evalúan sobre la fila viva.
  Future<void> cancelar(Pedido pedido, {String? usuarioId}) {
    return _enTransaccion(() async {
      final vivo = await _pedidoVivo(pedido.id);
      if (!TransicionesPedido.esCancelable(vivo.estado)) {
        throw TransicionInvalidaException(
          'Un pedido en estado "${vivo.estado}" no se puede cancelar.',
        );
      }
      if (vivo.estado == EstadosPedido.enEspera) {
        final recepciones = await _recepciones.listarPorPedido(vivo.id);
        if (recepciones.isNotEmpty) {
          throw TransicionInvalidaException(
            'Este pedido ya tiene recepciones registradas: cerrá la recepción '
            'en vez de cancelarlo.',
          );
        }
      }
      await _aplicar(
        vivo,
        EstadosPedido.cancelado,
        usuarioId: usuarioId,
        motivo: 'cancelacion',
      );
    });
  }

  /// Mueve la fecha de entrega pedida, o la deja sin fecha (#269).
  ///
  /// [nuevaFecha] en `null` es un valor VÁLIDO, no un faltante: el PO decidió
  /// que se pueda quitar la fecha. Quien llame tiene que haberle avisado al
  /// usuario qué implica —la entrega pasa a la sección "Sin fecha", arriba de
  /// todo, y queda siempre visible—, que es el efecto contrario al que espera
  /// quien quería posponerla.
  ///
  /// Tres validaciones, en este orden:
  ///
  ///  1. **el estado**, sobre la fila VIVA: la entrega no puede haber pasado ya;
  ///  2. **la ventana de fechas**, con las reglas de [FechaRecepcion] —las
  ///     mismas que el formulario del pedido, no una copia—;
  ///  3. **el choque de agenda**, que es la que no se ve venir.
  ///
  /// Sobre la tercera: el servidor tiene un índice único
  /// `ux_pedidos_ocurrencia (agenda_id, fecha_recepcion_solicitada)` que la base
  /// local NO replica. Sin este chequeo, reprogramar una entrega recurrente
  /// encima de otra de la misma serie se escribe local sin problema y el push
  /// muere en dead-letter, callado: el usuario ve la fecha cambiada y el
  /// servidor nunca se entera.
  ///
  /// **Queda un residual, y es honesto decirlo:** el chequeo mira lo que ESTE
  /// dispositivo tiene bajado. Una ocurrencia creada en otro dispositivo y
  /// todavía no sincronizada acá no se detecta, y ese caso sí termina en el
  /// push. Cerrarlo del todo pide que el push traduzca el error del índice.
  Future<void> reprogramar(
    Pedido pedido,
    DateTime? nuevaFecha, {
    String? usuarioId,
  }) {
    return _enTransaccion(() async {
      final vivo = await _pedidoVivo(pedido.id);

      if (!TransicionesPedido.esReprogramable(vivo.estado)) {
        throw TransicionInvalidaException(
          'Una entrega en estado "${vivo.estado}" ya no se puede reprogramar.',
        );
      }

      final motivoFecha = FechaRecepcion.validar(nuevaFecha);
      if (motivoFecha != null) throw TransicionInvalidaException(motivoFecha);

      final agendaId = vivo.agendaId;
      if (agendaId != null && nuevaFecha != null) {
        final choca = await _pedidos.hayOtraOcurrenciaEn(
          agendaId: agendaId,
          fecha: nuevaFecha,
          excluyendo: vivo.id,
        );
        if (choca) {
          throw TransicionInvalidaException(
            'Esta serie ya tiene una entrega para el '
            '${FechaRecepcion.formatear(nuevaFecha)}. Elegí otro día.',
          );
        }
      }

      final antes = vivo.fechaRecepcionSolicitada;
      await _pedidos.reprogramar(vivo.id, nuevaFecha);
      await _auditoria.registrar(
        negocioId: vivo.negocioId,
        usuarioId: usuarioId,
        tablaAfectada: 'pedidos',
        registroId: vivo.id,
        accion: 'UPDATE',
        // Las fechas viajan como texto `aaaa-mm-dd` y no como DateTime: la
        // auditoría serializa a JSON, y un DateTime crudo ahí revienta.
        datosAntes: {'fecha_recepcion_solicitada': FechaRecepcion.aIso(antes)},
        datosDespues: {
          'fecha_recepcion_solicitada': FechaRecepcion.aIso(nuevaFecha),
          'motivo': 'reprogramacion',
        },
      );
    });
  }

  /// Descarta un PARCIAL que no se va a reclamar (HU-145): el pedido pasa a
  /// `parcial_cerrado` (Historial) y sale de la lista de Parciales. NUNCA borra
  /// la recepción ni su evidencia (motivos, comentarios, adjuntos): es una
  /// transición explícita y auditada, no un borrado.
  Future<void> descartarParcial(Pedido pedido, {String? usuarioId}) {
    return _enTransaccion(() async {
      final vivo = await _pedidoVivo(pedido.id);
      if (vivo.estado != EstadosPedido.recibidoParcial) {
        throw TransicionInvalidaException(
          'Sólo un pedido parcial se puede descartar (este está '
          '"${vivo.estado}").',
        );
      }
      await _aplicar(
        vivo,
        EstadosPedido.parcialCerrado,
        usuarioId: usuarioId,
        motivo: 'descarte_parcial',
      );
    });
  }

  /// Elimina físicamente un BORRADOR (HU-141). Cualquier otro estado lanza:
  /// un pedido que ya viajó al proveedor se cancela, no se borra (la policy
  /// remota FOR DELETE también lo exige, ver migración hu141).
  Future<void> eliminarBorrador(Pedido pedido, {String? usuarioId}) {
    return _enTransaccion(() async {
      final vivo = await _pedidoVivo(pedido.id);
      if (!TransicionesPedido.esEliminable(vivo.estado)) {
        throw TransicionInvalidaException(
          'Sólo se pueden eliminar borradores; un pedido "${vivo.estado}" '
          'se cancela.',
        );
      }
      await _pedidos.eliminar(vivo.id);
      await _auditoria.registrar(
        negocioId: vivo.negocioId,
        usuarioId: usuarioId,
        tablaAfectada: 'pedidos',
        registroId: vivo.id,
        accion: 'DELETE',
        datosAntes: {
          'estado': vivo.estado,
          'proveedor_nombre': vivo.proveedorNombre,
          'total': vivo.total,
        },
      );
    });
  }

  // --- Helpers privados ----------------------------------------------------

  /// Cambio + auditoría, SIN abrir transacción propia (el llamador ya la abrió).
  Future<void> _aplicar(
    Pedido vivo,
    String nuevoEstado, {
    String? usuarioId,
    String? motivo,
  }) async {
    if (!TransicionesPedido.puede(vivo.estado, nuevoEstado)) {
      throw TransicionInvalidaException(
        'No se puede pasar el pedido de "${vivo.estado}" a "$nuevoEstado".',
      );
    }
    await _pedidos.cambiarEstado(vivo.id, nuevoEstado);
    await _auditoria.registrar(
      negocioId: vivo.negocioId,
      usuarioId: usuarioId,
      tablaAfectada: 'pedidos',
      registroId: vivo.id,
      accion: 'UPDATE',
      datosAntes: {'estado': vivo.estado},
      datosDespues: {'estado': nuevoEstado, 'motivo': ?motivo},
    );
  }

  /// La fila ACTUAL del pedido: la UI opera sobre un snapshot que el pull pudo
  /// haber dejado viejo; todas las reglas se evalúan sobre este estado.
  Future<Pedido> _pedidoVivo(String id) async {
    final vivo = await _pedidos.obtener(id);
    if (vivo == null) {
      throw const TransicionInvalidaException(
        'El pedido ya no existe (pudo eliminarse desde otro dispositivo).',
      );
    }
    return vivo;
  }

  /// Transacción con el Outbox suspendido si hay sync (HU-079); si no, una
  /// transacción Drift a secas. Anidable: el drenaje corre al commit externo.
  Future<T> _enTransaccion<T>(Future<T> Function() cuerpo) =>
      _tx.correr(cuerpo);
}
