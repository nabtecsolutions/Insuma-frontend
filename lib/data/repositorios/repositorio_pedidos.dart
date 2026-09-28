import 'package:drift/drift.dart';
import '../../database/database.dart';
import '../../utils/fecha_recepcion.dart';
import '../mapeadores_supabase.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio de Pedidos de compra (HU-010 / HU-059).
///
/// Es la ÚNICA capa que toca Drift en el módulo Compras: encapsula todas las
/// queries que antes vivían dispersas en `ControladorRecibir` y en
/// `BaseDatosApp`, y encola las mutaciones hacia Supabase (Outbox) reutilizando
/// el mapeo canónico de [MapeadoresSupabase]. Sigue el patrón ya establecido por
/// Recepciones/Pagos (repositorio abstracto + implementación Drift registrada en
/// [FabricaRepositorios]).
/// Quién manda el pedido al proveedor (#273).
///
/// Se pasa cuando la escritura DEJA el pedido en `enviado`. El repositorio
/// registra **el primer** envío y no lo pisa después: ver la nota de
/// `_envioAEscribir`.
typedef EnvioAlProveedor = ({String? usuarioId, String? nombre});

abstract class RepositorioPedidos {
  // --- Lecturas del módulo -------------------------------------------------
  Future<Pedido?> obtener(String id);

  /// Pedidos del negocio, más recientes primero (por `fechaActualizacion`).
  Future<List<Pedido>> listarPorNegocio(String negocioId);

  /// Stream reactivo de los pedidos del negocio (HU-089): la UI se actualiza SOLA cuando
  /// el pull deposita filas (aunque llegue tras el primer frame) o tras una mutación, sin
  /// recarga manual. Mismo filtro y orden que [listarPorNegocio].
  Stream<List<Pedido>> observarPorNegocio(String negocioId);

  Future<Usuario?> obtenerUsuario(String usuarioId);

  Future<List<Proveedore>> proveedoresActivos(String negocioId);

  /// Stream reactivo de los proveedores activos del negocio (HU-096): el selector de
  /// "Nuevo Pedido" se actualiza SOLO cuando el pull deposita filas (aunque llegue tras
  /// el primer frame), sin recarga manual. Mismo filtro que [proveedoresActivos]. Mismo
  /// root cause que HU-089, acotado al picker de proveedores.
  Stream<List<Proveedore>> observarProveedoresActivos(String negocioId);

  /// Todos los insumos activos del negocio.
  ///
  /// HU-138: ya no filtra por proveedor. Quién suministra qué vive ahora en la
  /// tabla puente `insumo_proveedores`, y ese cruce es una decisión de negocio
  /// que resuelve `ServicioPedidos` — el repositorio sólo trae datos.
  Future<List<Insumo>> insumosActivos(String negocioId);

  Future<List<Insumo>> insumosPorIds(List<String> ids);

  /// Teléfono y email del proveedor, para los canales de envío del pedido
  /// (WhatsApp — HU-011/063 — y correo — #235). Una sola consulta.
  Future<({String? telefono, String? email})> contactoProveedor(
    String proveedorId,
  );

  /// Precio neto estimado de un ítem (HU-010). Delega en la primitiva de datos
  /// de [BaseDatosApp] (única implementación de la cascada de fallbacks), de modo
  /// que el controlador deja de acceder a la BD directamente sin duplicar la query.
  Future<double> precioEstimadoItem({
    required String insumoId,
    String? proveedorId,
  });

  // --- Escrituras (con encolado Outbox) -----------------------------------
  /// Inserta un pedido nuevo y encola su INSERT con el payload canónico completo.
  /// Devuelve el pedido persistido.
  Future<Pedido> crear({
    required String id,
    required String negocioId,
    required String proveedorNombre,
    String? proveedorId,
    required String estado,
    String? nota,
    String? creadoPor,
    String? creadoPorNombre,
    required String itemsJson,
    required double total,
    required bool tieneEfectivo,
    DateTime? fechaRecepcionSolicitada,

    /// #273: quién manda el pedido al proveedor. Ver [EnvioAlProveedor].
    EnvioAlProveedor? envio,
  });

  /// Actualiza el contenido de un pedido existente y encola su UPDATE con el
  /// payload canónico completo. Si [estado] es null, no se modifica el estado.
  /// Devuelve el pedido actualizado.
  ///
  /// [fechaRecepcionSolicitada] (HU-142) se escribe SIEMPRE, incluso en `null`:
  /// el campo es opcional y borrarlo es una edición legítima.
  Future<Pedido> actualizarContenido({
    required String id,
    String? estado,
    required String itemsJson,
    required double total,
    String? nota,
    required bool tieneEfectivo,
    DateTime? fechaRecepcionSolicitada,

    /// #273: quién manda el pedido al proveedor. Ver [EnvioAlProveedor].
    EnvioAlProveedor? envio,
  });

  /// Cambia SÓLO la fecha de entrega pedida (#269). `null` la deja sin fecha,
  /// que es un valor válido y no un faltante.
  ///
  /// No pasa por [actualizarContenido] a propósito: ese método reescribe ítems,
  /// total y nota desde lo que le pasen, así que reprogramar con él obligaría a
  /// la UI a reenviar todo el contenido del pedido desde un snapshot que puede
  /// estar viejo. Reprogramar toca un campo; escribe uno.
  Future<Pedido> reprogramar(String id, DateTime? fecha);

  /// ¿Hay OTRA entrega de la misma agenda ya puesta en [fecha]? (#269)
  ///
  /// Existe para poder avisar ANTES de escribir. El servidor tiene un índice
  /// único `ux_pedidos_ocurrencia (agenda_id, fecha_recepcion_solicitada)` que
  /// la base local NO replica: sin esta consulta, la escritura local pasa y el
  /// push muere en dead-letter, callado.
  ///
  /// [excluyendo] es el pedido que se está reprogramando, que obviamente no
  /// choca consigo mismo.
  Future<bool> hayOtraOcurrenciaEn({
    required String agendaId,
    required DateTime fecha,
    required String excluyendo,
  });

  /// Cambia sólo el estado de un pedido (cancelar/confirmar/cerrar parcial).
  ///
  /// Encola el payload CANÓNICO COMPLETO, no `{'id', 'estado'}`. Ver el porqué
  /// en la implementación: encolar parcial acá borraba cambios pendientes.
  Future<void> cambiarEstado(String id, String estado);

  /// Elimina físicamente un pedido y encola su DELETE.
  Future<void> eliminar(String id);

  // --- HU-013: pedidos recurrentes -----------------------------------------

  /// Pedidos del negocio que nacieron de una agenda (`agendaId != null`).
  ///
  /// Una sola lectura para TODAS las agendas: el generador necesita saber, por
  /// agenda, si hay una entrega abierta y cuál fue la última emitida. Preguntarlo
  /// agenda por agenda sería un N+1 en cada arranque de la app.
  Future<List<Pedido>> deAgendas(String negocioId);

  /// Día de la última recepción que CERRÓ un ciclo, por agenda.
  ///
  /// Es el ancla del modo "contar desde que se recibe", y se DERIVA en vez de
  /// guardarse: un campo persistido lo tendría que escribir un hook dentro de
  /// `ServicioRecepciones`, y ese hook no cubre los cierres reales (cerrar un
  /// parcial y facturar cambian el estado sin pasar por ahí). Derivándolo,
  /// `servicio_recepciones.dart` no se toca ni una línea.
  ///
  /// [estadosCerrados] son los estados en los que el pedido ya resolvió su
  /// ciclo; los decide el Service con `EstadosPedido`, no este repositorio.
  Future<Map<String, DateTime>> ultimosCierresPorAgenda(
    String negocioId, {
    required Set<String> estadosCerrados,
  });

  /// Materializa una entrega de una agenda como un pedido REAL.
  ///
  /// Nace directamente en el estado que se le pase —`en_espera` por decisión del
  /// PO, que es el que habilita recibir— porque la confirmación se dio UNA vez,
  /// al crear el pedido recurrente.
  ///
  /// Devuelve `null` si el id ya existía: dos dispositivos pueden materializar
  /// la misma entrega a la vez y eso NO es un error. Por eso no usa el `crear`
  /// de arriba, que hace un `insert` que LANZA ante PK repetida.
  Future<Pedido?> materializarOcurrencia({
    required String id,
    required String negocioId,
    required String agendaId,
    required String proveedorNombre,
    String? proveedorId,
    required String estado,
    required String itemsJson,
    required double total,
    required bool tieneEfectivo,
    String? nota,
    required DateTime fechaRecepcionSolicitada,
  });
}

class RepositorioPedidosDrift extends RepositorioSincronizable
    implements RepositorioPedidos {
  RepositorioPedidosDrift(super.db, super.sync);

  static const String _tabla = 'pedidos';

  @override
  Future<Pedido?> obtener(String id) =>
      (db.select(db.pedidos)..where((p) => p.id.equals(id))).getSingleOrNull();

  @override
  Future<List<Pedido>> listarPorNegocio(String negocioId) {
    return _queryPorNegocio(negocioId).get();
  }

  @override
  Stream<List<Pedido>> observarPorNegocio(String negocioId) {
    return _queryPorNegocio(negocioId).watch();
  }

  /// Query base de los pedidos del negocio (más recientes primero). La comparten la
  /// lectura puntual (`.get()`) y la reactiva (`.watch()`) para no divergir el orden.
  Selectable<Pedido> _queryPorNegocio(String negocioId) =>
      (db.select(db.pedidos)
        ..where((p) => p.negocioId.equals(negocioId))
        ..orderBy([
          (p) => OrderingTerm(
            expression: p.fechaActualizacion,
            mode: OrderingMode.desc,
          ),
        ]));

  @override
  Future<Usuario?> obtenerUsuario(String usuarioId) => (db.select(
    db.usuarios,
  )..where((u) => u.id.equals(usuarioId))).getSingleOrNull();

  @override
  Future<List<Proveedore>> proveedoresActivos(String negocioId) {
    return _queryProveedoresActivos(negocioId).get();
  }

  @override
  Stream<List<Proveedore>> observarProveedoresActivos(String negocioId) {
    return _queryProveedoresActivos(negocioId).watch();
  }

  /// Query base de los proveedores activos del negocio. La comparten la lectura
  /// puntual (`.get()`) y la reactiva (`.watch()`) para no divergir el filtro (HU-096).
  Selectable<Proveedore> _queryProveedoresActivos(String negocioId) =>
      (db.select(db.proveedores)
        ..where((p) => p.negocioId.equals(negocioId) & p.activo.equals(true)));

  @override
  Future<List<Insumo>> insumosActivos(String negocioId) => (db.select(
    db.insumos,
  )..where((i) => i.negocioId.equals(negocioId) & i.activo.equals(true))).get();

  @override
  Future<List<Insumo>> insumosPorIds(List<String> ids) =>
      (db.select(db.insumos)..where((i) => i.id.isIn(ids))).get();

  @override
  Future<({String? telefono, String? email})> contactoProveedor(
    String proveedorId,
  ) async {
    final prov = await (db.select(
      db.proveedores,
    )..where((p) => p.id.equals(proveedorId))).getSingleOrNull();
    return (telefono: prov?.telefono, email: prov?.email);
  }

  @override
  Future<double> precioEstimadoItem({
    required String insumoId,
    String? proveedorId,
  }) => db.obtenerPrecioEstimadoItem(
    insumoId: insumoId,
    proveedorId: proveedorId,
  );

  @override
  Future<Pedido> crear({
    required String id,
    required String negocioId,
    required String proveedorNombre,
    String? proveedorId,
    required String estado,
    String? nota,
    String? creadoPor,
    String? creadoPorNombre,
    required String itemsJson,
    required double total,
    required bool tieneEfectivo,
    DateTime? fechaRecepcionSolicitada,
    EnvioAlProveedor? envio,
  }) async {
    final ahora = DateTime.now();
    await db
        .into(db.pedidos)
        .insert(
          PedidosCompanion.insert(
            id: id,
            negocioId: negocioId,
            proveedorNombre: proveedorNombre,
            proveedorId: Value(proveedorId),
            estado: Value(estado),
            nota: Value(nota),
            creadoPor: Value(creadoPor),
            creadoPorNombre: Value(creadoPorNombre),
            items: Value(itemsJson),
            total: Value(total),
            tieneEfectivo: Value(tieneEfectivo),
            // HU-142: se normaliza a medianoche local; es un día, no un instante.
            fechaRecepcionSolicitada: Value(
              FechaRecepcion.soloDiaNullable(fechaRecepcionSolicitada),
            ),
            fechaCreacion: Value(ahora),
            fechaActualizacion: Value(ahora),
            // #273: un pedido que nace `enviado` se envió recién, así que acá
            // no hay nada previo que preservar.
            fechaEnvio: envio == null ? const Value.absent() : Value(ahora),
            enviadoPor: envio == null
                ? const Value.absent()
                : Value(envio.usuarioId),
            enviadoPorNombre: envio == null
                ? const Value.absent()
                : Value(envio.nombre),
          ),
        );
    final creado = await (db.select(
      db.pedidos,
    )..where((p) => p.id.equals(id))).getSingle();
    await encolarInsert(_tabla, id, MapeadoresSupabase.pedido(creado));
    return creado;
  }

  @override
  Future<Pedido> actualizarContenido({
    required String id,
    String? estado,
    required String itemsJson,
    required double total,
    String? nota,
    required bool tieneEfectivo,
    DateTime? fechaRecepcionSolicitada,
    EnvioAlProveedor? envio,
  }) async {
    // HU-028: se captura la `version` PREVIA (token de concurrencia) y se
    // incrementa la local. El push comparará contra la previa para no pisar un
    // cambio que otro dispositivo ya subió.
    final previo = await (db.select(
      db.pedidos,
    )..where((p) => p.id.equals(id))).getSingle();
    await (db.update(db.pedidos)..where((p) => p.id.equals(id))).write(
      PedidosCompanion(
        estado: estado == null ? const Value.absent() : Value(estado),
        items: Value(itemsJson),
        total: Value(total),
        nota: Value(nota),
        tieneEfectivo: Value(tieneEfectivo),
        // HU-142: se escribe SIEMPRE (no Value.absent) para que borrar la fecha
        // sea posible — el campo es opcional y vaciarlo es una edición válida.
        fechaRecepcionSolicitada: Value(
          FechaRecepcion.soloDiaNullable(fechaRecepcionSolicitada),
        ),
        version: Value(siguienteVersion(previo.version)),
        fechaActualizacion: Value(DateTime.now()),
        // #273: el PRIMER envio gana. Ver `registraElEnvio`.
        fechaEnvio: registraElEnvio(previo, envio)
            ? Value(DateTime.now())
            : const Value.absent(),
        enviadoPor: registraElEnvio(previo, envio)
            ? Value(envio!.usuarioId)
            : const Value.absent(),
        enviadoPorNombre: registraElEnvio(previo, envio)
            ? Value(envio!.nombre)
            : const Value.absent(),
      ),
    );
    final actualizado = await (db.select(
      db.pedidos,
    )..where((p) => p.id.equals(id))).getSingle();
    await encolarUpdate(
      _tabla,
      id,
      MapeadoresSupabase.pedido(actualizado),
      versionBase: previo.version,
    );
    return actualizado;
  }

  /// Qué escribir de las columnas de envío (#273).
  ///
  /// **El PRIMER envío gana y no se pisa.** Re-enviar un pedido corregido
  /// (HU-141) pasa otra vez por `actualizarContenido`, y sobrescribir la fecha
  /// borraría para siempre el momento en que ese pedido salió de la casa —que es
  /// el hecho que la trazabilidad quiere mostrar— para reemplazarlo por el de
  /// una corrección.
  ///
  /// Que la historia COMPLETA de re-envíos no quede registrada es una limitación
  /// conocida y aceptada: con una columna por hecho sólo cabe uno. Un historial
  /// de N re-envíos es el registro genérico de auditoría (#61), no esto.
  ///
  /// Público —y no privado con `@visibleForTesting`— para poder probar la regla
  /// sola sin sumarle el paquete `meta` a las dependencias por una anotación. Es
  /// la clase de condición que alguien invierte sin que nadie lo note.
  static bool registraElEnvio(Pedido previo, EnvioAlProveedor? envio) =>
      envio != null && previo.fechaEnvio == null;

  @override
  Future<Pedido> reprogramar(String id, DateTime? fecha) async {
    // HU-028: la `version` PREVIA es el token de concurrencia del push.
    final previo = await (db.select(
      db.pedidos,
    )..where((p) => p.id.equals(id))).getSingle();
    await (db.update(db.pedidos)..where((p) => p.id.equals(id))).write(
      PedidosCompanion(
        // `Value(...)` y no `Value.absent()`: escribir null es el pedido
        // explícito de dejar la entrega sin fecha.
        fechaRecepcionSolicitada: Value(FechaRecepcion.soloDiaNullable(fecha)),
        version: Value(siguienteVersion(previo.version)),
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    // `filaReprogramada` y no `filaCompleta`: `cambiarEstado` mas abajo encola
    // la misma llamada, y el ancla de la mutacion que cuida aquel arreglo tiene
    // que matchear UNA sola vez. Lo cazo `mutaciones_vigentes_test`.
    final filaReprogramada = await (db.select(
      db.pedidos,
    )..where((p) => p.id.equals(id))).getSingle();
    await encolarUpdate(
      _tabla,
      id,
      MapeadoresSupabase.pedido(filaReprogramada),
      versionBase: previo.version,
    );
    return filaReprogramada;
  }

  @override
  Future<bool> hayOtraOcurrenciaEn({
    required String agendaId,
    required DateTime fecha,
    required String excluyendo,
  }) async {
    final dia = FechaRecepcion.soloDia(fecha);
    final choque =
        await (db.select(db.pedidos)..where(
              (p) =>
                  p.agendaId.equals(agendaId) &
                  p.fechaRecepcionSolicitada.equals(dia) &
                  p.id.equals(excluyendo).not(),
            ))
            .get();
    // El índice remoto NO excluye cancelados, así que acá tampoco se filtra por
    // estado: una entrega cancelada sigue ocupando su fecha en el servidor, y
    // filtrarla acá daría un "se puede" que el push desmiente.
    return choque.isNotEmpty;
  }

  @override
  Future<void> cambiarEstado(String id, String estado) async {
    final previo = await (db.select(
      db.pedidos,
    )..where((p) => p.id.equals(id))).getSingleOrNull();
    await (db.update(db.pedidos)..where((p) => p.id.equals(id))).write(
      PedidosCompanion(
        estado: Value(estado),
        version: previo == null
            ? const Value.absent()
            : Value(siguienteVersion(previo.version)),
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    // #269 — SE RELEE Y SE ENCOLA LA FILA ENTERA, no `{id, estado}`.
    //
    // El Outbox deduplica por `(tabla, registro, accion)` con DELETE + INSERT:
    // la mutación nueva BORRA cualquier UPDATE pendiente del mismo registro. Con
    // un payload parcial acá, esta secuencia perdía datos sin ningún error:
    //
    //   1. el usuario reprograma la entrega sin conexión
    //      → se encola el UPDATE completo, con la fecha nueva;
    //   2. después confirma o cancela el pedido
    //      → este encolado borraba aquél y dejaba sólo `{id, estado}`;
    //   3. al recuperar señal sube el estado y la fecha nueva NUNCA viaja.
    //
    // La fila local sí tiene la fecha, así que en el dispositivo todo se ve
    // bien: la divergencia aparece recién en el otro dispositivo, o después de
    // reinstalar. Por eso el test de esto mira la COLA y no el pedido.
    //
    // Es el mismo patrón que `actualizarContenido` acá arriba: releer y encolar
    // `MapeadoresSupabase.pedido(...)`. La `versionBase` sigue siendo la PREVIA
    // —el token de concurrencia optimista de HU-028— y no la nueva.
    // El nombre no es casual: `actualizarContenido` acá arriba encola la misma
    // llamada con una variable llamada `actualizado`, y la mutación que cuida
    // este arreglo necesita un ancla que no matchee las dos.
    final filaCompleta = await (db.select(
      db.pedidos,
    )..where((p) => p.id.equals(id))).getSingle();
    await encolarUpdate(
      _tabla,
      id,
      MapeadoresSupabase.pedido(filaCompleta),
      versionBase: previo?.version,
    );
  }

  @override
  Future<void> eliminar(String id) async {
    await (db.delete(db.pedidos)..where((p) => p.id.equals(id))).go();
    await encolarDelete(_tabla, id);
  }

  // --- HU-013: pedidos recurrentes -----------------------------------------

  @override
  Future<List<Pedido>> deAgendas(String negocioId) =>
      (db.select(db.pedidos)..where(
            (p) => p.negocioId.equals(negocioId) & p.agendaId.isNotNull(),
          ))
          .get();

  @override
  Future<Map<String, DateTime>> ultimosCierresPorAgenda(
    String negocioId, {
    required Set<String> estadosCerrados,
  }) async {
    if (estadosCerrados.isEmpty) return const {};
    // UNA consulta agregada para todas las agendas, no una por agenda. La lista
    // de estados entra por variables y no interpolada: son datos, y aunque hoy
    // salgan de una constante del código, concatenarlos sería sembrar la
    // próxima inyección.
    final marcas = List.filled(estadosCerrados.length, '?').join(', ');
    final filas = await db
        .customSelect(
          'SELECT p.agenda_id AS agenda, MAX(r.fecha_recepcion) AS ultimo_cierre '
          'FROM recepciones r JOIN pedidos p ON p.id = r.pedido_id '
          'WHERE p.negocio_id = ? AND p.agenda_id IS NOT NULL '
          'AND p.estado IN ($marcas) '
          'GROUP BY p.agenda_id',
          variables: [
            Variable<String>(negocioId),
            ...estadosCerrados.map(Variable<String>.new),
          ],
          readsFrom: {db.pedidos, db.recepciones},
        )
        .get();

    final salida = <String, DateTime>{};
    for (final f in filas) {
      final agenda = f.read<String?>('agenda');
      final cierre = f.read<DateTime?>('ultimo_cierre');
      if (agenda != null && cierre != null) salida[agenda] = cierre;
    }
    return salida;
  }

  @override
  Future<Pedido?> materializarOcurrencia({
    required String id,
    required String negocioId,
    required String agendaId,
    required String proveedorNombre,
    String? proveedorId,
    required String estado,
    required String itemsJson,
    required double total,
    required bool tieneEfectivo,
    String? nota,
    required DateTime fechaRecepcionSolicitada,
  }) async {
    final ahora = DateTime.now();
    // Si la fila ya existe —dos dispositivos que materializaron la misma
    // entrega, o un pull que la trajo primero— no es un error, es la carrera
    // esperada. `insert()` a secas LANZA ante PK repetida, y acá eso abortaría
    // la evaluación entera de la agenda.
    //
    // Se usa `insertReturningOrNull` y NO `insert(mode: insertOrIgnore)`: ese
    // devuelve el rowid, que ante un conflicto NO queda en 0 —SQLite conserva
    // el último rowid insertado— así que "no se insertó nada" era
    // indistinguible de "se insertó". El returning devuelve null y no miente.
    final creado = await db
        .into(db.pedidos)
        .insertReturningOrNull(
          PedidosCompanion.insert(
            id: id,
            negocioId: negocioId,
            proveedorNombre: proveedorNombre,
            proveedorId: Value(proveedorId),
            estado: Value(estado),
            nota: Value(nota),
            items: Value(itemsJson),
            total: Value(total),
            tieneEfectivo: Value(tieneEfectivo),
            agendaId: Value(agendaId),
            fechaRecepcionSolicitada: Value(
              FechaRecepcion.soloDia(fechaRecepcionSolicitada),
            ),
            fechaCreacion: Value(ahora),
            fechaActualizacion: Value(ahora),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    if (creado == null) return null; // ya existía: nada que encolar

    await encolarInsert(_tabla, id, MapeadoresSupabase.pedido(creado));
    return creado;
  }
}
