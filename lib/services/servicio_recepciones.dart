import 'dart:convert';
import 'package:drift/drift.dart';
import '../database/database.dart';
import '../data/repositorios/repositorio_recepciones.dart';
import '../data/repositorios/repositorio_auditoria.dart';
import 'servicio_sincronizacion_supabase.dart';
import '../utils/desenlace_recepcion.dart';
import '../utils/dinero.dart';
import '../utils/estados_pedido.dart';
import '../utils/sanitizador_texto.dart';
import '../utils/transiciones_pedido.dart';
import '../data/transaccionador.dart';
import 'servicio_transiciones_pedido.dart' show TransicionInvalidaException;

/// Servicio de recepción de mercadería (RN-012/013, HU-014/015).
/// Cada recepción es un EVENTO append-only: las cantidades recibidas se
/// ACUMULAN por ítem entre eventos y nunca se sobrescriben las anteriores.
class ServicioRecepciones {
  final BaseDatosApp _db;

  /// #269: la regla de atomicidad vive en UN solo lugar. Ver
  /// `Transaccionador`: el ternario que estaba acá se repetia en seis
  /// services, y escribirlo al revés no tiene sintoma.
  late final Transaccionador _tx = Transaccionador(_db, _sync);
  final RepositorioRecepciones _repoRecepciones;
  final RepositorioAuditoria _auditoria;
  final ServicioSincronizacionSupabase? _sync;

  ServicioRecepciones(
    this._db,
    this._repoRecepciones,
    this._auditoria, [
    this._sync,
  ]);

  /// Registra un evento de recepción y recalcula el estado del pedido acumulando
  /// todas las recepciones previas.
  ///
  /// #229: acá ya NO se registran precios. El bucle que costeaba al recibir se
  /// mudó a `ServicioProcesarRecepcion` — el costo real se carga en Pagos,
  /// contra la factura. El `precioUnitario` que viaja en los ítems es la
  /// ESTIMACIÓN copiada del pedido: sostiene el total estimado del evento (y
  /// `montoRecibido` en Pagos), pero no toca `historial_precios` ni el caché
  /// del insumo. Reconectar un costeo acá duplicaría precios sin síntoma: el
  /// invariante que lo delata vive en `servicio_procesar_recepcion_test`.
  ///
  /// [itemsVerificados]: [{insumoId, nombre, unidad, cantidadPedida, cantidadRecibida, precioUnitario, estado}]
  /// [totalManual]: total recibido escrito a mano (HU-143). Si viene, MANDA
  /// sobre el derivado de las líneas y queda auditado quién/cuándo lo escribió;
  /// null ⇒ vale el calculado ([totalFacturable]).
  ///
  /// [cerrarSinParcial] (HU-145): ante una recepción con faltantes, el usuario
  /// eligió NO generar parcial. El faltante queda registrado como observación
  /// del ítem (evidencia inmutable del evento) y el pedido cierra directo en
  /// `parcial_cerrado` (Historial) en vez de quedar en Parciales.
  Future<Recepcion> registrar({
    required Pedido pedido,
    required List<Map<String, dynamic>> itemsVerificados,
    List<Map<String, dynamic>> alertas = const [],
    String? usuarioId,
    String? usuarioNombre,
    bool pagarEfectivo = false,
    String? nota,
    double? totalManual,
    bool cerrarSinParcial = false,
    Future<void> Function(String recepcionId)? adjuntarEnTransaccion,
  }) async {
    if (totalManual != null && totalManual < 0) {
      throw ArgumentError.value(
        totalManual,
        'totalManual',
        'El total recibido no puede ser negativo',
      );
    }
    // HU-146: el invariante de la nota (saneo + tope) vive en el Service, no
    // sólo en el formatter de la UI — cualquier llamador (p. ej. HU-009) queda
    // cubierto. Vacía ⇒ null (no se guarda string vacío).
    final notaLimpia = nota == null
        ? null
        : SanitizadorTexto.limpiarMultilinea(nota);
    nota = (notaLimpia == null || notaLimpia.isEmpty) ? null : notaLimpia;
    // HU-090: NO se guarda aquí. Recepción es un evento operativo (append-only) que la
    // reciben también cocineros; NO crea movimientos de cuenta corriente / facturas /
    // pagos, así que no alimenta ningún saldo/anticipo derivado. El guard vive sólo en
    // los creadores de movimientos financieros (facturación y pagos).
    // HU-079 (C2): evento + estado del pedido + precios + auditoría en UNA transacción.
    // Con el Outbox suspendido la cola participa; un fallo revierte todo.
    Future<Recepcion> cuerpo() async {
      final itemsPedido = (jsonDecode(pedido.items) as List)
          .cast<Map<String, dynamic>>();

      // HU-145: si el usuario cierra SIN parcial, el faltante (acumulado entre
      // todas las recepciones, esta incluida) queda como observación del ítem
      // DENTRO del evento — evidencia inmutable de la diferencia aceptada.
      // Defensa en profundidad: sólo si el estado PROYECTADO es realmente
      // parcial; un llamador que pase el flag sin faltante real (API misuse)
      // no genera anotaciones ni auditoría espurias.
      var itemsEvento = itemsVerificados;
      var faltantesAceptados = const <Map<String, dynamic>>[];
      if (cerrarSinParcial) {
        final previas = await _repoRecepciones.listarPorPedido(pedido.id);
        final lineasPrevias = previas
            .map(
              (r) => (jsonDecode(r.items) as List).cast<Map<String, dynamic>>(),
            )
            .toList();
        final estadoProyectado = estadoPedidoTrasRecepcion(
          itemsPedido: itemsPedido,
          lineasPorRecepcion: [...lineasPrevias, itemsVerificados],
          estadoBase: pedido.estado,
        );
        if (estadoProyectado == EstadosPedido.recibidoParcial) {
          faltantesAceptados = calcularFaltantes(
            itemsPedido: itemsPedido,
            lineasPorRecepcion: [...lineasPrevias, itemsVerificados],
          );
          itemsEvento = anotarFaltantesEnItems(
            itemsVerificados,
            faltantesAceptados,
          );
        }
      }

      // 1. Evento append-only. `origenPrecio` (HU-144) es un dato de PROCESO,
      // no de evidencia: se quita del JSON del evento para no ampliar de facto
      // el contrato JSONB remoto. (Hoy ya nadie lo setea en este camino — el
      // OCR vive en Procesar — pero se sigue limpiando por si un cliente viejo
      // manda ítems con la clave puesta.)
      final itemsEventoLimpios = [
        for (final it in itemsEvento) {...it}..remove('origenPrecio'),
      ];
      final evento = await _repoRecepciones.registrarEvento(
        negocioId: pedido.negocioId,
        pedidoId: pedido.id,
        items: itemsEventoLimpios,
        recepcionadoPor: usuarioId,
        recepcionadoPorNombre: usuarioNombre,
        nota: nota,
        totalRecibido: totalManual,
        totalEditadoPor: usuarioId,
        totalEditadoPorNombre: usuarioNombre,
      );

      // 2. Recalcular el estado del pedido a partir de los DESENLACES de TODAS sus
      //    recepciones (HU-064): un ítem está resuelto si se aceptó lo pedido o fue
      //    rechazado (terminal). Lo rechazado NO suma cantidad aceptada.
      final recepciones = await _repoRecepciones.listarPorPedido(pedido.id);
      final lineasPorRecepcion = recepciones
          .map(
            (r) => (jsonDecode(r.items) as List).cast<Map<String, dynamic>>(),
          )
          .toList();

      final estado = estadoPedidoTrasRecepcion(
        itemsPedido: itemsPedido,
        lineasPorRecepcion: lineasPorRecepcion,
        estadoBase: pedido.estado,
      );
      // HU-145: "cerrar sin parcial" convierte el parcial derivado en un cierre
      // directo (parcial_cerrado → Historial). La matriz lo permite desde
      // en_espera y desde recibido_parcial (HU-141).
      final estadoElegido =
          (cerrarSinParcial && estado == EstadosPedido.recibidoParcial)
          ? EstadosPedido.parcialCerrado
          : estado;
      // #229: acá se forzaba `'facturado'` cuando era en efectivo (RN-014).
      // Se cayó con el rediseño: el efectivo ya no saltea la cuenta corriente —
      // pasa por Procesar como todos, y es AHÍ donde el pedido llega a
      // 'facturado' (y a 'pagado', con la plata asentada de verdad).
      final estadoFinal = estadoElegido;

      // HU-141: el estado derivado también respeta la matriz. La identidad
      // (recepción que no mueve el estado) es válida; cualquier otro salto no
      // contemplado aborta la transacción entera (evento incluido).
      if (estadoFinal != pedido.estado &&
          !TransicionesPedido.puede(pedido.estado, estadoFinal)) {
        throw TransicionInvalidaException(
          'La recepción llevaría el pedido de "${pedido.estado}" a '
          '"$estadoFinal", una transición inválida.',
        );
      }

      // 5. Actualizar el pedido (estado + auditoría de usuario). NO se pierde el detalle histórico.
      //    El total del evento usa la cantidad ACEPTADA (lo rechazado vale 0);
      //    si hay total manual (HU-143), manda el manual.
      final totalEvento = Dinero.redondear(
        totalFacturable(totalManual: totalManual, lineas: itemsVerificados),
      ); // HU-081 (C3)
      final alertasJson = alertas.isEmpty ? null : jsonEncode(alertas);
      await (_db.update(
        _db.pedidos,
      )..where((p) => p.id.equals(pedido.id))).write(
        PedidosCompanion(
          estado: Value(estadoFinal),
          recepcionadoPor: Value(usuarioId),
          recepcionadoPorNombre: Value(usuarioNombre),
          tieneEfectivo: Value(pagarEfectivo),
          total: Value(totalEvento),
          alertas: Value(alertasJson),
          estadoSync: const Value('pendiente'),
          fechaActualizacion: Value(DateTime.now()),
        ),
      );
      await _sync?.encolarMutacion(
        nombreTabla: 'pedidos',
        registroId: pedido.id,
        accion: 'UPDATE',
        datos: {
          'id': pedido.id,
          'estado': estadoFinal,
          'recepcionado_por': usuarioId,
          'recepcionado_por_nombre': usuarioNombre,
          'tiene_efectivo': pagarEfectivo,
          'total': totalEvento,
          'alertas': alertas.isEmpty ? null : alertas,
        },
      );

      // 6. (#229) Acá vivía el bucle que registraba precios al recibir — EL
      //    único camino recepción → historial_precios. Se mudó entero a
      //    `ServicioProcesarRecepcion` junto con la dependencia de
      //    `ServicioPrecios`: sacarla del constructor hace que reconectarlo
      //    exija volver a cablear la inyección, que es el tipo de fricción que
      //    conviene que tenga un doble conteo.

      // 7. Auditoría inmutable del evento (HU-030).
      await _auditoria.registrar(
        negocioId: pedido.negocioId,
        usuarioId: usuarioId,
        tablaAfectada: 'recepciones',
        registroId: evento.id,
        accion: 'INSERT',
        datosDespues: {
          'pedido_id': pedido.id,
          'numero_recepcion': evento.numeroRecepcion,
          'estado_resultante': estadoFinal,
          // HU-145: constancia explícita de la decisión "cerrar sin parcial"
          // y de qué faltantes se aceptaron (versionada en la auditoría).
          if (cerrarSinParcial && faltantesAceptados.isNotEmpty) ...{
            'transicion': 'cierre_sin_parcial',
            'faltantes': faltantesAceptados,
          },
        },
      );

      // 8. (#227) El comprobante, DENTRO de la misma transacción.
      //
      //    Antes se persistía después de que `registrar` volviera, así que un
      //    fallo dejaba la recepción registrada sin el papel que la regla de
      //    #226 exige — y el bucle de `persistirEn` lo descartaba en silencio.
      //    Acá adentro, si la escritura falla, la recepción entera se revierte
      //    y el archivo sobrevive staged para reintentar.
      //
      //    Va ÚLTIMO a propósito: escribir un BLOB de hasta 5 MB antes de la
      //    validación de la matriz o de la auditoría sería trabajo tirado cada
      //    vez que una de esas revierte la transacción.
      //
      //    ⚠ El hook es SÓLO para escrituras cortas de base. Nada de red, nada
      //    de compresión: eso corre antes (`ControladorAdjuntos.prepararTodo`),
      //    porque SQLite tiene un solo escritor y sostenerlo mientras se
      //    comprime una imagen es peor negocio todavía en Flutter Web, sin
      //    isolates. Y todo lo que escriba tiene que ir `await`-eado: un future
      //    suelto se sale de la transacción sin hacer ruido.
      await adjuntarEnTransaccion?.call(evento.id);

      return evento;
    }

    return _tx.correr(cuerpo);
  }

  /// Recepciones de un pedido, ordenadas por número (HU-146): la vista de
  /// detalle las muestra con su desenlace y su nota sin tocar el repositorio.
  Future<List<Recepcion>> recepcionesDePedido(String pedidoId) =>
      _repoRecepciones.listarPorPedido(pedidoId);

  /// ¿Registrar [items] ahora dejaría el pedido PARCIAL? (HU-145). La UI lo
  /// consulta ANTES de confirmar la recepción para ofrecer explícitamente
  /// "incluir el faltante como parcial" o "cerrar sin parcial".
  Future<bool> quedariaParcial({
    required Pedido pedido,
    required List<Map<String, dynamic>> items,
  }) async {
    final previas = await _repoRecepciones.listarPorPedido(pedido.id);
    final lineasPrevias = previas
        .map((r) => (jsonDecode(r.items) as List).cast<Map<String, dynamic>>())
        .toList();
    final estado = estadoPedidoTrasRecepcion(
      itemsPedido: (jsonDecode(pedido.items) as List)
          .cast<Map<String, dynamic>>(),
      lineasPorRecepcion: [...lineasPrevias, items],
      estadoBase: pedido.estado,
    );
    return estado == EstadosPedido.recibidoParcial;
  }

  /// Faltantes de un pedido (HU-064): por cada ítem, lo que NO entró
  /// (`cantidadPedida` − aceptada acumulada en todas sus recepciones). Lo rechazado
  /// cuenta como faltante. Sirve para armar un nuevo borrador con la mercadería que
  /// resta (re-pedir lo faltante).
  Future<List<Map<String, dynamic>>> faltantesDePedido(Pedido pedido) async {
    final recepciones = await _repoRecepciones.listarPorPedido(pedido.id);
    final lineasPorRecepcion = recepciones
        .map((r) => (jsonDecode(r.items) as List).cast<Map<String, dynamic>>())
        .toList();
    final itemsPedido = (jsonDecode(pedido.items) as List)
        .cast<Map<String, dynamic>>();
    return calcularFaltantes(
      itemsPedido: itemsPedido,
      lineasPorRecepcion: lineasPorRecepcion,
    );
  }
}
