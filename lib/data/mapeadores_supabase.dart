import 'dart:convert';
import '../database/database.dart';
import '../utils/dinero.dart';
import '../utils/fecha_recepcion.dart';

/// Convierte las filas locales (Drift) a mapas snake_case con las columnas que
/// existen en Supabase. Es el único lugar donde se define ese mapeo, de modo que
/// los controladores no repitan la conversión al encolar mutaciones (Outbox).
///
/// IMPORTANTE: NO se incluyen columnas inexistentes en Supabase (estado_sync,
/// password_hash, pin_hash, iva) ni `updated_at` (lo gestiona un trigger BEFORE
/// UPDATE). `created_at` en general lo asigna el DEFAULT now() del servidor,
/// EXCEPTO en `pedidos`: ahí SÍ se envía porque es la fecha de negocio que ve el
/// usuario ("Creado: ...") y debe ser la de creación real, no la del flush del
/// Outbox (HU-122). Los campos JSON (items/alertas) se envían decodificados
/// porque en Supabase son JSONB.
class MapeadoresSupabase {
  static dynamic _json(String? texto) {
    if (texto == null || texto.isEmpty) return null;
    try {
      return jsonDecode(texto);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> negocio(Negocio n) => {
    'id': n.id,
    'nombre': n.nombre,
    'tipo': n.tipo,
    'pais': n.pais,
    'email': n.email,
    'version': n.version,
  };

  static Map<String, dynamic> usuario(Usuario u) => {
    'id': u.id,
    'negocio_id': u.negocioId,
    'nombre': u.nombre,
    'rol': u.rol,
    'email': u.email,
    'activo': u.activo,
    'version': u.version,
  };

  static Map<String, dynamic> proveedor(Proveedore p) => {
    'id': p.id,
    'negocio_id': p.negocioId,
    'nombre': p.nombre,
    'categoria': p.categoria,
    'contacto': p.contacto,
    'email': p.email,
    'telefono': p.telefono,
    'cuit': p.cuit,
    'plazo_pago': p.plazoPago,
    // #220: los datos para transferirle. Las columnas se crean en
    // `20260825120000_datos_bancarios_proveedor.sql`, que va SIEMPRE antes que
    // este código: como acá se manda un mapa de claves EXPLÍCITO, un cliente
    // que las mande contra un servidor que no las tiene manda a dead-letter
    // TODO insert y update de proveedores, no sólo estos dos campos.
    'alias_bancario': p.aliasBancario,
    'cbu': p.cbu,
    'activo': p.activo,
    'version': p.version,
  };

  static Map<String, dynamic> insumo(Insumo i) => {
    'id': i.id,
    'negocio_id': i.negocioId,
    'nombre': i.nombre,
    'categoria': i.categoria,
    // #262: la categoría-entidad. Convive con el texto `categoria` durante la
    // transición (Fase 5 deprecará el texto). `proveedor_id` sigue por back-compat.
    'categoria_id': i.categoriaId,
    'unidad': i.unidad,
    'costo_por_unidad': Dinero.redondear(i.costoPorUnidad),
    'proveedor_id': i.proveedorId,
    'tipo': i.tipo,
    'activo': i.activo,
    'version': i.version,
  };

  static Map<String, dynamic> receta(Receta r) => {
    'id': r.id,
    'negocio_id': r.negocioId,
    'nombre': r.nombre,
    'porciones': r.porciones,
    'precio_venta_carta': r.precioVentaCarta == null
        ? null
        : Dinero.redondear(r.precioVentaCarta!),
    'margen_deseado_porcentaje': r.margenDeseadoPorcentaje,
    // HU-152: minutos de la TANDA entera, no de una porción. Puede ser null
    // ("no declara tiempo"), que es distinto de cero.
    'tiempo_elaboracion_minutos': r.tiempoElaboracionMinutos,
    'categoria': r.categoria,
    'imagen_url': r.imagenUrl,
    'archivada': r.archivada,
    'version': r.version,
  };

  static Map<String, dynamic> recetaIngrediente(RecetaIngrediente ri) => {
    'id': ri.id,
    'negocio_id': ri.negocioId,
    'receta_id': ri.recetaId,
    'insumo_id': ri.insumoId,
    'cantidad_neta': ri.cantidadNeta,
    'unidad_cantidad': ri.unidadCantidad,
    'desperdicio_porcentaje': ri.desperdicioPorcentaje,
  };

  /// Vínculo insumo↔proveedor (HU-138). `precio` viaja como número: en Supabase
  /// la columna es `numeric(14,2)` (HU-081), nunca punto flotante.
  static Map<String, dynamic> insumoProveedor(InsumoProveedore ip) => {
    'id': ip.id,
    'negocio_id': ip.negocioId,
    'insumo_id': ip.insumoId,
    'proveedor_id': ip.proveedorId,
    'precio': ip.precio == null ? null : Dinero.redondear(ip.precio!),
    'activo': ip.activo,
    'version': ip.version,
  };

  /// Vínculo proveedor↔categoría (#262). Sin precio (se abandonó el precio de
  /// lista por vínculo); baja lógica por `activo`.
  static Map<String, dynamic> proveedorCategoria(ProveedorCategoria pc) => {
    'id': pc.id,
    'negocio_id': pc.negocioId,
    'proveedor_id': pc.proveedorId,
    'categoria_id': pc.categoriaId,
    'activo': pc.activo,
    'version': pc.version,
  };

  /// Agenda de un pedido recurrente (HU-013). `fecha_inicio` y
  /// `fecha_ultima_ocurrencia_emitida` son columnas `date` en Supabase: viajan
  /// como `aaaa-mm-dd` y NUNCA con `toIso8601String()`, que arrastraría hora y
  /// zona y correría el día en otro huso. `items` va decodificado porque del
  /// otro lado es `jsonb`, igual que en [pedido].
  static Map<String, dynamic> pedidoRecurrente(PedidosRecurrente a) => {
    'id': a.id,
    'negocio_id': a.negocioId,
    'proveedor_id': a.proveedorId,
    'tipo': a.tipo,
    'dias_semana': a.diasSemana,
    'dia_mes': a.diaMes,
    'cada_n_dias': a.cadaNDias,
    'ancla': a.ancla,
    'fecha_inicio': FechaRecepcion.aIso(a.fechaInicio),
    'fecha_ultima_ocurrencia_emitida': FechaRecepcion.aIso(
      a.fechaUltimaOcurrenciaEmitida,
    ),
    'items': _json(a.items),
    'tiene_efectivo': a.tieneEfectivo,
    'nota': a.nota,
    'activo': a.activo,
    'version': a.version,
  };

  static Map<String, dynamic> pedido(Pedido p) => {
    'id': p.id,
    'negocio_id': p.negocioId,
    'proveedor_nombre': p.proveedorNombre,
    'proveedor_id': p.proveedorId,
    'estado': p.estado,
    'nota': p.nota,
    'creado_por': p.creadoPor,
    'creado_por_nombre': p.creadoPorNombre,
    'recepcionado_por': p.recepcionadoPor,
    'recepcionado_por_nombre': p.recepcionadoPorNombre,
    'items': _json(p.items),
    'total': p.total == null ? null : Dinero.redondear(p.total!),
    'tiene_efectivo': p.tieneEfectivo,
    'alertas': _json(p.alertas),
    'version': p.version,
    // HU-142: día pedido de recepción. Viaja como `aaaa-mm-dd` (la columna
    // es `date`): con toIso8601String() iría con hora y zona, y el mismo día
    // podría leerse corrido en otro huso.
    'fecha_recepcion_solicitada': FechaRecepcion.aIso(
      p.fechaRecepcionSolicitada,
    ),
    // HU-013: procedencia. Viaja SIEMPRE, también en null, para que quitarle
    // la marca a un pedido sea posible.
    'agenda_id': p.agendaId,
    // HU-122: la fecha real de creación (offline incluida) viaja al servidor;
    // sin esto Postgres usaría DEFAULT now() = momento del flush del Outbox.
    'created_at': p.fechaCreacion.toUtc().toIso8601String(),
    // #273: quién y cuándo se envió al proveedor. Viajan SIEMPRE, también en
    // null: son null de verdad hasta que el pedido se envía, y omitirlos haría
    // que el servidor conservara un valor viejo si alguna vez se corrigieran.
    'fecha_envio': p.fechaEnvio?.toUtc().toIso8601String(),
    'enviado_por': p.enviadoPor,
    'enviado_por_nombre': p.enviadoPorNombre,
  };
}
