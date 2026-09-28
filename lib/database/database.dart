import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'migraciones/migrador_categorias_v24.dart';
import 'migraciones/migrador_insumos_v14.dart';
import '../services/servicio_configuracion_negocio.dart';
import '../utils/calculadora_costos.dart';
import 'connection/unsupported.dart'
    if (dart.library.js_interop) 'connection/web.dart'
    if (dart.library.io) 'connection/native.dart'
    as conn;

part 'database.g.dart';

// ─── CONVENCIONES DE COLUMNAS DE SINCRONIZACIÓN (offline-first) ──────────────
//
// Toda entidad sincronizable debe poder representar (HU-027 / RN-015 / RN-016):
//   - id            : UUID v4 generado en el cliente (clave global estable).
//   - negocioId     : tenant_id para aislamiento multi-negocio (RN-001).
//   - fechaCreacion : marca de alta.
//   - fechaActualizacion : última modificación (last-write-wins).
//   - estadoSync    : 'pendiente' | 'sincronizado' | 'conflicto' | 'error'.
//   - version       : contador incremental para desempate de conflictos.
//
// Las tablas APPEND-ONLY (historial de precios, recepciones, movimientos de
// cuenta corriente, auditoría) no se modifican una vez creadas: sólo llevan
// fechaCreacion + estadoSync (no fechaActualizacion ni version).

// ─── DEFINICIÓN DE TABLAS DE LA BASE DE DATOS (DRIFT/SQLITE) ─────────────────

/// Tabla que representa un Negocio/Establecimiento gastronómico.
/// Raíz de la arquitectura multi-inquilino (Multi-Tenant).
class Negocios extends Table {
  TextColumn get id => text()();
  TextColumn get nombre => text()();
  TextColumn get tipo => text()(); // restaurante, local, delivery, otro
  TextColumn get pais => text().withDefault(const Constant('Argentina'))();
  TextColumn get email => text().nullable()();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tabla de Usuarios vinculados a un Negocio.
/// Soporta roles de 'admin' (acceso completo y costos) y 'cocinero' (operaciones básicas).
/// La contraseña se persiste como HASH (nunca en texto plano) — ver ServicioAutenticacion.
class Usuarios extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get nombre => text()();
  TextColumn get rol =>
      text().withDefault(const Constant('cocinero'))(); // admin, cocinero
  // HU-112: la columna pin_hash se eliminó (quedó huérfana tras HU-077; ninguna
  // función la usaba). El drop vive en la migración v8 → v9.
  TextColumn get email => text().nullable()(); // Email para login individual
  TextColumn get passwordHash =>
      text().nullable()(); // Hash de contraseña (HU-001: nunca texto plano)
  BoolColumn get activo => boolean().withDefault(const Constant(true))();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};

  // Email único por negocio (RN-001 / HU-001). Permite el mismo email en negocios distintos.
  @override
  List<Set<Column>> get uniqueKeys => [
    {negocioId, email},
  ];
}

/// Tabla de Proveedores de insumos.
class Proveedores extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get nombre => text()();
  TextColumn get categoria => text().nullable()();
  TextColumn get contacto => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get telefono => text().nullable()();
  TextColumn get cuit => text()
      .nullable()(); // CUIT/CUIL (HU-007), único por negocio cuando se informa
  TextColumn get plazoPago => text().nullable()();

  /// Alias de la cuenta del proveedor, para transferirle (#220).
  ///
  /// NULL significa "no cargado", y es DISTINTO de cadena vacía: es lo que
  /// permite mostrar la fila en gris diciendo "sin cargar" —información útil,
  /// dice que a este proveedor le falta— en vez de esconderla.
  TextColumn get aliasBancario => text().nullable()();

  /// CBU o CVU, 22 dígitos (#220).
  ///
  /// TEXT y no número: en varios bancos EMPIEZA CON CERO, y guardarlo como
  /// número se come ese cero y la transferencia se cae. Tampoco se opera
  /// aritméticamente con él: se copia y se pega.
  ///
  /// La app valida los 22 dígitos; en Postgres NO hay CHECK, porque las filas
  /// históricas llegan nulas y un CHECK mal calibrado —los CVU de algunas
  /// billeteras no respetan el dígito verificador del CBU bancario— rechazaría
  /// datos válidos y rompería la sincronización sin que la app se entere.
  TextColumn get cbu => text().nullable()();

  BoolColumn get activo => boolean().withDefault(const Constant(true))();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tabla de Insumos (ingredientes u objetos de apoyo como carbón, descartables).
/// El IVA NO se guarda aquí: se audita por compra en HistorialPrecios.ivaPorcentaje.
class Insumos extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get nombre => text()();

  /// Texto libre de categoría. DEPRECADO por #262 en favor de [categoriaId]
  /// (entidad [Categorias]). Se conserva —no se dropea— durante la transición:
  /// clientes viejos lo siguen mandando y el backfill lo usa para derivar la FK.
  TextColumn get categoria => text()();

  /// #262: la categoría a la que pertenece el insumo, como ENTIDAD ([Categorias]).
  /// Reemplaza al texto libre [categoria]. Nullable en el ALTER (única forma
  /// segura) + backfill (Fase 3); la app la exige en el alta una vez migrado.
  /// onDelete setNull: una categoría no se lleva el insumo (y su baja es lógica).
  TextColumn get categoriaId => text().nullable().references(
    Categorias,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get unidad =>
      text()(); // kg, g, lt, ml, u, paq, atado, otro (unidad BASE del insumo)
  /// Caché del ÚLTIMO precio al que INGRESÓ el insumo, sin importar de qué
  /// proveedor vino (decisión del PO, HU-138). Es el número que alimenta el
  /// FoodCost cuando no hay historial. La fuente de verdad sigue siendo
  /// [HistorialPrecios]; ver [BaseDatosApp.registrarPrecioInsumo].
  RealColumn get costoPorUnidad => real().withDefault(const Constant(0.0))();

  /// DEPRECADA (HU-138): el insumo pasó a tener VARIOS proveedores, en
  /// [InsumoProveedores]. La columna NO se elimina —los clientes viejos la
  /// siguen mandando en el payload y borrarla obligaría a recrear la tabla, que
  /// tiene tres hijas en CASCADE— pero ya nadie la lee ni la escribe.
  TextColumn get proveedorId => text().nullable().references(
    Proveedores,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get tipo => text().withDefault(
    const Constant('ingrediente'),
  )(); // ingrediente, apoyo, descartable
  BoolColumn get activo => boolean().withDefault(const Constant(true))();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};

  // El nombre es ÚNICO por negocio (HU-138), pero ese índice vive SOLO en
  // Supabase. Acá no se declara a propósito: un índice único local convertiría
  // el pull en un descartador silencioso de filas (dos dispositivos crean
  // "Limón" offline y la fila remota ya no entra). El control local es la
  // validación de la app al dar de alta; Postgres es la barrera real.
}

/// Qué proveedores suministran un insumo, y a qué precio de LISTA cada uno (HU-138).
///
/// Antes el insumo tenía UN proveedor (`Insumos.proveedorId`), así que el mismo
/// tomate comprado a dos verdulerías eran dos insumos distintos — y al armar una
/// receta había que elegir cuál, cuando en ese flujo el origen no importa.
///
/// Es una tabla PUENTE con tenant propio (HU-045), moldeada sobre
/// [RecetaIngredientes], con dos diferencias deliberadas:
///  • [version]: el precio se edita fila a fila, así que necesita el token de
///    concurrencia optimista de HU-028; sin él, dos ediciones simultáneas se
///    pisan en silencio.
///  • [activo]: la baja es LÓGICA. Un DELETE físico exigiría una policy
///    `FOR DELETE` en Supabase (la lección que dejó `receta_ingredientes` en
///    HU-045: sin esa policy la RLS rechazaba el borrado y la cola moría).
///
/// IMPORTANTE — este precio NO alimenta el FoodCost: es el precio de lista que
/// se usa al armar un PEDIDO. El costo de la receta sigue saliendo del último
/// precio de INGRESO ([HistorialPrecios]). Cotizar no es comprar.
class InsumoProveedores extends Table {
  /// DETERMINISTA: `md5(insumoId + ':' + proveedorId)`. Ver [IdDeterminista].
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get insumoId =>
      text().references(Insumos, #id, onDelete: KeyAction.cascade)();
  TextColumn get proveedorId =>
      text().references(Proveedores, #id, onDelete: KeyAction.cascade)();

  /// Precio de lista de ESE proveedor. `null` = todavía no se pactó.
  RealColumn get precio => real().nullable()();
  BoolColumn get activo => boolean().withDefault(const Constant(true))();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};

  /// Un proveedor suministra un insumo una sola vez: reactivar es un UPDATE de
  /// [activo], nunca un INSERT nuevo.
  @override
  List<Set<Column>> get uniqueKeys => [
    {insumoId, proveedorId},
  ];
}

/// Pedido RECURRENTE de un proveedor: la REGLA de una entrega que se repite
/// (HU-013). Un proveedor puede tener varias.
///
/// MODELO (decisión del PO, 2026-08-10): el pedido recurrente se confirma UNA
/// sola vez, al crearlo, y ahí se le avisa al proveedor. Desde entonces cada
/// entrega se materializa como un [Pedidos] REAL que nace directamente en
/// `en_espera` —el estado que habilita recibir— sin que nadie tenga que
/// aprobarla. La serie cicla hasta que la agenda se modifique o se dé de baja.
///
/// Hay EXACTAMENTE UNA entrega pendiente por agenda: la próxima no se agenda
/// hasta recepcionar la anterior. La regla es por AGENDA, nunca por proveedor
/// (que no lleguen las peras del lunes no bloquea las bananas del jueves).
///
/// Acá vive SÓLO la regla. Las ocurrencias futuras NO se persisten: la grilla
/// es infinita y reproducible, y guardarla sería un caché inválido apenas se
/// edita la configuración. La "próxima fecha" tampoco se guarda — sería un
/// campo derivado que dos dispositivos incrementan por separado, el LWW elige
/// uno y una entrega se puede SALTEAR.
@TableIndex(name: 'ix_agendas_negocio_activo', columns: {#negocioId, #activo})
@TableIndex(name: 'ix_agendas_proveedor', columns: {#proveedorId})
class PedidosRecurrentes extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get proveedorId =>
      text().references(Proveedores, #id, onDelete: KeyAction.cascade)();

  /// 'semanal' | 'mensual' | 'cada_n_dias'. Ver `utils/agenda_recurrente.dart`.
  TextColumn get tipo => text()();

  /// Sólo 'semanal'. BITMASK 1..127: bit `(weekday - 1)` con la convención de
  /// [DateTime.weekday] (1 = lunes). Una sola columna cubre un día o los siete.
  IntColumn get diasSemana => integer().nullable()();

  /// Sólo 'mensual'. 1..31 y SIN recortar: se guarda el día PEDIDO. Si se
  /// guardara el recortado, febrero degradaría la agenda a "día 28" para
  /// siempre. El desborde al mes siguiente lo hace Dart solo.
  IntColumn get diaMes => integer().nullable()();

  /// Sólo 'cada_n_dias'. >= 1. A propósito SIN tope: el PO pidió "una cantidad
  /// fija de días" y un CHECK lo estrecharía en silencio.
  IntColumn get cadaNDias => integer().nullable()();

  /// Sólo 'cada_n_dias': 'recepcion' (la cuenta arranca al recibir) o 'fija'
  /// (la grilla no espera a nadie).
  TextColumn get ancla => text().nullable()();

  /// ANCLA de toda la serie: día puro (medianoche local). Todo el calendario se
  /// deriva de acá y nunca de "hoy", por eso pausar y reanudar no corre la grilla.
  DateTimeColumn get fechaInicio => dateTime()();

  /// MEMORIA de la serie: última fecha ya emitida. El generador sólo emite
  /// fechas ESTRICTAMENTE POSTERIORES. Sin esto, "saltar esta vez" no existe:
  /// se borra la entrega de esta semana y el próximo arranque la resucita.
  DateTimeColumn get fechaUltimaOcurrenciaEmitida => dateTime().nullable()();

  /// MISMA forma de JSON que `pedidos.items`:
  /// `[{insumoId, nombre, unidad, cantidadPedida, precioUnitario}]`.
  /// En JSON y no en tabla hija: se leen siempre enteros, editar la lista es UN
  /// solo UPDATE en vez de N DELETE por el Outbox (la trampa de HU-141), y dos
  /// dispositivos editando dan una lista coherente en vez de una mezclada.
  TextColumn get items => text().withDefault(const Constant('[]'))();

  /// Se copian tal cual a cada entrega materializada.
  BoolColumn get tieneEfectivo =>
      boolean().withDefault(const Constant(false))();
  TextColumn get nota => text().nullable()();

  /// Baja LÓGICA. Por eso en Supabase NO se crea policy `FOR DELETE`: es la
  /// lección escrita de HU-138 / HU-141.
  BoolColumn get activo => boolean().withDefault(const Constant(true))();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tabla histórica de precios de los insumos (APPEND-ONLY, inmutable).
/// Vital para auditoría financiera de recetas y alertas de desviación (RN-005).
class HistorialPrecios extends Table {
  TextColumn get id => text()();
  // Tenant propio (HU-045): aislamiento directo por negocio, no transitivo vía insumo.
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get insumoId =>
      text().references(Insumos, #id, onDelete: KeyAction.cascade)();
  TextColumn get proveedorId => text().nullable().references(
    Proveedores,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get usuarioId =>
      text().nullable()(); // QUIÉN registró el cambio (RN-005)
  DateTimeColumn get fechaRegistro =>
      dateTime().withDefault(currentDateAndTime)();
  RealColumn get precioUnitarioNeto => real()();
  RealColumn get ivaPorcentaje =>
      real().withDefault(const Constant(0.21))(); // 0.21 = 21%, 0.105 = 10.5%
  TextColumn get origen => text()(); // compra_ocr, compra_manual, ajuste_manual
  TextColumn get referenciaId =>
      text().nullable()(); // id del pedido/recepción origen
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tabla que almacena alertas generadas cuando un insumo varía por encima del umbral.
class AlertasDesviacion extends Table {
  TextColumn get id => text()();
  // Tenant propio (HU-045): aislamiento directo por negocio, no transitivo vía insumo.
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get insumoId =>
      text().references(Insumos, #id, onDelete: KeyAction.cascade)();
  RealColumn get precioAnteriorNeto => real()();
  RealColumn get precioNuevoNeto => real()();
  RealColumn get porcentajeDesviacion =>
      real()(); // ej. 0.15 = +15% ; -0.12 = -12%
  BoolColumn get resuelta => boolean().withDefault(const Constant(false))();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tabla de Pedidos de mercadería hechos a proveedores.
/// Estados (RN-012): borrador, enviado, recibido_parcial, recibido_completo, facturado, cancelado.
@TableIndex(name: 'ix_pedidos_agenda', columns: {#agendaId})
class Pedidos extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get proveedorNombre =>
      text()(); // denormalizado para búsqueda/operación offline
  TextColumn get proveedorId => text().nullable().references(
    Proveedores,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get estado => text().withDefault(const Constant('borrador'))();
  TextColumn get nota => text().nullable()();
  TextColumn get creadoPor =>
      text().nullable()(); // UUID de Usuarios (referencia lógica)
  TextColumn get creadoPorNombre =>
      text().nullable()(); // denormalizado para UI offline
  TextColumn get recepcionadoPor =>
      text().nullable()(); // UUID de Usuarios (referencia lógica)
  TextColumn get recepcionadoPorNombre => text().nullable()();

  /// #273: cuándo y quién envió el pedido al proveedor.
  ///
  /// Hasta #273 este hecho no quedaba registrado en NINGÚN lado: el service
  /// escribía `estado = 'enviado'` y nada más. Va como columna de la fila y no
  /// como registro de auditoría a propósito: `registros_auditoria` SUBE y NO
  /// BAJA en el pull, así que una fila ahí sólo la vería el dispositivo que la
  /// generó, y la trazabilidad se mira desde cualquiera.
  ///
  /// `enviadoPorNombre` está denormalizado por el mismo motivo que
  /// `creadoPorNombre`: la app funciona offline y el UUID no se puede resolver
  /// contra una tabla que quizá no bajó.
  DateTimeColumn get fechaEnvio => dateTime().nullable()();
  TextColumn get enviadoPor => text().nullable()();
  TextColumn get enviadoPorNombre => text().nullable()();

  TextColumn get items => text().withDefault(
    const Constant('[]'),
  )(); // JSON de los ítems solicitados
  RealColumn get total => real().nullable()();
  BoolColumn get tieneEfectivo =>
      boolean().withDefault(const Constant(false))();
  TextColumn get alertas =>
      text().nullable()(); // JSON con discrepancias detectadas al recibir
  /// HU-142: día en que se pide recibir la mercadería. NULL = sin fecha pedida
  /// (el campo es OPCIONAL). Es un día de calendario: se guarda a medianoche
  /// local y en Supabase es `date`, no `timestamptz`. Ver utils/fecha_recepcion.dart.
  DateTimeColumn get fechaRecepcionSolicitada => dateTime().nullable()();

  /// HU-013: agenda que generó este pedido. NULL = pedido normal.
  ///
  /// Referencia LÓGICA a propósito (convención de [creadoPor]), NO `.references()`:
  ///  • cada tabla del pull tiene su try/catch aislado, así que con FK dura y
  ///    `PRAGMA foreign_keys = ON` un fallo al bajar `pedidos_recurrentes` haría
  ///    reventar TODOS los pedidos recurrentes al insertar, en silencio: se
  ///    perderían pedidos reales por una tabla de configuración caída;
  ///  • con `onDelete: setNull`, dar de baja la agenda le sacaría la marca de
  ///    "recurrente" a los pedidos YA recibidos del Historial y se perdería la
  ///    procedencia.
  TextColumn get agendaId => text().nullable()();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tabla de eventos de Recepción de mercadería (RN-013 / HU-014 / HU-015).
/// Cada recepción es un evento independiente que NO reemplaza a los anteriores:
/// las cantidades recibidas se ACUMULAN por ítem entre eventos.
///
/// HU-143: deja de ser append-only pura y pasa a MUTABLE ACOTADA — lo único
/// editable después del alta es el total manual ([totalRecibido] + su autoría),
/// vía `RepositorioRecepciones.actualizarTotalRecibido`. Los `items` (evidencia,
/// motivos, comentarios) siguen siendo inmutables por contrato del repositorio.
/// Por eso lleva `version` + `fechaActualizacion` (token de concurrencia LWW,
/// misma convención que las tablas mutables, HU-028).
@DataClassName('Recepcion')
class Recepciones extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get pedidoId =>
      text().references(Pedidos, #id, onDelete: KeyAction.cascade)();
  IntColumn get numeroRecepcion =>
      integer().withDefault(const Constant(1))(); // secuencia por pedido

  // HU-121: la secuencia es única POR PEDIDO (espejo del UNIQUE server-side).
  // El server renumera en colisión (BEFORE INSERT) y el pull reconcilia el local.
  @override
  List<Set<Column>> get uniqueKeys => [
    {pedidoId, numeroRecepcion},
  ];
  TextColumn get recepcionadoPor => text().nullable()(); // UUID de Usuarios
  TextColumn get recepcionadoPorNombre => text().nullable()();
  // JSON: [{insumoId, cantidadPedida, cantidadRecibida, precioUnitario, estado}]
  // #229: `precioUnitario` acá es la ESTIMACIÓN copiada del pedido, NO el costo
  // real — ése vive en `factura_items`, cargado al procesar. Se conserva porque
  // sostiene el total estimado del evento y `montoRecibido` en Pagos.
  TextColumn get items => text()();
  TextColumn get nota => text().nullable()();

  // HU-143: total escrito a mano según el remito/factura del proveedor. Si es
  // NULL vale el total derivado de las líneas (totalFacturable); si no, MANDA
  // sobre el calculado y queda marcado quién y cuándo lo editó.
  RealColumn get totalRecibido => real().nullable()();
  TextColumn get totalEditadoPor => text().nullable()(); // UUID de Usuarios
  TextColumn get totalEditadoPorNombre => text().nullable()();
  DateTimeColumn get fechaTotalEditado => dateTime().nullable()();

  DateTimeColumn get fechaRecepcion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Catálogo de motivos de rechazo/observación de recepción, por negocio (HU-065).
/// Gestionable por el admin; soft-delete vía [activo]. Aislamiento correlacionado
/// por fila (negocio_id), igual que proveedores/insumos. La unicidad por nombre se
/// declara aquí (backstop exacto) y la valida el Service de forma case-insensitive.
class MotivosRecepcion extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get nombre => text()();
  BoolColumn get activo => boolean().withDefault(const Constant(true))();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {negocioId, nombre},
  ];
}

/// Catálogo de CATEGORÍAS de insumo (rediseño insumos-por-categoría).
///
/// La categoría deja de ser un texto libre en `insumos.categoria` y pasa a ser
/// una entidad de primera clase, gestionable por el admin (CRUD), con soft-delete
/// vía [activo]. Mismo patrón exacto que [MotivosRecepcion]: aislamiento por fila
/// (negocio_id), unicidad {negocio, nombre} declarada acá como backstop y validada
/// case-insensitive por el Service. Cada proveedor suministra un conjunto de estas
/// categorías (tabla puente `ProveedorCategorias`) y cada insumo pertenece a una
/// (`insumos.categoriaId`).
class Categorias extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get nombre => text()();
  BoolColumn get activo => boolean().withDefault(const Constant(true))();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {negocioId, nombre},
  ];
}

/// Qué CATEGORÍAS suministra un proveedor (#262). Tabla PUENTE proveedor↔categoría.
///
/// Reemplaza el eje insumo↔proveedor de [InsumoProveedores]: en vez de decir "este
/// proveedor surte este insumo", dice "este proveedor surte esta categoría", y al
/// armar un pedido se ofrecen los insumos de esas categorías. Mismo patrón que
/// [InsumoProveedores] —tenant propio, id determinista, baja lógica, version— PERO
/// SIN `precio`: el precio de lista por vínculo se abandona (decisión del PO — el
/// costo se estima sobre el último costo real tras procesar la recepción).
class ProveedorCategorias extends Table {
  /// DETERMINISTA: `md5(proveedorId + ':' + categoriaId)`. Ver [IdDeterminista].
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get proveedorId =>
      text().references(Proveedores, #id, onDelete: KeyAction.cascade)();
  TextColumn get categoriaId =>
      text().references(Categorias, #id, onDelete: KeyAction.cascade)();
  BoolColumn get activo => boolean().withDefault(const Constant(true))();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};

  /// Un proveedor suministra una categoría una sola vez: desasignar es un UPDATE
  /// de [activo], nunca un INSERT nuevo.
  @override
  List<Set<Column>> get uniqueKeys => [
    {proveedorId, categoriaId},
  ];
}

/// Tabla de Adjuntos (remitos) — APPEND-ONLY (HU-066).
///
/// Cada fila es UN archivo: una recepción admite varios remitos (varias filas).
/// FK dura a [Recepciones]: el remito documenta ESE evento de recepción; el pedido
/// se obtiene siempre vía `recepcion.pedidoId`. Los bytes se guardan localmente en
/// [contenido] (BLOB, eficiente, sin el +33% de base64) y se sincronizan como base64
/// (texto) por el Outbox — esa (de)codificación vive SOLO en el repositorio, nunca
/// en controladores/vistas. [datosOcr] queda como base para el reconocimiento de
/// HU-068 (no se usa todavía).
@DataClassName('Adjunto')
class Adjuntos extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();

  // #238: el adjunto cuelga de UNA de dos entidades — la recepción (remitos,
  // facturas, comprobantes del efectivo) o el pago (el comprobante de la
  // transferencia: un pago puede imputar varias facturas o ser un anticipo,
  // así que no hay recepción única a la que colgarlo). Exactamente-uno lo
  // exigen el CHECK del servidor y el ArgumentError del repositorio; acá no
  // hay CHECK de SQLite a propósito — una recreación de tabla que fallara por
  // una fila legado sería peor que validar en el repo.
  TextColumn get recepcionId => text().nullable().references(
    Recepciones,
    #id,
    onDelete: KeyAction.cascade,
  )();

  // Referencia LÓGICA a Pagos, sin `.references()` (precedente: `agendaId`):
  // el pull baja `adjuntos` ANTES que `pagos`, y con PRAGMA foreign_keys=ON
  // una FK dura reventaría esos upserts. En el remoto la FK real la satisface
  // el orden FIFO del Outbox (el INSERT del pago se encola antes que el del
  // adjunto, en la misma transacción).
  TextColumn get pagoId => text().nullable()();
  TextColumn get nombreArchivo => text()();
  TextColumn get mimeType => text()(); // application/pdf, image/jpeg, image/png
  IntColumn get tamanioBytes => integer().withDefault(const Constant(0))();

  /// Bytes del archivo, o NULL = "todavía no bajado a este dispositivo"
  /// (#248). El pull baja solo METADATOS; los bytes llegan bajo demanda la
  /// primera vez que el visor abre el adjunto y quedan cacheados acá. NULL y
  /// vacío son cosas distintas a propósito: un archivo vacío jamás entra
  /// (lo rechaza `ServicioAdjuntos.validar`), así que NULL siempre significa
  /// "pedilo al servidor". Los adjuntos creados EN este dispositivo nacen
  /// con sus bytes, como siempre.
  BlobColumn get contenido => blob().nullable()();
  // Tipo del adjunto (HU-069): 'remito' (mercadería, HU-066) o 'comprobante' (pago de
  // la factura). Default 'remito' para las filas históricas. Ver [TipoAdjunto].
  TextColumn get tipo => text().withDefault(const Constant('remito'))();
  TextColumn get datosOcr =>
      text().nullable()(); // JSON del reconocimiento futuro (HU-068)
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// #250: cursor de pull incremental por (negocio, tabla). Guarda la ALTA-MARCA
/// (high-water-mark) del timestamp server-set más nuevo ya aplicado localmente:
/// el próximo pull de esa tabla pide sólo `>= cursor − lag`, en vez de todo.
///
/// Es estado LOCAL PURO, derivado de lo ya bajado — NUNCA se encola en el
/// Outbox ni sube al servidor (mismo trato que el caché de bytes de #248).
/// Vacío = todavía nunca se pulleó esa tabla en este dispositivo = pull
/// completo (cursor epoch). El nombre de tabla es el REMOTO (snake_case), la
/// clave que usa el orquestador.
class CursoresPull extends Table {
  TextColumn get negocioId => text()();

  /// Nombre de la tabla remota (p.ej. 'recepciones'), tal como la pide el pull.
  TextColumn get tabla => text()();

  /// Alta-marca aplicada: el `updated_at`/`created_at` más nuevo ya escrito
  /// localmente para esta (negocio, tabla). El filtro del próximo pull resta el
  /// lag de seguridad a este valor.
  DateTimeColumn get cursor => dateTime()();

  @override
  Set<Column> get primaryKey => {negocioId, tabla};
}

/// Tabla de Facturas de proveedor. La DEUDA NACE con la factura (RN-014 / HU-023).
class Facturas extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get proveedorId => text().nullable().references(
    Proveedores,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get pedidoId =>
      text().nullable().references(Pedidos, #id, onDelete: KeyAction.setNull)();
  // Recepción/remito facturado (HU-067): se factura "contra remito" por lo recibido,
  // no por el pedido completo. Nullable para no romper las facturas históricas
  // (creadas a nivel pedido antes de HU-067) ni el aislamiento append-only.
  TextColumn get recepcionId => text().nullable().references(
    Recepciones,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get numeroFactura => text()();
  DateTimeColumn get fechaFactura =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaVencimiento => dateTime()();
  RealColumn get totalNeto => real()();
  RealColumn get ivaTotal => real().withDefault(const Constant(0.0))();
  RealColumn get totalBruto => real()();
  TextColumn get estado => text().withDefault(
    const Constant('pendiente'),
  )(); // pendiente, parcial, pagada, anulada
  TextColumn get comprobanteUrl => text().nullable()();
  TextColumn get comentario =>
      text().nullable()(); // nota libre al facturar (HU-069)
  TextColumn get creadoPor => text().nullable()(); // UUID de Usuarios
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};

  // Número de factura único por proveedor dentro del negocio (HU-023).
  @override
  List<Set<Column>> get uniqueKeys => [
    {negocioId, proveedorId, numeroFactura},
  ];
}

/// Tabla de Pagos a proveedores (HU-024). Cada pago tiene identificador idempotente.
class Pagos extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get proveedorId =>
      text().references(Proveedores, #id, onDelete: KeyAction.cascade)();
  RealColumn get monto => real()(); // > 0
  TextColumn get metodo => text()(); // efectivo, transferencia, cheque
  TextColumn get referenciaExterna =>
      text().nullable()(); // nro comprobante (idempotencia)
  DateTimeColumn get fechaPago => dateTime().withDefault(currentDateAndTime)();
  TextColumn get nota => text().nullable()();
  TextColumn get creadoPor => text().nullable()(); // UUID de Usuarios
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// El detalle por insumo de una factura de compra (#229).
///
/// Hasta acá la factura sólo tenía los tres importes de CABECERA (`totalNeto`,
/// `ivaTotal`, `totalBruto`), que alcanzaban mientras la pantalla pedía un único
/// número. La de procesar recepción carga el costo insumo por insumo, y eso
/// necesita renglones.
///
/// ── Por qué tabla y no un JSON en `facturas` ────────────────────────────────
/// El detalle se suma y se agrupa: "cuánto compré de tomate este mes" es una
/// consulta natural sobre esta tabla y un parseo a mano sobre un JSON. Además
/// una columna `jsonb` no valida nada: nada impediría guardar una alícuota en
/// escala equivocada, que es justo el error que #229 vino a corregir.
///
/// Tampoco va en `recepciones.items`: ese JSON es evidencia inmutable de lo que
/// entró —el pull ni siquiera lo pisa (HU-143)— y el costo se decide después,
/// al procesar. Mezclarlos ensucia la evidencia con una corrección posterior.
///
/// ── Se guarda POCO y se deriva el resto ─────────────────────────────────────
/// Sólo los tres datos independientes: [cantidad], [netoUnitario] y [alicuota].
/// El subtotal neto, el unitario con IVA, el IVA de la línea y el subtotal con
/// IVA son aritmética de `LineaCosto` (`lib/utils/iva.dart`). Guardar un
/// derivado sería guardar una segunda verdad que puede contradecir a la primera.
///
/// Con estos renglones el trío de cabecera pasa a ser verificable: `ResumenIva`
/// redondea el IVA POR LÍNEA y recién después suma, así que con alícuotas
/// mezcladas `iva_total` NO se puede reconstruir desde `total_neto`. Sin el
/// detalle, ese número habría que creerlo.
@DataClassName('FacturaItem')
class FacturaItems extends Table {
  TextColumn get id => text()();

  /// Tenant propio (HU-045): el aislamiento es directo y no transitivo vía la
  /// factura. Es el patrón de la casa y lo que el verificador de migraciones
  /// mira en `information_schema` para las tablas hijas.
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get facturaId =>
      text().references(Facturas, #id, onDelete: KeyAction.cascade)();

  /// A qué insumo se le cargó este costo. Es el argumento con el que se llama a
  /// `ServicioPrecios.registrar`, así que sin él el renglón no costea nada.
  ///
  /// SIN `onDelete`: a diferencia de la factura —que sí puede arrastrar a sus
  /// renglones— un insumo que desaparece no puede llevarse el detalle de una
  /// factura ya emitida, ni dejarlo apuntando a la nada. Los insumos se archivan
  /// (`activo = false`), no se borran, justamente por esto.
  TextColumn get insumoId => text().references(Insumos, #id)();

  /// Cuánto entró. Viene de la recepción y NO se edita al procesar: lo que se
  /// carga acá es el precio, no la cantidad.
  RealColumn get cantidad => real()();

  /// Precio NETO de una unidad, sin IVA.
  RealColumn get netoUnitario => real()();

  /// Alícuota en FRACCIÓN: 0.21 = 21%, 0.105 = 10.5%, 0 = exento.
  ///
  /// La escala está declarada igual de los dos lados a propósito. La columna
  /// vieja `historial_precios.iva_porcentaje` nació en fracción en Drift y en
  /// PORCENTAJE en Postgres (`DEFAULT 21.0`), y no explotó de casualidad: el
  /// cliente manda siempre el valor explícito. La migración de #229 corrige
  /// aquella y estrena ésta ya alineada.
  RealColumn get alicuota => real().withDefault(const Constant(0.21))();

  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();

  @override
  Set<Column> get primaryKey => {id};

  /// Un renglón por insumo en cada factura. Cargar dos veces el mismo insumo no
  /// es un caso de uso: es un doble tap o una pantalla reintentando, y el
  /// resultado sería un total inflado que cuadra consigo mismo y no con el
  /// papel del proveedor.
  @override
  List<Set<Column>> get uniqueKeys => [
    {facturaId, insumoId},
  ];
}

/// Tabla de imputaciones: aplica un Pago a una Factura (HU-024 / HU-025). Append-only.
@DataClassName('ImputacionPago')
class ImputacionesPago extends Table {
  TextColumn get id => text()();
  // Tenant propio (HU-045): aislamiento directo por negocio, no transitivo vía factura/pago.
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get pagoId =>
      text().references(Pagos, #id, onDelete: KeyAction.cascade)();
  TextColumn get facturaId =>
      text().references(Facturas, #id, onDelete: KeyAction.cascade)();
  RealColumn get montoImputado => real()(); // > 0
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Saldo a favor (anticipo) acumulado por proveedor (HU-024 / HU-025).
class Anticipos extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get proveedorId =>
      text().references(Proveedores, #id, onDelete: KeyAction.cascade)();
  RealColumn get saldo => real().withDefault(const Constant(0.0))();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {negocioId, proveedorId},
  ];
}

/// Cronología de cuenta corriente por proveedor (APPEND-ONLY, HU-025).
/// Débitos (facturas) y créditos (pagos/anticipos) con saldo acumulado.
@DataClassName('MovimientoCuentaCorriente')
class MovimientosCuentaCorriente extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get proveedorId =>
      text().references(Proveedores, #id, onDelete: KeyAction.cascade)();
  TextColumn get tipoMovimiento =>
      text()(); // factura, pago, anticipo, nota_credito, ajuste
  RealColumn get monto => real()(); // débito (+) o crédito (-)
  RealColumn get saldo => real()(); // saldo acumulado tras este movimiento
  TextColumn get referenciaId =>
      text().nullable()(); // id de la factura/pago/ajuste
  TextColumn get descripcion => text().nullable()();
  DateTimeColumn get fechaMovimiento =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Auditoría inmutable de operaciones críticas (APPEND-ONLY, HU-030 / RNF-006).
@DataClassName('RegistroAuditoria')
class RegistrosAuditoria extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get usuarioId => text().nullable()();
  TextColumn get tablaAfectada => text()();
  TextColumn get registroId => text()();
  TextColumn get accion => text()(); // INSERT, UPDATE, DELETE
  TextColumn get datosAntes => text().nullable()(); // JSON
  TextColumn get datosDespues => text().nullable()(); // JSON
  TextColumn get origen => text().withDefault(
    const Constant('app_offline'),
  )(); // app_offline, app_online, api
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();

  /// #273: cuándo pasó el hecho, que NO es cuándo se subió.
  ///
  /// El payload del push no mandaba ninguna fecha y la tabla remota tiene
  /// `created_at DEFAULT now()`, así que un hecho del lunes que se drena el
  /// jueves quedaba fechado el jueves. Una auditoría con la fecha del flush no
  /// sirve para auditar.
  ///
  /// Columna APARTE y no reusar `created_at`: ese campo es el CURSOR del pull
  /// incremental (#250). Si lo escribiéramos con la fecha del hecho, un registro
  /// viejo que se sube hoy quedaría por debajo del cursor y el pull no lo vería
  /// nunca.
  DateTimeColumn get ocurridoEn => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Configuración por negocio (HU-031): umbrales, moneda y catálogos configurables.
class ConfiguracionNegocio extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();

  /// Umbral de desviación que dispara alerta de precio (HU-018). El default
  /// sale del servicio para que no viva duplicado (#203).
  RealColumn get umbralAlertaDesviacion => real().withDefault(
    const Constant(ServicioConfiguracionNegocio.umbralAlertaPorDefecto),
  )();
  TextColumn get moneda => text().withDefault(const Constant('ARS'))();
  TextColumn get simboloMoneda => text().withDefault(const Constant('\$'))();
  TextColumn get pais => text().withDefault(const Constant('Argentina'))();
  TextColumn get idioma => text().withDefault(const Constant('es'))();

  /// Umbrales del semáforo de FoodCost (HU-031). El default sale de
  /// [CalculadoraCostos] para que el número no viva duplicado (#197).
  RealColumn get foodcostVerdeMax => real().withDefault(
    const Constant(CalculadoraCostos.umbralVerdePorDefecto),
  )();
  RealColumn get foodcostAmarilloMax => real().withDefault(
    const Constant(CalculadoraCostos.umbralAmarilloPorDefecto),
  )();

  /// Costo de la hora de trabajo, para la mano de obra de las recetas (HU-152).
  ///
  /// NULLABLE y sin default a propósito: `null` = "no configurado", que es
  /// distinto de "configurado en cero". Con `withDefault(0)` los dos casos serían
  /// indistinguibles y la app no podría avisar por qué la mano de obra dio cero
  /// — que es un criterio explícito de la HU (misma lección que HU-150).
  RealColumn get costoHoraEmpleado => real().nullable()();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {negocioId},
  ];
}

/// Tabla de Recetas registradas para calcular costos del menú.
class Recetas extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get nombre => text()();
  RealColumn get porciones => real().withDefault(const Constant(1.0))();
  RealColumn get precioVentaCarta => real().nullable()();
  RealColumn get margenDeseadoPorcentaje => real().nullable()();
  TextColumn get categoria => text().withDefault(const Constant('Principal'))();

  /// Minutos que lleva elaborar la receta (HU-152).
  ///
  /// NULLABLE: las recetas que ya existen no declararon tiempo, y eso NO es lo
  /// mismo que "se hace en cero minutos". La app avisa en vez de calcular una
  /// mano de obra de 0 como si fuera un dato.
  RealColumn get tiempoElaboracionMinutos => real().nullable()();
  TextColumn get imagenUrl => text().nullable()();
  BoolColumn get archivada => boolean().withDefault(const Constant(false))();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tabla intermedia que asocia insumos (o sub-recetas) con una receta madre.
class RecetaIngredientes extends Table {
  TextColumn get id => text()();
  // Tenant propio (HU-045): aislamiento directo por negocio, no transitivo vía receta.
  TextColumn get negocioId =>
      text().references(Negocios, #id, onDelete: KeyAction.cascade)();
  TextColumn get recetaId =>
      text().references(Recetas, #id, onDelete: KeyAction.cascade)();
  TextColumn get insumoId =>
      text().references(Insumos, #id, onDelete: KeyAction.cascade)();
  RealColumn get cantidadNeta => real()();
  TextColumn get unidadCantidad => text()
      .nullable()(); // unidad en que se ingresó la cantidad (para conversión)
  RealColumn get desperdicioPorcentaje =>
      real().withDefault(const Constant(0.0))(); // 0.10 = 10% merma
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get estadoSync =>
      text().withDefault(const Constant('pendiente'))();

  @override
  Set<Column> get primaryKey => {id};

  // Un insumo no puede repetirse dentro de la misma receta (RN-008).
  @override
  List<Set<Column>> get uniqueKeys => [
    {recetaId, insumoId},
  ];
}

/// Tabla de cola de operaciones para sincronización diferida (Outbox Pattern).
/// Conflictos de sincronización detectados (HU-028). APPEND-ONLY y **local**:
/// es la bitácora de "acá dos versiones del mismo registro se cruzaron". No se
/// sincroniza (cada dispositivo registra los suyos) y no se borra: se marca
/// [resueltoEn] para que un conflicto ya atendido no reaparezca.
class ConflictosSync extends Table {
  TextColumn get id => text()();
  TextColumn get negocioId => text().nullable()();
  TextColumn get nombreTabla => text()();
  TextColumn get registroId => text()();

  /// `push_rechazado` (el servidor tenía otra versión: HU-028 fase 2),
  /// `pull_piso_local` (el remoto ganó sobre un cambio local en vuelo),
  /// `pull_rechazado` (se conservó lo local: append-only o importes divergentes).
  TextColumn get motivo => text()();

  /// Versiones en juego al detectarlo: permiten no duplicar el mismo conflicto
  /// y reconstruir qué pasó.
  IntColumn get versionLocal => integer().nullable()();
  IntColumn get versionRemota => integer().nullable()();

  TextColumn get detalle => text().nullable()(); // JSON/texto libre
  DateTimeColumn get fechaDeteccion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get resueltoEn => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class ColaSincronizacion extends Table {
  TextColumn get id => text()();
  TextColumn get nombreTabla =>
      text()(); // Tabla destino en el backend (ej: "insumos")
  TextColumn get registroId => text()(); // ID del registro afectado
  TextColumn get accion => text()(); // INSERT, UPDATE, DELETE
  TextColumn get payload =>
      text()(); // Representación en JSON (snake_case) del objeto modificado
  // HU-028: `version` que tenía la fila REMOTA cuando se leyó (token de
  // concurrencia optimista). El push la usa como predicado del UPDATE: si en el
  // servidor ya cambió, el UPDATE no afecta filas → hay conflicto, en vez de
  // pisar a ciegas. Null en INSERT/DELETE y en tablas sin `version`.
  IntColumn get versionBase => integer().nullable()();
  IntColumn get intentos => integer().withDefault(const Constant(0))();
  IntColumn get maxIntentos =>
      integer().withDefault(const Constant(8))(); // tope antes de dead-letter
  TextColumn get ultimoError => text().nullable()();

  /// Momento a partir del cual conviene volver a intentar esta mutacion (C-02).
  ///
  /// NULLABLE = "intentala ya". El drenaje filtra por esta columna, asi que un
  /// fallo no vuelve a golpear al servidor —ni a la red— en el mismo segundo.
  ///
  /// Existe porque el docstring del servicio prometia "reintentos con backoff"
  /// desde el dia uno y no habia ninguno: cada mutacion local drenaba la cola
  /// entera, y ocho mutaciones offline seguidas mandaban la primera a
  /// dead-letter antes de haber tenido una sola chance real de subir.
  DateTimeColumn get fechaProximoIntento => dateTime().nullable()();
  DateTimeColumn get fechaCreacion =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get fechaActualizacion =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// ─── CLASE DE CONEXIÓN A LA BASE DE DATOS (BASE DATOS APP) ───────────────────

@DriftDatabase(
  tables: [
    Negocios,
    Usuarios,
    Proveedores,
    Insumos,
    InsumoProveedores,
    PedidosRecurrentes,
    HistorialPrecios,
    AlertasDesviacion,
    Pedidos,
    Recepciones,
    MotivosRecepcion,
    Categorias,
    ProveedorCategorias,
    Adjuntos,
    Facturas,
    FacturaItems,
    Pagos,
    ImputacionesPago,
    Anticipos,
    MovimientosCuentaCorriente,
    RegistrosAuditoria,
    ConfiguracionNegocio,
    Recetas,
    RecetaIngredientes,
    ColaSincronizacion,
    ConflictosSync,
    CursoresPull,
  ],
)
class BaseDatosApp extends _$BaseDatosApp {
  BaseDatosApp() : super(conn.connect());

  /// Constructor que permite inyectar un [QueryExecutor] (útil para tests con BD en memoria).
  BaseDatosApp.conEjecutor(super.executor);

  @override
  int get schemaVersion => 25;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
      // `createAll()` NO emite los índices de `_crearIndices`: sólo los
      // `@TableIndex` y los `uniqueKeys` declarados en las tablas. Sin esta
      // línea, TODA instalación nueva corría sin los índices de rendimiento
      // (#190) — sin fallar nada, sólo con consultas más lentas en silencio.
      await _crearIndices();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      // v1 → v2 (legado): se recreaba todo el esquema.
      //
      // Ojo con el `return`: se saltea todo lo que viene después, incluida
      // la creación de índices del final. Por eso se la llama acá también
      // — si no, una base migrada desde v1 quedaría sin índices, que es el
      // mismo bug de #190 con otro disfraz.
      if (from < 2) {
        for (final table in allTables) {
          await m.deleteTable(table.actualTableName);
        }
        await m.createAll();
        await _crearIndices();
        return;
      }

      // v2 → v3: migración INCREMENTAL, NO destructiva (RNF-010 / R-008).
      if (from < 3) {
        await _migrarV2aV3(m);
      }

      // v3 → v4: tenant propio (negocio_id + FK) en las 4 tablas que aislaban
      // de forma transitiva (HU-045).
      if (from < 4) {
        await _migrarV3aV4(m);
      }

      // v4 → v5: catálogo de motivos de recepción (HU-065). NO destructiva.
      if (from < 5) {
        await _migrarV4aV5(m);
      }

      // v5 → v6: tabla de adjuntos/remitos (HU-066). NO destructiva.
      if (from < 6) {
        await _migrarV5aV6(m);
      }

      // v6 → v7: recepcionId en facturas (HU-067, factura contra remito). NO destructiva.
      if (from < 7) {
        await _migrarV6aV7(m);
      }

      // v7 → v8: tipo en adjuntos + comentario en facturas (HU-069). NO destructiva.
      if (from < 8) {
        await _migrarV7aV8(m);
      }

      // v8 → v9: elimina la columna huérfana usuarios.pin_hash (HU-112). Drift
      // recrea la tabla desde el esquema actual (sin pin_hash), copiando el resto
      // de los datos; SQLite no soporta DROP COLUMN directo en versiones viejas.
      if (from < 9) {
        await m.alterTable(TableMigration(usuarios));
      }

      // v9 → v10: unicidad (pedido_id, numero_recepcion) en recepciones
      // (HU-121), con saneo previo de duplicados. NO destructiva.
      if (from < 10) {
        await _migrarV9aV10(m);
      }

      // v10 → v11: token de concurrencia optimista en la cola (HU-028).
      // Columna nullable → ALTER TABLE ADD COLUMN, no destructiva.
      if (from < 11) {
        await m.addColumn(colaSincronizacion, colaSincronizacion.versionBase);
      }

      // v11 → v12: bitácora local de conflictos (HU-028). Tabla nueva, no
      // toca datos existentes.
      if (from < 12) {
        await m.createTable(conflictosSync);
      }

      // v12 → v13: total recibido manual + token de concurrencia en
      // recepciones (HU-143). Columnas nuevas nullable/con default →
      // ALTER TABLE ADD COLUMN, no destructiva.
      if (from < 13) {
        await _migrarV12aV13(m);
      }

      // v13 → v14: un insumo pasa a tener VARIOS proveedores (HU-138).
      // Tabla nueva + backfill del vínculo que hoy vive en
      // `insumos.proveedor_id` (que queda deprecada, NO se borra: recrear
      // `insumos` con tres hijas en CASCADE es la operación más riesgosa
      // del repo y acá no hace falta).
      //
      // Va como v14 y NO como v13 porque HU-143 ya se llevó ese número en
      // `dev`: un dispositivo que instaló ese build está en 13, así que un
      // `from < 13` nunca se ejecutaría en él y se quedaría SIN la tabla.
      //
      // `createTable` es seguro con los defaults no constantes de las fechas
      // (el problema documentado en docs/migraciones-drift-default-no-constante.md
      // es exclusivo de `addColumn`, que acá no se usa).
      if (from < 14) {
        await m.createTable(insumoProveedores);
        await MigradorInsumosV14.backfillVinculos(this);
      }

      // v14 → v15: fecha de recepción deseada en el pedido (HU-142).
      //
      // La columna es NULLABLE y SIN default, que es la única forma segura
      // de sumar una fecha con `addColumn`: el patrón peligroso documentado
      // en docs/migraciones-drift-default-no-constante.md es el default NO
      // constante (currentDateAndTime), que SQLite rechaza en ALTER TABLE.
      // NULL además es el valor correcto de negocio: los pedidos que ya
      // existen no pidieron ninguna fecha.
      if (from < 15) {
        await m.addColumn(pedidos, pedidos.fechaRecepcionSolicitada);
      }

      // v15 → v16: pedidos recurrentes por proveedor (HU-013). Tabla nueva
      // + la marca de procedencia en el pedido.
      //
      // El `addColumn` es seguro por el mismo motivo que el de v15: la
      // columna es NULLABLE y SIN default (ver
      // docs/migraciones-drift-default-no-constante.md). NULL es además el
      // valor de negocio correcto: los pedidos que ya existen no vinieron
      // de ninguna agenda.
      //
      // Los índices van declarados con `@TableIndex` y NO en `_crearIndices`:
      // `onCreate` sólo llama a `createAll()` y nunca a `_crearIndices`, así
      // que un índice agregado ahí no existiría en una instalación NUEVA.
      // `createAll()` sí los emite solo.
      //
      // PERO `m.createTable()` NO: crea la tabla y nada más. Verificado con
      // un test —`migracion_agendas_v16_test`— que abre la base migrada y
      // lee `sqlite_master`: sin los `createIndex` de abajo, un dispositivo
      // que ACTUALIZA se queda sin los tres índices mientras que uno que
      // instala de cero los tiene. Es una diferencia invisible: no falla
      // nada, sólo se degrada la consulta, y justo en los equipos que más
      // datos acumularon.
      if (from < 16) {
        await m.createTable(pedidosRecurrentes);
        await m.addColumn(pedidos, pedidos.agendaId);
        await m.createIndex(ixAgendasNegocioActivo);
        await m.createIndex(ixAgendasProveedor);
        await m.createIndex(ixPedidosAgenda);
      }

      // v16 → v17: mano de obra en el costo de la receta (HU-152).
      //
      // Las dos columnas son NULLABLE y SIN default, que además de ser el
      // patrón seguro para `addColumn` (ver
      // docs/migraciones-drift-default-no-constante.md) es el valor correcto
      // de negocio: NULL significa "no configurado", distinto de cero. Con
      // un default de 0 no habría forma de distinguir "no lo cargaste" de
      // "vale cero", y la app no podría avisar por qué la mano de obra dio 0.
      if (from < 17) {
        await m.addColumn(recetas, recetas.tiempoElaboracionMinutos);
        await m.addColumn(
          configuracionNegocio,
          configuracionNegocio.costoHoraEmpleado,
        );
      }

      // v17 → v18: momento del próximo intento en la cola (C-02).
      //
      // NULLABLE y sin default, que además de ser el patrón seguro para
      // `addColumn` es el valor correcto de negocio: las mutaciones que ya están
      // encoladas tienen que poder intentarse YA, no esperar a nada.
      if (from < 18) {
        await m.addColumn(
          colaSincronizacion,
          colaSincronizacion.fechaProximoIntento,
        );
      }

      if (from < 19) {
        // #220: los datos con los que se le transfiere al proveedor. El SQL
        // equivalente en Supabase es
        // `20260825120000_datos_bancarios_proveedor.sql`, y va SIEMPRE primero:
        // `MapeadoresSupabase.proveedor` manda un mapa de claves explícito, así
        // que un cliente con estas columnas contra un servidor sin ellas manda
        // a dead-letter TODO insert y update de proveedores, no sólo los campos
        // nuevos.
        await m.addColumn(proveedores, proveedores.aliasBancario);
        await m.addColumn(proveedores, proveedores.cbu);
      }

      if (from < 20) {
        // #229: el detalle por insumo de la factura. Su SQL equivalente es
        // `20260827120000_hu229_factura_items.sql` y, como siempre, va PRIMERO:
        // un cliente que empieza a mandar `factura_items` contra un servidor
        // que no tiene la tabla manda esas filas a dead-letter.
        //
        // `createTable` y no `addColumn`: es una tabla nueva, así que el
        // dispositivo que migra no tiene nada que convertir. Las facturas
        // viejas se quedan sin renglones —que es la verdad: se cargaron con un
        // único importe— y por eso el detalle NO se exige para leer una
        // factura, sólo se escribe al procesar de acá en adelante.
        await m.createTable(facturaItems);
      }

      if (from < 21) {
        // #238: el comprobante de la transferencia cuelga del PAGO —
        // `recepcion_id` pasa a nullable y nace `pago_id` (referencia lógica,
        // ver la tabla). Su SQL equivalente es
        // `20260831120000_hu238_comprobante_de_pago.sql` y, como siempre, va
        // PRIMERO: un cliente que empiece a mandar `pago_id` contra un
        // servidor sin la columna manda TODOS los INSERT de adjuntos
        // (remitos incluidos) a dead-letter.
        //
        // `alterTable`: recreación con copia de filas — BLOBs incluidos, así
        // que en bases con muchos remitos el primer arranque post-update
        // tarda lo que tarde esa copia. Corre una sola vez. `newColumns`
        // declara que `pago_id` NO existe en la tabla vieja: sin eso, la copia
        // intenta seleccionarla y revienta con "no such column".
        //
        // La guarda de existencia: toda base real tiene `adjuntos` desde v6,
        // pero recrear una tabla INEXISTENTE (fixtures de migraciones viejas,
        // o una base rota) tira la migración entera y deja el esquema a mitad
        // de camino. Si falta, se crea directamente con la forma nueva.
        final existeAdjuntos = (await customSelect(
          "SELECT 1 FROM sqlite_master "
          "WHERE type = 'table' AND name = 'adjuntos'",
        ).get()).isNotEmpty;
        if (existeAdjuntos) {
          await m.alterTable(
            TableMigration(adjuntos, newColumns: [adjuntos.pagoId]),
          );
        } else {
          await m.createTable(adjuntos);
        }
      }

      if (from < 22) {
        // #248: `contenido` pasa a NULLABLE — null = "no bajado a este
        // dispositivo". El pull deja de bajar los bytes de todas las fotos
        // (eran los minutos de espera y la pestaña congelada del reporte del
        // cliente); llegan bajo demanda al abrir el visor y quedan cacheados.
        // SIN SQL espejo a propósito: en Supabase `contenido_base64` no
        // cambia — solo cambia qué columnas pide el pull.
        //
        // Misma guarda de existencia y misma advertencia de v21: la
        // recreación copia los BLOBs existentes (que se CONSERVAN: son el
        // caché ya bajado) y corre una sola vez.
        final existeAdjuntosV22 = (await customSelect(
          "SELECT 1 FROM sqlite_master "
          "WHERE type = 'table' AND name = 'adjuntos'",
        ).get()).isNotEmpty;
        if (existeAdjuntosV22) {
          await m.alterTable(TableMigration(adjuntos));
        } else {
          await m.createTable(adjuntos);
        }
      }

      if (from < 23) {
        // #250: pull incremental con cursor. La única tabla local nueva es la
        // de cursores (estado local puro; el `updated_at` que #250 le suma a
        // `adjuntos` vive sólo en Supabase — el cursor lee ese campo del JSON
        // remoto, no necesita columna local). Guarda de existencia por el mismo
        // motivo que las tablas de arriba: crear una que ya está tira la
        // migración entera.
        final existeCursores = (await customSelect(
          "SELECT 1 FROM sqlite_master "
          "WHERE type = 'table' AND name = 'cursores_pull'",
        ).get()).isNotEmpty;
        if (!existeCursores) {
          await m.createTable(cursoresPull);
        }
      }

      if (from < 24) {
        // Rediseño insumos-por-categoría (Fase 1): catálogo de categorías como
        // entidad. Guarda de existencia por el mismo motivo que las tablas de
        // arriba: crear una que ya está tira la migración entera. Las tablas
        // `proveedor_categorias` y la columna `insumos.categoria_id` (Fase 2) y
        // el backfill (Fase 3) se suman a ESTE mismo bloque `from < 24`.
        final existeCategorias = (await customSelect(
          "SELECT 1 FROM sqlite_master "
          "WHERE type = 'table' AND name = 'categorias'",
        ).get()).isNotEmpty;
        if (!existeCategorias) {
          await m.createTable(categorias);
        }

        // Fase 2: tabla puente proveedor↔categoría + FK insumos.categoria_id.
        final existeProvCat = (await customSelect(
          "SELECT 1 FROM sqlite_master "
          "WHERE type = 'table' AND name = 'proveedor_categorias'",
        ).get()).isNotEmpty;
        if (!existeProvCat) {
          await m.createTable(proveedorCategorias);
        }

        // Columna nueva NULLABLE y SIN default: única forma segura del ALTER en
        // SQLite (un default no-constante rompe ALTER TABLE). Doble guarda:
        //  1) que la tabla `insumos` EXISTA — los tests de migración parcial
        //     (v15–v19) arman un esquema mínimo sin insumos y llegan igual a este
        //     step; un `ALTER TABLE insumos` ahí tira "no such table". Un
        //     createTable tolera FKs colgadas (el chequeo está off en migración),
        //     un addColumn NO tolera que falte la tabla.
        //  2) que la columna no exista ya — correr addColumn dos veces tira todo.
        final existeInsumos = (await customSelect(
          "SELECT 1 FROM sqlite_master "
          "WHERE type = 'table' AND name = 'insumos'",
        ).get()).isNotEmpty;
        final tieneCategoriaId = (await customSelect(
          "SELECT 1 FROM pragma_table_info('insumos') WHERE name = 'categoria_id'",
        ).get()).isNotEmpty;
        if (existeInsumos && !tieneCategoriaId) {
          await m.addColumn(insumos, insumos.categoriaId);
        }

        // Fase 3: backfill. Siembra el catálogo desde el texto libre existente,
        // reapunta insumos.categoria_id y arma proveedor_categorias. Idempotente
        // (ids deterministas) y con guardas de existencia propias para tolerar
        // los fixtures de esquema parcial (v15–v19). No encola nada: el servidor
        // deriva lo mismo por su backfill SQL espejo (ver el migrador).
        await MigradorCategoriasV24.backfill(this);
      }

      if (from < 25) {
        // #273: trazabilidad del pedido. Tres columnas nuevas, todas NULLABLE y
        // SIN default, que es la única forma segura del ALTER en SQLite (un
        // default no-constante rompe ALTER TABLE).
        //
        // Doble guarda por columna, igual que el paso v24: que la TABLA exista
        // —los fixtures de migración parcial (v15–v19) arman un esquema mínimo y
        // llegan igual a este step, y un `ALTER TABLE` sobre una tabla que falta
        // tira "no such table"— y que la columna no esté ya, porque correr
        // `addColumn` dos veces tira la migración entera.
        Future<void> sumarColumna(
          TableInfo<Table, dynamic> tabla,
          GeneratedColumn<Object> columna,
        ) async {
          final existeTabla = (await customSelect(
            "SELECT 1 FROM sqlite_master "
            "WHERE type = 'table' AND name = '${tabla.actualTableName}'",
          ).get()).isNotEmpty;
          if (!existeTabla) return;
          final existeColumna = (await customSelect(
            "SELECT 1 FROM pragma_table_info('${tabla.actualTableName}') "
            "WHERE name = '${columna.name}'",
          ).get()).isNotEmpty;
          if (!existeColumna) await m.addColumn(tabla, columna);
        }

        await sumarColumna(pedidos, pedidos.fechaEnvio);
        await sumarColumna(pedidos, pedidos.enviadoPor);
        await sumarColumna(pedidos, pedidos.enviadoPorNombre);
        await sumarColumna(registrosAuditoria, registrosAuditoria.ocurridoEn);

        // NO se hace backfill de `fecha_envio` con `fecha_creacion`. Serían dos
        // hechos distintos con la misma fecha, y la trazabilidad diría que el
        // pedido se envió en el mismo instante en que se creó, que casi nunca es
        // verdad. Un dato inventado es peor que un dato ausente: el bloque
        // muestra "sin registrar" para los pedidos anteriores a esta versión,
        // que es la verdad.
      }

      // SIEMPRE al final, para cualquier `from` (#190). Son todos
      // `IF NOT EXISTS`, así que es idempotente y además AUTOREPARA: los
      // dispositivos que hoy están sin índices —los que instalaron fresco
      // en v3 o después, que nunca pasaron por `_migrarV2aV3`— los
      // recuperan en la próxima actualización, sin migración nueva ni bump
      // de `schemaVersion`.
      //
      // Esa reparación corre en el arranque, bloqueando la primera consulta,
      // y le toca justo a las bases más grandes. Medido antes de mergear:
      // **77 ms** para los 22 índices sobre 5.000 pedidos + 20.000 registros
      // de historial de precios. No hay freeze de arranque que justifique
      // diferirlo a un isolate.
      await _crearIndices();
    },
    beforeOpen: (details) async {
      // Habilita la verificación de claves foráneas en SQLite.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Migración incremental v2 → v3: agrega columnas de sincronización,
  /// reubica el IVA y crea las nuevas entidades (recepciones, facturación, etc.)
  /// SIN borrar los datos locales existentes.
  Future<void> _migrarV2aV3(Migrator m) async {
    // 1. Columnas de sincronización en tablas mutables ya existentes.
    //    Se agregan con default, por lo que ALTER ADD COLUMN es válido en SQLite.
    // Negocios
    await m.addColumn(negocios, negocios.fechaActualizacion);
    await m.addColumn(negocios, negocios.estadoSync);
    await m.addColumn(negocios, negocios.version);
    // Usuarios (pin/password ahora son hash; columnas nuevas)
    // HU-112: pin_hash se eliminó del esquema (drop en v8→v9). En el path histórico
    // v2→v3 ya no se crea; los dispositivos que la tengan la pierden al llegar a v9.
    await m.addColumn(usuarios, usuarios.passwordHash);
    await m.addColumn(usuarios, usuarios.fechaActualizacion);
    await m.addColumn(usuarios, usuarios.estadoSync);
    await m.addColumn(usuarios, usuarios.version);
    // Proveedores
    await m.addColumn(proveedores, proveedores.cuit);
    await m.addColumn(proveedores, proveedores.fechaActualizacion);
    await m.addColumn(proveedores, proveedores.estadoSync);
    await m.addColumn(proveedores, proveedores.version);
    // Insumos (se elimina iva; se agregan columnas sync)
    await m.addColumn(insumos, insumos.fechaActualizacion);
    await m.addColumn(insumos, insumos.estadoSync);
    await m.addColumn(insumos, insumos.version);
    try {
      await customStatement('ALTER TABLE insumos DROP COLUMN iva');
    } catch (_) {
      /* columna inexistente o SQLite antiguo: se ignora */
    }
    // HistorialPrecios (append-only) — IVA, usuario, created_at, sync
    await m.addColumn(historialPrecios, historialPrecios.usuarioId);
    await m.addColumn(historialPrecios, historialPrecios.ivaPorcentaje);
    await m.addColumn(historialPrecios, historialPrecios.fechaCreacion);
    await m.addColumn(historialPrecios, historialPrecios.estadoSync);
    // AlertasDesviacion
    await m.addColumn(alertasDesviacion, alertasDesviacion.fechaActualizacion);
    await m.addColumn(alertasDesviacion, alertasDesviacion.estadoSync);
    await m.addColumn(alertasDesviacion, alertasDesviacion.version);
    // Pedidos — usuario UUID + nombres denormalizados + sync
    await m.addColumn(pedidos, pedidos.creadoPorNombre);
    await m.addColumn(pedidos, pedidos.recepcionadoPorNombre);
    await m.addColumn(pedidos, pedidos.estadoSync);
    await m.addColumn(pedidos, pedidos.version);
    // Recetas
    await m.addColumn(recetas, recetas.fechaActualizacion);
    await m.addColumn(recetas, recetas.estadoSync);
    await m.addColumn(recetas, recetas.version);
    // RecetaIngredientes
    await m.addColumn(recetaIngredientes, recetaIngredientes.unidadCantidad);
    await m.addColumn(recetaIngredientes, recetaIngredientes.fechaCreacion);
    await m.addColumn(
      recetaIngredientes,
      recetaIngredientes.fechaActualizacion,
    );
    await m.addColumn(recetaIngredientes, recetaIngredientes.estadoSync);
    // ColaSincronizacion
    await m.addColumn(colaSincronizacion, colaSincronizacion.maxIntentos);
    await m.addColumn(colaSincronizacion, colaSincronizacion.ultimoError);
    await m.addColumn(
      colaSincronizacion,
      colaSincronizacion.fechaActualizacion,
    );

    // 2. Nuevas tablas (entidades faltantes).
    await m.createTable(recepciones);
    await m.createTable(facturas);
    await m.createTable(pagos);
    await m.createTable(imputacionesPago);
    await m.createTable(anticipos);
    await m.createTable(movimientosCuentaCorriente);
    await m.createTable(registrosAuditoria);
    await m.createTable(configuracionNegocio);

    // 3. Índices únicos para tablas preexistentes (paridad con Supabase).
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_usuarios_negocio_email ON usuarios(negocio_id, email)',
    );
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_receta_ingredientes ON receta_ingredientes(receta_id, insumo_id)',
    );

    // Los índices de rendimiento ya NO se crean acá: los emite el final de
    // `onUpgrade` para cualquier `from` (#190).
  }

  /// Migración incremental v3 → v4 (HU-045): agrega `negocio_id` + FK a `negocios`
  /// en las 4 tablas que aislaban de forma transitiva (historial_precios,
  /// alertas_desviacion, imputaciones_pago, receta_ingredientes).
  ///
  /// Como SQLite no permite `ALTER TABLE ADD COLUMN` NOT NULL sin default y la base
  /// aún no tiene datos productivos (inicio de proyecto), se RECREAN estas 4 tablas
  /// para incorporar la columna NOT NULL de forma limpia. No tienen tablas hijas, por
  /// lo que el drop es seguro. La unicidad de receta_ingredientes (receta_id, insumo_id)
  /// se restituye sola al recrear desde la definición Drift.
  Future<void> _migrarV3aV4(Migrator m) async {
    await m.deleteTable(historialPrecios.actualTableName);
    await m.createTable(historialPrecios);
    await m.deleteTable(alertasDesviacion.actualTableName);
    await m.createTable(alertasDesviacion);
    await m.deleteTable(imputacionesPago.actualTableName);
    await m.createTable(imputacionesPago);
    await m.deleteTable(recetaIngredientes.actualTableName);
    await m.createTable(recetaIngredientes);
  }

  /// Migración incremental v4 → v5 (HU-065): crea la tabla de catálogo de motivos
  /// de recepción. Solo agrega una tabla nueva: NO toca ni borra datos existentes.
  /// La unicidad {negocio_id, nombre} viaja en la definición de la tabla.
  Future<void> _migrarV4aV5(Migrator m) async {
    await m.createTable(motivosRecepcion);
  }

  /// Migración incremental v5 → v6 (HU-066): crea la tabla de adjuntos (remitos) y
  /// sus índices. Solo agrega una tabla nueva: NO toca ni borra datos existentes.
  Future<void> _migrarV5aV6(Migrator m) async {
    await m.createTable(adjuntos);
    // Sus índices viven en `_crearIndices` (#190): declararlos acá los dejaba
    // fuera del camino de instalación nueva.
  }

  /// Migración incremental v6 → v7 (HU-067): agrega `recepcion_id` a `facturas` para
  /// facturar contra el remito de una recepción (no contra el pedido). La columna es
  /// nullable con default implícito NULL: `ALTER TABLE ADD COLUMN` es válido en SQLite
  /// y NO toca las facturas existentes (que quedan con recepcion_id = NULL).
  Future<void> _migrarV6aV7(Migrator m) async {
    await m.addColumn(facturas, facturas.recepcionId);
    // Su índice vive en `_crearIndices` (#190).
  }

  /// Migración incremental v7 → v8 (HU-069): agrega `tipo` a `adjuntos` (remito vs
  /// comprobante de pago) y `comentario` a `facturas`. Ambas columnas con default/NULL,
  /// así que `ALTER TABLE ADD COLUMN` es válido y NO toca los datos existentes: los
  /// adjuntos previos quedan como 'remito'.
  Future<void> _migrarV7aV8(Migrator m) async {
    await m.addColumn(adjuntos, adjuntos.tipo);
    await m.addColumn(facturas, facturas.comentario);
  }

  /// v9 → v10 (HU-121): unicidad `(pedido_id, numero_recepcion)` en recepciones,
  /// espejo del UNIQUE server-side. Antes del índice se SANEAN los duplicados
  /// locales (solo pedidos que los tengan: se renumeran densamente preservando
  /// el orden número→fecha→id, igual que la migración de Supabase). Se usa un
  /// UNIQUE INDEX (equivalente al constraint de tabla que reciben las
  /// instalaciones nuevas vía `uniqueKeys`).
  Future<void> _migrarV9aV10(Migrator m) async {
    await customStatement('''
      UPDATE recepciones SET numero_recepcion = (
        SELECT nuevo FROM (
          SELECT id,
                 ROW_NUMBER() OVER (PARTITION BY pedido_id
                                    ORDER BY numero_recepcion, fecha_recepcion, id) AS nuevo
            FROM recepciones
           WHERE pedido_id IN (
             SELECT pedido_id FROM recepciones
              GROUP BY pedido_id, numero_recepcion
             HAVING COUNT(*) > 1
           )
        ) ren WHERE ren.id = recepciones.id
      )
      WHERE id IN (
        SELECT id FROM recepciones
         WHERE pedido_id IN (
           SELECT pedido_id FROM recepciones
            GROUP BY pedido_id, numero_recepcion
           HAVING COUNT(*) > 1
         )
      )
    ''');
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS ix_recepciones_pedido_numero '
      'ON recepciones(pedido_id, numero_recepcion)',
    );
  }

  /// v12 → v13 (HU-143): total recibido manual + autoría + token de concurrencia
  /// en recepciones. NO destructiva: todas las columnas son nullable o tienen
  /// default constante, y las filas existentes quedan intactas (total NULL =
  /// sigue valiendo el derivado de las líneas; version 0 = base del contador LWW).
  ///
  /// OJO: `fechaActualizacion` NO puede ir por `m.addColumn` — su default
  /// declarado es `currentDateAndTime` (expresión) y SQLite prohíbe defaults no
  /// constantes en ALTER TABLE ADD COLUMN (SqliteException 1: "Cannot add a
  /// column with non-constant default"). Se agrega con SQL crudo y default
  /// constante, y se backfillea con la fecha de creación del evento.
  Future<void> _migrarV12aV13(Migrator m) async {
    await m.addColumn(recepciones, recepciones.totalRecibido);
    await m.addColumn(recepciones, recepciones.totalEditadoPor);
    await m.addColumn(recepciones, recepciones.totalEditadoPorNombre);
    await m.addColumn(recepciones, recepciones.fechaTotalEditado);
    await customStatement(
      'ALTER TABLE recepciones ADD COLUMN fecha_actualizacion INTEGER NOT NULL DEFAULT 0',
    );
    await customStatement(
      'UPDATE recepciones SET fecha_actualizacion = fecha_creacion',
    );
    await m.addColumn(recepciones, recepciones.version);
  }

  /// Índices de rendimiento para listados, búsquedas y FoodCost histórico.
  Future<void> _crearIndices() async {
    const indices = <String>[
      'CREATE INDEX IF NOT EXISTS ix_usuarios_negocio ON usuarios(negocio_id)',
      'CREATE INDEX IF NOT EXISTS ix_proveedores_negocio ON proveedores(negocio_id)',
      'CREATE INDEX IF NOT EXISTS ix_insumos_negocio_activo ON insumos(negocio_id, activo)',
      'CREATE INDEX IF NOT EXISTS ix_insumos_proveedor ON insumos(proveedor_id)',
      'CREATE INDEX IF NOT EXISTS ix_historial_insumo_fecha ON historial_precios(insumo_id, fecha_registro DESC)',
      'CREATE INDEX IF NOT EXISTS ix_historial_negocio ON historial_precios(negocio_id)',
      'CREATE INDEX IF NOT EXISTS ix_alertas_resuelta ON alertas_desviacion(resuelta, insumo_id)',
      'CREATE INDEX IF NOT EXISTS ix_alertas_negocio ON alertas_desviacion(negocio_id)',
      'CREATE INDEX IF NOT EXISTS ix_imputaciones_negocio ON imputaciones_pago(negocio_id)',
      'CREATE INDEX IF NOT EXISTS ix_receta_ing_negocio ON receta_ingredientes(negocio_id)',
      'CREATE INDEX IF NOT EXISTS ix_pedidos_negocio_estado_fecha ON pedidos(negocio_id, estado, fecha_actualizacion DESC)',
      'CREATE INDEX IF NOT EXISTS ix_recepciones_pedido ON recepciones(pedido_id, numero_recepcion)',
      'CREATE INDEX IF NOT EXISTS ix_facturas_negocio_estado ON facturas(negocio_id, estado, fecha_vencimiento)',
      'CREATE INDEX IF NOT EXISTS ix_pagos_proveedor ON pagos(negocio_id, proveedor_id)',
      'CREATE INDEX IF NOT EXISTS ix_cta_corriente_proveedor_fecha ON movimientos_cuenta_corriente(proveedor_id, fecha_movimiento DESC)',
      'CREATE INDEX IF NOT EXISTS ix_recetas_negocio ON recetas(negocio_id)',
      'CREATE INDEX IF NOT EXISTS ix_receta_ing_receta ON receta_ingredientes(receta_id)',
      'CREATE INDEX IF NOT EXISTS ix_cola_fecha ON cola_sincronizacion(fecha_creacion ASC)',
      'CREATE INDEX IF NOT EXISTS ix_auditoria_negocio_fecha ON registros_auditoria(negocio_id, fecha_creacion DESC)',
      // Venían declarados dentro de _migrarV5aV6 y _migrarV6aV7 (#190): ahí
      // quedaban fuera del camino de instalación nueva.
      'CREATE INDEX IF NOT EXISTS ix_adjuntos_recepcion ON adjuntos(recepcion_id)',
      'CREATE INDEX IF NOT EXISTS ix_adjuntos_negocio ON adjuntos(negocio_id)',
      'CREATE INDEX IF NOT EXISTS ix_facturas_recepcion ON facturas(recepcion_id)',
    ];

    // Se emite sólo lo que apunta a una tabla que EXISTE.
    //
    // En producción no descarta nada: al final de `onUpgrade` los pasos ya
    // corrieron en orden y el esquema está completo. Lo que gana es que
    // `_crearIndices` sea segura de llamar en CUALQUIER punto — y eso es
    // justamente lo que la habilita a ser la única forma canónica de declarar
    // un índice. Sin el filtro, la función explota con "no such table" según
    // desde dónde se la invoque, que es la fragilidad que dejó a estos índices
    // repartidos en cinco lugares distintos para empezar (#190).
    final existentes = (await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    ).get()).map((f) => f.read<String>('name')).toSet();

    // Nombres de tabla que el esquema Drift declara, para distinguir "todavía no
    // existe en ESTA base" de "está mal escrita". El primer caso es legítimo (una
    // fixture parcial, un paso intermedio); el segundo es un bug.
    final conocidas = {for (final t in allTables) t.actualTableName};

    for (final sql in indices) {
      final tabla = RegExp(r'\sON\s+(\w+)\s*\(').firstMatch(sql)?.group(1);

      // Un `assert` y no un `continue` silencioso: saltear en silencio un índice
      // cuya tabla no existe en el esquema —por un typo o por un rename— lo
      // borraría de TODOS los dispositivos para siempre, sin excepción, sin log
      // y sin test en rojo. Que es exactamente la forma de fallar de #190, la
      // que este cambio vino a cerrar. En release el assert se compila afuera y
      // el filtro de abajo evita el crash.
      assert(
        tabla != null && conocidas.contains(tabla),
        'Índice sobre una tabla que el esquema no declara: $sql',
      );

      if (tabla == null || !existentes.contains(tabla)) continue;
      await customStatement(sql);
    }
  }

  // ─── MÉTODOS DE NEGOCIO Y CONSULTAS PERSONALIZADAS ─────────────────────────

  /// Calcula el costo total de una receta y el costo por porción en una fecha específica,
  /// buscando los precios históricos de los ingredientes vigentes a ese día.
  Future<ResultadoCostoReceta> obtenerCostoRecetaAFecha(
    String recetaId,
    DateTime fecha,
  ) async {
    final receta = await (select(
      recetas,
    )..where((r) => r.id.equals(recetaId))).getSingle();
    final ingredientes = await (select(
      recetaIngredientes,
    )..where((ri) => ri.recetaId.equals(recetaId))).get();

    double costoNetoTotal = 0.0;
    var insumosSinPrecio = 0;

    for (final ing in ingredientes) {
      final consultaPrecio = select(historialPrecios)
        ..where(
          (hp) =>
              hp.insumoId.equals(ing.insumoId) &
              hp.fechaRegistro.isSmallerOrEqualValue(fecha),
        )
        ..orderBy([
          (hp) => OrderingTerm(
            expression: hp.fechaRegistro,
            mode: OrderingMode.desc,
          ),
        ])
        ..limit(1);

      final ultimoPrecio = await consultaPrecio.getSingleOrNull();

      final insumoObj = await (select(
        insumos,
      )..where((i) => i.id.equals(ing.insumoId))).getSingleOrNull();
      double precioAUsar;
      if (ultimoPrecio != null) {
        precioAUsar = ultimoPrecio.precioUnitarioNeto;
      } else {
        precioAUsar = insumoObj?.costoPorUnidad ?? 0.0;
      }

      if (precioAUsar > 0) {
        // Normaliza la cantidad a la unidad base del insumo antes de multiplicar (R-001 / HU-020).
        final cantidadBase = ConversorUnidades.normalizar(
          cantidad: ing.cantidadNeta,
          unidadOrigen: ing.unidadCantidad,
          unidadBaseInsumo: insumoObj?.unidad,
        );
        final mermaEfectiva = ing.desperdicioPorcentaje.clamp(0.0, 0.99);
        final costoIngrediente =
            (cantidadBase / (1.0 - mermaEfectiva)) * precioAUsar;
        costoNetoTotal += costoIngrediente;
      } else {
        // #239: este guard salteaba al ingrediente EN SILENCIO y la receta
        // parecía completa costando de menos — el patrón "sub-reporta con
        // CERO". Se cuenta para que el costeo pueda decirse incompleto, sobre
        // todo ahora que un insumo nace SIN precio hasta su primera recepción.
        insumosSinPrecio += 1;
      }
    }

    final porcionesSeguras = receta.porciones <= 0 ? 1.0 : receta.porciones;
    final costoPorPorcion = costoNetoTotal / porcionesSeguras;

    return ResultadoCostoReceta(
      costoTotal: costoNetoTotal,
      costoPorPorcion: costoPorPorcion,
      porciones: receta.porciones,
      insumosSinPrecio: insumosSinPrecio,
    );
  }

  /// Devuelve el precio neto estimado para un ítem de pedido (HU-010): el último
  /// precio que [proveedorId] cobró por [insumoId] según el historial. Es base para
  /// foodcost y métricas, por eso se prioriza el precio puntual de ESE proveedor.
  /// Fallbacks en cascada: (1) último precio de ese proveedor con ese insumo →
  /// (2) último precio del insumo con cualquier proveedor → (3) caché del insumo →
  /// (4) 0.0 ("a confirmar con la factura").
  Future<double> obtenerPrecioEstimadoItem({
    required String insumoId,
    String? proveedorId,
  }) async {
    if (proveedorId != null) {
      final porProveedor =
          await (select(historialPrecios)
                ..where(
                  (hp) =>
                      hp.insumoId.equals(insumoId) &
                      hp.proveedorId.equals(proveedorId),
                )
                ..orderBy([
                  (hp) => OrderingTerm(
                    expression: hp.fechaRegistro,
                    mode: OrderingMode.desc,
                  ),
                ])
                ..limit(1))
              .getSingleOrNull();
      if (porProveedor != null) return porProveedor.precioUnitarioNeto;
    }

    final cualquierProveedor =
        await (select(historialPrecios)
              ..where((hp) => hp.insumoId.equals(insumoId))
              ..orderBy([
                (hp) => OrderingTerm(
                  expression: hp.fechaRegistro,
                  mode: OrderingMode.desc,
                ),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (cualquierProveedor != null) {
      return cualquierProveedor.precioUnitarioNeto;
    }

    final insumo = await (select(
      insumos,
    )..where((i) => i.id.equals(insumoId))).getSingleOrNull();
    return insumo?.costoPorUnidad ?? 0.0;
  }

  /// Registra un nuevo precio en el Historial (inmutable), actualiza la caché del insumo
  /// y genera una alerta de desviación si la variación (en cualquier sentido) iguala o
  /// supera el [umbralAlerta]. El umbral es configurable por negocio (HU-018 / HU-031).
  ///
  /// NOTA de sincronización: en Supabase, el trigger `verificar_desviacion_precio`
  /// reproduce el alta de alerta y la caché. Por eso la cola de sincronización debe
  /// encolar ÚNICAMENTE el INSERT de historial_precios (fuente de verdad) y NO los
  /// efectos derivados (alertas_desviacion / costo_por_unidad), evitando duplicación.
  Future<String> registrarPrecioInsumo({
    required String insumoId,
    required double nuevoPrecio,
    required String origen,
    required String? proveedorId,
    required String? referenciaId,
    String? usuarioId,
    double ivaPorcentaje = 0.21,
    double umbralAlerta = 0.10,
  }) async {
    final consultaPrecioAnterior = select(historialPrecios)
      ..where((hp) => hp.insumoId.equals(insumoId))
      ..orderBy([
        (hp) =>
            OrderingTerm(expression: hp.fechaRegistro, mode: OrderingMode.desc),
      ])
      ..limit(1);

    final precioAnteriorObj = await consultaPrecioAnterior.getSingleOrNull();

    // El historial y la alerta heredan el negocio del insumo (HU-045): el tenant del
    // hijo SIEMPRE se deriva del padre, nunca se recibe suelto desde afuera.
    final insumoRef = await (select(
      insumos,
    )..where((i) => i.id.equals(insumoId))).getSingleOrNull();
    if (insumoRef == null) {
      throw StateError(
        'No se puede registrar precio: el insumo $insumoId no existe.',
      );
    }
    final negocioIdInsumo = insumoRef.negocioId;

    final nuevoId = const Uuid().v4();
    final fechaRegistro = DateTime.now();
    await into(historialPrecios).insert(
      HistorialPreciosCompanion.insert(
        id: nuevoId,
        negocioId: negocioIdInsumo,
        insumoId: insumoId,
        proveedorId: Value(proveedorId),
        usuarioId: Value(usuarioId),
        precioUnitarioNeto: nuevoPrecio,
        ivaPorcentaje: Value(ivaPorcentaje),
        origen: origen,
        referenciaId: Value(referenciaId),
        fechaRegistro: Value(fechaRegistro),
      ),
    );

    // Caché de lectura rápida del precio actual (el que alimenta el FoodCost
    // cuando no hay historial a la fecha pedida).
    //
    // HU-138: el caché se mueve solo si esta carga es la MÁS NUEVA del insumo, no
    // por ser la última en llegar. Antes se escribía a ciegas: con push offline
    // desordenado —y ahora con varios proveedores cargando precios del mismo
    // insumo— una carga vieja que aterriza tarde hacía RETROCEDER el costo a un
    // precio que ya no regía. La comparación es estricta, así que un empate de
    // fecha conserva el comportamiento de siempre (gana el que escribe).
    final hayCargaMasNueva =
        await (select(historialPrecios)
              ..where(
                (hp) =>
                    hp.insumoId.equals(insumoId) &
                    hp.fechaRegistro.isBiggerThanValue(fechaRegistro),
              )
              ..limit(1))
            .getSingleOrNull();

    if (hayCargaMasNueva == null) {
      await (update(insumos)..where((i) => i.id.equals(insumoId))).write(
        InsumosCompanion(
          costoPorUnidad: Value(nuevoPrecio),
          fechaActualizacion: Value(DateTime.now()),
        ),
      );
    }

    // Alerta de desviación en AMBOS sentidos (subida o bajada) — HU-018.
    if (precioAnteriorObj != null && precioAnteriorObj.precioUnitarioNeto > 0) {
      final precioViejo = precioAnteriorObj.precioUnitarioNeto;
      final desviacion = (nuevoPrecio - precioViejo) / precioViejo;

      if (desviacion.abs() >= umbralAlerta) {
        await into(alertasDesviacion).insert(
          AlertasDesviacionCompanion.insert(
            id: const Uuid().v4(),
            negocioId: negocioIdInsumo,
            insumoId: insumoId,
            precioAnteriorNeto: precioViejo,
            precioNuevoNeto: nuevoPrecio,
            porcentajeDesviacion: desviacion,
            resuelta: const Value(false),
            fechaCreacion: Value(DateTime.now()),
          ),
        );
      }
    }

    return nuevoId;
  }
}

/// Estructura de retorno para el cálculo financiero de costos de recetas.
class ResultadoCostoReceta {
  final double costoTotal;
  final double costoPorPorcion;
  final double porciones;

  /// #239: ingredientes que quedaron FUERA del total por no tener precio
  /// todavía (ni historial ni caché). Si es > 0, [costoTotal] cuesta de menos.
  final int insumosSinPrecio;

  ResultadoCostoReceta({
    required this.costoTotal,
    required this.costoPorPorcion,
    required this.porciones,
    this.insumosSinPrecio = 0,
  });
}

/// Conversor de unidades para normalizar cantidades a la unidad BASE del insumo (R-001 / HU-020).
/// Evita errores de orden de magnitud (ej.: 150 g de un insumo cuya unidad base es kg).
class ConversorUnidades {
  // Factor para convertir 1 [unidad] → unidad base de su familia.
  static const Map<String, _Familia> _familias = {
    'kg': _Familia('kg', 1.0),
    'g': _Familia('kg', 0.001),
    'gr': _Familia('kg', 0.001),
    'lt': _Familia('lt', 1.0),
    'l': _Familia('lt', 1.0),
    'ml': _Familia('lt', 0.001),
    'cc': _Familia('lt', 0.001),
  };

  /// Convierte [cantidad] expresada en [unidadOrigen] a la [unidadBaseInsumo].
  /// Si no hay información suficiente o las unidades no son convertibles entre sí,
  /// devuelve la cantidad sin transformar (comportamiento previo, retrocompatible).
  static double normalizar({
    required double cantidad,
    String? unidadOrigen,
    String? unidadBaseInsumo,
  }) {
    if (unidadOrigen == null || unidadBaseInsumo == null) return cantidad;
    final origen = _familias[unidadOrigen.trim().toLowerCase()];
    final base = _familias[unidadBaseInsumo.trim().toLowerCase()];
    if (origen == null || base == null) return cantidad;
    if (origen.base != base.base) {
      return cantidad; // familias distintas: no se convierte
    }
    // cantidad en unidad base de la familia, luego a la unidad base del insumo
    final enBaseFamilia = cantidad * origen.factor;
    return enBaseFamilia / base.factor;
  }
}

class _Familia {
  final String base;
  final double factor;
  const _Familia(this.base, this.factor);
}
