import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../database/database.dart';
import '../data/liberacion_pendientes.dart';
import '../data/repositorios/repositorio_cursores_pull.dart';
import '../utils/calculadora_costos.dart';
import '../utils/dinero.dart';
import '../utils/fecha_recepcion.dart';
import '../utils/paginacion_postgrest.dart';
import '../utils/politica_conflictos.dart';
import '../utils/adjuntos/codificador_adjuntos.dart';
import '../utils/adjuntos/tipo_adjunto.dart';
import 'servicio_configuracion_negocio.dart';
import 'guarda_primer_pull.dart';
import 'servicio_conflictos.dart';
import 'servicio_permisos.dart';

/// Servicio de DESCARGA (pull) de los datos de un negocio desde Supabase hacia la
/// base local (Drift). Responsabilidad única y reutilizable: lo consumen tanto el
/// flujo del SuperAdmin (al entrar a un negocio) como el de un usuario normal
/// (al iniciar sesión o al recargar una pantalla), para ver los datos cargados
/// por otros dispositivos del mismo negocio.
///
/// La RLS de Supabase ya autoriza a cada usuario a leer SOLO su propio negocio
/// (policies `see_*` filtradas por `get_current_negocio_id()`), por lo que este
/// servicio no requiere permisos especiales: es la contraparte de lectura del
/// push offline-first (Outbox) del [ServicioSincronizacionSupabase].
/// Las columnas de `configuracion_negocio` que baja un dispositivo OPERATIVO
/// (#207).
///
/// Se piden por NOMBRE en vez de `select()` por una razón concreta:
/// `costo_hora_empleado` NO está en la lista. Es un dato salarial, el cocinero
/// no lo necesita —no ve costos de receta, están detrás de `verFinanzas`— y
/// pedirlo por nombre hace que ni siquiera viaje por la red. Es la misma idea
/// que las vistas `_operativo` de HU-045, sin necesitar una migración.
///
/// Vive como constante pública para poder afirmarlo en un test: esta lista ES
/// la decisión de qué ve cada rol, y eso merece quedar fijado.
const String columnasConfiguracionOperativa =
    'id,negocio_id,umbral_alerta_desviacion,moneda,simbolo_moneda,'
    'pais,idioma,foodcost_verde_max,foodcost_amarillo_max,version,updated_at';

class ServicioDescargaNegocio {
  final SupabaseClient _supabase;
  final BaseDatosApp _db;

  /// (De)codificador de los bytes de adjuntos. El decode del remito (base64 remoto →
  /// BLOB local) pasa SIEMPRE por esta interfaz, nunca inline (HU-066).
  final CodificadorAdjuntos _codificador;

  /// Devuelve el ROL BASE del usuario en sesión (`usuarios.rol`). Define si insumos/
  /// recetas se bajan de las vistas operativas (cocinero) o de las tablas base
  /// (admin/superadmin) — HU-045. Se inyecta para no acoplar el servicio a la sesión.
  final String Function()? _rolActual;

  /// Guarda del primer pull (HU-090): al completar un pull COMPLETO (con finanzas)
  /// se marca el negocio como hidratado en este dispositivo. Null en tests.
  final GuardaPrimerPull? _guarda;

  /// Bitácora de conflictos (HU-028). Null en tests que no la ejercitan.
  final ServicioConflictos? conflictos;

  /// #250: cursores del pull incremental. Null = pull SIEMPRE completo
  /// (comportamiento pre-#250): con este repo ausente no se lee ni se guarda
  /// ninguna alta-marca, así que cada tabla se baja entera. Los tests que no lo
  /// inyectan siguen viendo el pull completo de siempre.
  final RepositorioCursoresPull? _cursores;

  ServicioDescargaNegocio(
    this._supabase,
    this._db, {
    String Function()? rolActual,
    GuardaPrimerPull? guarda,
    this.conflictos,
    RepositorioCursoresPull? cursores,
    this._codificador = const CodificadorAdjuntosBase64(),
    // Params PÚBLICOS a propósito: se inyectan desde main.dart (otro library), donde
    // un formal privado `this._rolActual` no sería accesible.
    // ignore: prefer_initializing_formals
  }) : _rolActual = rolActual,
       // Mismo motivo que arriba: el formal es público a propósito.
       // ignore: prefer_initializing_formals
       _guarda = guarda,
       // Mismo motivo que arriba: el formal es público a propósito.
       // ignore: prefer_initializing_formals
       _cursores = cursores;

  /// #250: ventana de solapamiento del cursor incremental.
  ///
  /// El timestamp server-set es `now()`, que en Postgres es el instante de
  /// INICIO de la transacción: una fila cuya transacción arranca ANTES del pull
  /// pero commitea DESPUÉS quedaría por debajo de la alta-marca y no se vería
  /// nunca. Cada pull vuelve a pedir una ventana de este tamaño hacia atrás; la
  /// idempotencia de los upserts (y los corto-circuitos de re-pull idéntico de
  /// `_upsertPedido`/`_upsertRecepcion`) absorbe los duplicados sin escribir de
  /// más ni ensuciar la bitácora de conflictos. El sesgo es deliberado: re-bajar
  /// de más es barato; perder una fila es permanente.
  static const Duration lagCursor = Duration(minutes: 5);

  /// Decide si insumos/recetas se bajan de las VISTAS operativas (sin costo/precio/
  /// margen) o de las tablas base (HU-045). Leen la BASE solo admin y superadmin (que
  /// necesitan las finanzas y a quienes la RLS los autoriza); CUALQUIER otro rol
  /// (cocinero, desconocido o vacío) usa las vistas, para ver el catálogo sin finanzas
  /// en lugar de un catálogo VACÍO (la base pasó a ser solo-admin).
  @visibleForTesting
  static bool usaVistasOperativas(String? rolBase) =>
      rolBase != 'admin' && rolBase != 'superadmin';

  /// Descarga el negocio y sus datos principales a la base local. Cada tabla se
  /// aísla en su propio try/catch: si una falla (RLS, red, tabla ausente), las
  /// demás siguen descargándose.
  ///
  /// El cocinero (y todo rol no admin/superadmin) baja insumos y recetas de las VISTAS
  /// `*_operativo` (sin costo/precio/margen), porque la RLS le niega la lectura de las
  /// tablas base (HU-045). Se decide por el ROL BASE de sesión inyectado (`_rolActual`),
  /// NO por el rol efectivo: la elevación por PIN (HU-043) es solo del cliente y el
  /// backend enforca sobre el rol base, así que los datos financieros nunca se descargan
  /// al dispositivo del cocinero.
  ///
  /// Devuelve `true` si el pull COMPLETO (con finanzas) llegó al backend y se marcó el
  /// primer pull; `false` si estamos offline (la sonda inicial falló) o fue un pull
  /// operativo (cocinero). Los llamadores pueden ignorar el resultado.
  Future<bool> descargarNegocio(String negocioId) async {
    final soloOp = usaVistasOperativas(_rolActual?.call());
    // #249: el resumen de descartes es POR pull — arranca limpio.
    filasOmitidasUltimoPull.clear();

    // 0. (#223) Auto-reparación: soltar las filas que quedaron marcadas para
    //    subir sin nada encolado. Una fila así rechaza TODO lo que baje del
    //    servidor, para siempre y sin avisar, así que repararla antes del pull
    //    es lo que hace que este pull le sirva de algo.
    //
    //    Va acá, ANTES de traer nada: durante el pull competiría con los
    //    upserts que él mismo está aplicando.
    await repararPendientesHuerfanas(_db);

    // 1. El negocio en sí. Hace además de SONDA DE CONECTIVIDAD (HU-090): si esta
    //    primera lectura LANZA, estamos offline / sin acceso → no se hidrató nada, así
    //    que salimos sin marcar el primer pull (las demás tablas fallarían igual, y
    //    marcar con datos incompletos derivaría saldos/anticipos erróneos).
    try {
      final negocio = await _supabase
          .from('negocios')
          .select()
          .eq('id', negocioId)
          .maybeSingle();
      if (negocio != null) await _upsertNegocio(negocio);
    } catch (_) {
      return false;
    }

    // #250: cursores de este negocio (vacío = todas las tablas van completas,
    // que es exactamente el primer pull). El repo es null en `local`/tests, y
    // ahí el mapa vacío mantiene el pull completo de siempre.
    final repoCursores = _cursores;
    final cursores = repoCursores != null
        ? await repoCursores.leer(negocioId)
        : <String, DateTime>{};

    // 2. Tablas filtradas por negocio_id.
    await _pullIncremental(
      'usuarios',
      negocioId,
      _upsertUsuario,
      cursores: cursores,
      columnaCursor: 'updated_at',
    );
    await _pullIncremental(
      'proveedores',
      negocioId,
      _upsertProveedor,
      cursores: cursores,
      columnaCursor: 'updated_at',
    );
    // #262: catálogo de categorías. Va ANTES de insumos (será el padre de
    // `insumos.categoria_id`) y FUERA del bloque financiero, porque el cocinero
    // también las necesita para no reventar esa FK local al bajar sus insumos.
    await _pullIncremental(
      'categorias',
      negocioId,
      _upsertCategoria,
      cursores: cursores,
      columnaCursor: 'updated_at',
    );
    // #262: qué categorías suministra cada proveedor. DESPUÉS de proveedores y
    // categorias (sus dos FK). También fuera del bloque financiero: el cocinero
    // la necesita para el selector del pedido por categoría.
    await _pullIncremental(
      'proveedor_categorias',
      negocioId,
      _upsertProveedorCategoria,
      cursores: cursores,
      columnaCursor: 'updated_at',
    );
    // HU-045: el cocinero baja la vista sin `costo_por_unidad`. Esa vista queda
    // FUERA del incremental (se baja completa): el cursor sólo se aplica al
    // camino de la tabla BASE (admin/superadmin). Es acotar el riesgo — no hace
    // falta afirmar que la vista `_operativo` expone `updated_at` para que el
    // cocinero siga viendo su catálogo, y el volumen pesado del cocinero no está
    // en insumos sino en lo operativo, que igual se incrementaliza abajo.
    if (soloOp) {
      await _pullPorNegocio(
        'insumos_operativo',
        negocioId,
        (m) => _upsertInsumo(m, operativo: true),
      );
    } else {
      await _pullIncremental(
        'insumos',
        negocioId,
        (m) => _upsertInsumo(m, operativo: false),
        cursores: cursores,
        columnaCursor: 'updated_at',
      );
    }
    // HU-013: las agendas van DESPUÉS de proveedores (FK proveedor_id) y ANTES
    // de pedidos, que las referencian por `agenda_id`.
    //
    // Y van acá arriba, FUERA del bloque `if (!soloOp)` de las tablas
    // financieras, a propósito: el COCINERO tiene que bajarlas. Su pull termina
    // antes de ese bloque, así que meterlas ahí dejaría sin entregas
    // programadas justo al usuario que más las mira.
    await _pullIncremental(
      'pedidos_recurrentes',
      negocioId,
      _upsertPedidoRecurrente,
      cursores: cursores,
      columnaCursor: 'updated_at',
    );
    final pedidosOk = await _pullIncremental(
      'pedidos',
      negocioId,
      _upsertPedido,
      cursores: cursores,
      columnaCursor: 'updated_at',
    );

    // 2.b Catálogo de motivos (HU-065) y la cadena recepción → adjuntos (HU-066).
    //     ORDEN POR FK: las recepciones dependen de los pedidos (ya bajados) y los
    //     adjuntos de las recepciones, por eso recepciones va ANTES que adjuntos.
    await _pullIncremental(
      'motivos_recepcion',
      negocioId,
      _upsertMotivoRecepcion,
      cursores: cursores,
      columnaCursor: 'updated_at',
    );
    // #249: la cadena de FK se respeta también cuando un PADRE no llega. El
    // bool de éxito de cada tabla padre existía desde HU-090 y acá se
    // DESCARTABA: con `pedidos` caído (corte de red, RLS), `recepciones` y
    // sus hijas igual se bajaban y cada fila reventaba la FOREIGN KEY una
    // por una, descartándose en un debugPrint que nadie mira — la mecánica
    // exacta que hizo invisible el bug de #247 durante días.
    final recepcionesOk = !pedidosOk
        ? _saltearPorPadreCaido('recepciones', 'pedidos')
        : await _pullIncremental(
            'recepciones',
            negocioId,
            _upsertRecepcion,
            cursores: cursores,
            columnaCursor: 'updated_at',
          );
    if (!recepcionesOk) {
      _saltearPorPadreCaido('adjuntos', 'recepciones');
    } else {
      // HU-110/#244: el cocinero NO baja los adjuntos financieros
      // (comprobantes Y facturas — la exclusión mono-tipo de HU-110 quedó
      // desactualizada cuando HU-147 sumó el tipo 'factura'); sí baja los
      // remitos que él mismo adjunta al recepcionar (HU-066). Es defensa en
      // profundidad: la RLS `see_adjuntos` ya los filtra server-side.
      await _pullIncremental(
        'adjuntos',
        negocioId,
        _upsertAdjunto,
        cursores: cursores,
        // #250: `adjuntos` es mutable (datos_ocr) y desde #250 tiene
        // `updated_at` + trigger, así que se incrementaliza por él — un OCR
        // escrito en otro dispositivo bumpea `updated_at` y vuelve a bajar.
        columnaCursor: 'updated_at',
        excluirTipos: tiposDeAdjuntoExcluidos(soloOperativo: soloOp),
        // #248: SOLO metadatos — sin `contenido_base64`. Bajar la foto entera
        // de todo el historial (~2,1 MB de base64 por foto) era los minutos de
        // espera y la pestaña congelada del reporte del cliente. Los bytes se
        // piden bajo demanda al abrir el visor y quedan cacheados
        // (BackendAdjuntosBlob.obtenerContenido).
        columnas: columnasMetadatosAdjuntos,
      );
    }

    // 3. Recetas (vista operativa para el cocinero — HU-045, sin precio_venta/margen).
    final recetas = await _selectSeguro(
      (desde, hasta) => _supabase
          .from(soloOp ? 'recetas_operativo' : 'recetas')
          .select()
          .eq('negocio_id', negocioId)
          .order('id')
          .range(desde, hasta),
    );
    // HU-136: en transacción por el mismo motivo que _aplicarFilas.
    if (recetas.isNotEmpty) {
      await _db.transaction(() async {
        for (final r in recetas) {
          await _upsertReceta(r, operativo: soloOp);
        }
      });
    }
    // receta_ingredientes tiene su propio `negocio_id` (HU-045) con RLS por negocio → se
    // baja filtrado por negocio como el resto, NO por un `inFilter` de miles de
    // receta_id que reventaría el largo de la URL en negocios grandes (HU-089). Va DESPUÉS
    // de recetas por la FK receta_ingredientes.receta_id → recetas.id.
    await _pullIncremental(
      'receta_ingredientes',
      negocioId,
      _upsertRecetaIngrediente,
      cursores: cursores,
      columnaCursor: 'updated_at',
    );

    // insumo_proveedores (HU-138): tenant propio, igual que receta_ingredientes.
    // Va DESPUÉS de insumos y de proveedores por sus dos FK.
    await _pullIncremental(
      'insumo_proveedores',
      negocioId,
      _upsertInsumoProveedor,
      cursores: cursores,
      columnaCursor: 'updated_at',
    );

    // 3.b (#207) La configuración del negocio, TAMBIÉN para el cocinero.
    //
    //     Vivía sólo en el bloque financiero de abajo, heredando la restricción
    //     admin-only de HU-044. Pero acá no aplica: la policy `see_configuracion`
    //     filtra únicamente por `negocio_id` —sin exigir rol— y la escritura la
    //     sigue protegiendo `admin_edit_configuracion`. O sea que leerla nunca
    //     estuvo prohibido; simplemente nadie la bajaba.
    //
    //     El costo: un dispositivo de cocinero NUNCA tenía la fila, así que todo
    //     lo que se calcula con ella caía al default de fábrica, en silencio y
    //     para siempre. El caso que reportó #207 —el umbral de alertas— se
    //     resolvió solo con #229 (el cálculo se mudó a Procesar, que es del
    //     admin), pero el mismo agujero seguía vivo en los parámetros de costeo
    //     de HU-152/#197: costo por hora y umbrales del semáforo de FoodCost.
    //
    //     ⚠ Se piden COLUMNAS EXPLÍCITAS y `costo_hora_empleado` NO está en la
    //     lista: es un dato salarial y el cocinero no lo necesita —no ve costos
    //     de receta, están detrás de `verFinanzas`—. Pedirlo por nombre hace que
    //     ni siquiera viaje por la red, que es mejor que bajarlo y no guardarlo.
    //     Es la misma idea que las vistas `_operativo` de HU-045, sin migración.
    if (soloOp) {
      await _pullIncremental(
        'configuracion_negocio',
        negocioId,
        _upsertConfiguracion,
        cursores: cursores,
        columnaCursor: 'updated_at',
        columnas: columnasConfiguracionOperativa,
      );
    }

    // 4. Tablas FINANCIERAS (HU-082 / C4). Antes NO se bajaban → un segundo dispositivo
    //    nunca veía facturas ni cuenta corriente y los saldos divergían por dispositivo.
    //    Sólo admin/superadmin: la RLS de estas tablas es admin-only (HU-044), el cocinero
    //    no las descarga. Orden por FK: configuración/facturas/pagos antes que imputaciones.
    if (!soloOp) {
      // HU-090: sólo se marca el primer pull si TODAS las tablas financieras llegaron
      // al backend. No alcanza con que el método termine: los fetch tragan un corte de
      // red por tabla y marcaríamos con datos incompletos → saldos/anticipos derivados
      // erróneos. `anticipos` (HU-092) ya no se descarga: es un valor derivado.
      //
      // #249: mismo gating por FK que arriba. Una tabla SALTEADA aporta `false`
      // (su pull NO ocurrió): el salteo honesto deja el primer pull sin marcar,
      // igual que un corte de red — nunca se finge un pull completo.
      final facturasOk = !recepcionesOk
          ? _saltearPorPadreCaido('facturas', 'recepciones')
          : await _pullIncremental(
              'facturas',
              negocioId,
              _upsertFactura,
              cursores: cursores,
              columnaCursor: 'updated_at',
            );
      // #229: va DESPUÉS de facturas por la FK, y antes que nada que lo mire.
      // Un dispositivo que no lo baje ve la factura sin su detalle: los tres
      // importes de cabecera están, pero el desglose por insumo aparece
      // vacío, como si la factura se hubiera cargado con un único número.
      // #250: append-only → cursor por `fecha_creacion` (no tiene `updated_at`).
      final facturaItemsOk = !facturasOk
          ? _saltearPorPadreCaido('factura_items', 'facturas')
          : await _pullIncremental(
              'factura_items',
              negocioId,
              _upsertFacturaItem,
              cursores: cursores,
              columnaCursor: 'fecha_creacion',
            );
      final pagosOk = await _pullIncremental(
        'pagos',
        negocioId,
        _upsertPago,
        cursores: cursores,
        columnaCursor: 'updated_at',
      );
      // Las imputaciones cuelgan de DOS padres: factura Y pago.
      // #250: append-only → cursor por `created_at`.
      final imputacionesOk = !(facturasOk && pagosOk)
          ? _saltearPorPadreCaido('imputaciones_pago', 'facturas/pagos')
          : await _pullIncremental(
              'imputaciones_pago',
              negocioId,
              _upsertImputacion,
              cursores: cursores,
              columnaCursor: 'created_at',
            );
      // Movimientos e historial NO se gatean: no tienen FK dura hacia las de
      // arriba (referencian proveedor/insumo, ya bajados al principio). Ambas
      // append-only → cursor por `created_at` (#250).
      final resultados = [
        await _pullIncremental(
          'configuracion_negocio',
          negocioId,
          _upsertConfiguracion,
          cursores: cursores,
          columnaCursor: 'updated_at',
        ),
        facturasOk,
        facturaItemsOk,
        pagosOk,
        imputacionesOk,
        await _pullIncremental(
          'movimientos_cuenta_corriente',
          negocioId,
          _upsertMovimiento,
          cursores: cursores,
          columnaCursor: 'created_at',
        ),
        await _pullIncremental(
          'historial_precios',
          negocioId,
          _upsertHistorialPrecio,
          cursores: cursores,
          columnaCursor: 'created_at',
        ),
      ];
      final hidratado = resultados.every((ok) => ok);
      if (hidratado) await _guarda?.marcarPrimerPull(negocioId);
      return hidratado;
    }
    // Pull operativo (cocinero): no baja finanzas, así que no habilita la guarda; pero
    // el cocinero tampoco registra movimientos financieros, así que no se bloquea.
    return false;
  }

  // ─── Helpers de descarga ────────────────────────────────────────────────────

  /// Devuelve `true` si el fetch LLEGÓ al backend (aunque no haya filas), `false` si
  /// LANZÓ (red / RLS / tabla ausente). HU-090 usa este resultado en el bloque
  /// financiero para saber si el pull fue COMPLETO antes de marcar el primer pull: no
  /// alcanza con que el método termine, porque un corte de red se traga por tabla y
  /// marcaríamos con datos incompletos. El upsert de cada fila se aísla aparte (HU-082).
  ///
  /// [excluirTipos]: si viene, se descartan del pull las filas con esos `tipo`.
  /// Lo usa el cocinero para NO bajar los adjuntos financieros (HU-110,
  /// completado en #244: antes excluía solo 'comprobante' y la 'factura' de
  /// HU-147 se colaba a la copia local). Es defensa en profundidad: el
  /// enforcement real es la RLS `see_adjuntos`, que ya filtra server-side.
  ///
  /// [columnas]: lista explícita para PostgREST en vez de `select()`. Se usa
  /// cuando una tabla tiene columnas que este dispositivo NO debe recibir
  /// (#207): pidiéndolas por nombre, el dato sensible ni siquiera viaja por la
  /// red — que es bastante mejor que bajarlo y no guardarlo.
  /// #248: las columnas que el pull de adjuntos SÍ baja — todas menos
  /// `contenido_base64`. La lista es explícita (mecanismo de #207) para que
  /// el dato pesado ni siquiera viaje por la red; tiene que cubrir todo lo
  /// que `_upsertAdjunto` mapea, o el campo faltante degrada a su default.
  /// #250: incluye `updated_at` — el cursor incremental de adjuntos lee ese
  /// campo para calcular su alta-marca. Sin él, el pull de adjuntos no podría
  /// avanzar el cursor (bajaría todo siempre).
  static const String columnasMetadatosAdjuntos =
      'id,negocio_id,recepcion_id,pago_id,nombre_archivo,mime_type,'
      'tamanio_bytes,tipo,datos_ocr,created_at,updated_at';

  /// #244: qué tipos de adjunto NO baja un dispositivo operativo — el
  /// conjunto financiero ENTERO, no un literal suelto: sumar un tipo
  /// financiero nuevo toca UN lugar de cada lado (`tipo_adjunto.dart` acá,
  /// la RLS `see_adjuntos` allá). Estática y pura: es la costura testeable
  /// de la defensa en profundidad del cliente.
  static Set<String>? tiposDeAdjuntoExcluidos({required bool soloOperativo}) =>
      soloOperativo ? TipoAdjunto.financieros : null;

  /// #249: deja constancia de que una tabla HIJA se salteó porque su [padre]
  /// no llegó en este pull, y devuelve `false` (el pull de esa tabla NO
  /// ocurrió). Saltear es mejor que intentar: sin el padre, CADA fila hija
  /// reventaría la FOREIGN KEY local y se descartaría una por una — filas que
  /// el próximo pull con el padre sano sí va a aplicar.
  bool _saltearPorPadreCaido(String tabla, String padre) {
    debugPrint(
      '[PULL] $tabla SALTEADA en este pull: su padre ($padre) no llegó. '
      'Se reintenta completa en el próximo pull.',
    );
    return false;
  }

  /// #250: baja una tabla en modo INCREMENTAL — sólo lo cambiado desde el
  /// cursor guardado — y avanza el cursor si el pull fue confiable.
  ///
  /// [cursores] es el mapa `tabla → alta-marca` leído al inicio del pull;
  /// [columnaCursor] es el timestamp server-set por el que se filtra y avanza
  /// (`updated_at` para las mutables, `created_at`/`fecha_creacion` para las
  /// append-only). Devuelve `true` si el fetch llegó (el bool que usa el gating
  /// de FK de #249), igual que [_pullPorNegocio].
  ///
  /// El cursor avanza SÓLO si el pull fue confiable, y ese invariante es lo que
  /// vuelve seguro el incremental (sinergia con #249): con el pull completo el
  /// padre siempre estaba antes que el hijo; con el incremental el padre puede
  /// no venir en esta tanda. Por eso NO se avanza si el fetch no llegó, o si
  /// `_aplicarFilas` omitió alguna fila (FK rota): esas filas se re-piden en el
  /// próximo pull desde el cursor viejo. Una tabla SALTEADA por el gating ni
  /// siquiera llega acá, así que su cursor tampoco avanza.
  Future<bool> _pullIncremental(
    String tabla,
    String negocioId,
    Future<void> Function(Map<String, dynamic>) upsert, {
    required Map<String, DateTime> cursores,
    required String columnaCursor,
    Set<String>? excluirTipos,
    String? columnas,
  }) async {
    final previo = cursores[tabla];
    // El lag se resta acá (no al guardar): el cursor guardado es la alta-marca
    // exacta y nunca retrocede; la ventana de solapamiento vive sólo en el filtro.
    final desde = previo?.subtract(lagCursor);
    final r = await _pullPorNegocio(
      tabla,
      negocioId,
      upsert,
      excluirTipos: excluirTipos,
      columnas: columnas,
      columnaCursor: columnaCursor,
      cursorDesde: desde,
    );
    final confiable = r.llego && (filasOmitidasUltimoPull[tabla] ?? 0) == 0;
    if (confiable && r.altaMarca != null) {
      // Nunca retrocede: sólo se persiste si la marca nueva supera la guardada.
      if (previo == null || r.altaMarca!.isAfter(previo)) {
        await _cursores?.guardar(negocioId, tabla, r.altaMarca!);
      }
    }
    return r.llego;
  }

  /// Devuelve `llego`: `true` si el fetch LLEGÓ al backend (aunque no haya
  /// filas), `false` si LANZÓ (red / RLS / tabla ausente). HU-090 usa este
  /// resultado en el bloque financiero para saber si el pull fue COMPLETO antes
  /// de marcar el primer pull: no alcanza con que el método termine, porque un
  /// corte de red se traga por tabla y marcaríamos con datos incompletos. El
  /// upsert de cada fila se aísla aparte (HU-082).
  ///
  /// `altaMarca` (#250): el mayor [columnaCursor] entre las filas traídas, o
  /// null si no hubo filas o no se pidió cursor. Es el valor con el que el
  /// llamador incremental avanza el cursor.
  ///
  /// [excluirTipos]: si viene, se descartan del pull las filas con esos `tipo`.
  /// Lo usa el cocinero para NO bajar los adjuntos financieros (HU-110,
  /// completado en #244: antes excluía solo 'comprobante' y la 'factura' de
  /// HU-147 se colaba a la copia local). Es defensa en profundidad: el
  /// enforcement real es la RLS `see_adjuntos`, que ya filtra server-side.
  ///
  /// [columnas]: lista explícita para PostgREST en vez de `select()`. Se usa
  /// cuando una tabla tiene columnas que este dispositivo NO debe recibir
  /// (#207): pidiéndolas por nombre, el dato sensible ni siquiera viaja por la
  /// red — que es bastante mejor que bajarlo y no guardarlo.
  ///
  /// [columnaCursor]/[cursorDesde] (#250): si vienen, el fetch agrega
  /// `.gte(columnaCursor, cursorDesde)` — el filtro incremental. `cursorDesde`
  /// ya trae el lag restado. El `.order('id')` de HU-089 se mantiene, así que
  /// la paginación por rango sigue estable.
  Future<({bool llego, DateTime? altaMarca})> _pullPorNegocio(
    String tabla,
    String negocioId,
    Future<void> Function(Map<String, dynamic>) upsert, {
    Set<String>? excluirTipos,
    String? columnas,
    String? columnaCursor,
    DateTime? cursorDesde,
  }) async {
    final List<Map<String, dynamic>> filas;
    try {
      // HU-089: paginado por rango con orden ESTABLE (`.order('id')`; sin él el rango
      // podría saltear/duplicar filas entre requests).
      filas = await PaginacionPostgrest.paginarTodo((desde, hasta) async {
        var consulta = _supabase
            .from(tabla)
            .select(columnas ?? '*')
            .eq('negocio_id', negocioId);
        // Cadena de `neq` (AND) y no un `not in`: mismo resultado sin depender
        // del formato de listas de PostgREST.
        for (final tipo in excluirTipos ?? const <String>{}) {
          consulta = consulta.neq('tipo', tipo);
        }
        // #250: el filtro incremental. El timestamp viaja en ISO-8601 UTC, el
        // mismo formato en que Postgres lo devuelve y compara.
        if (columnaCursor != null && cursorDesde != null) {
          consulta = consulta.gte(
            columnaCursor,
            cursorDesde.toUtc().toIso8601String(),
          );
        }
        final res = await consulta.order('id').range(desde, hasta);
        return (res as List).cast<Map<String, dynamic>>();
      });
    } catch (e) {
      // Fetch no llegó al backend (red / RLS / vista ausente). Se loguea para poder
      // diagnosticar un bloqueo persistente del primer pull (HU-090) por una tabla.
      debugPrint('[PULL] Fetch falló en $tabla (negocio=$negocioId): $e');
      return (llego: false, altaMarca: null);
    }
    await _aplicarFilas(tabla, filas, upsert);
    return (llego: true, altaMarca: _maxTimestamp(filas, columnaCursor));
  }

  /// #250: el mayor valor de [columna] entre [filas] (la alta-marca del lote),
  /// o null si no se pidió cursor o el lote vino vacío. Tolera timestamps
  /// ausentes o malformados (los ignora) para no romper el avance por una fila
  /// rara.
  static DateTime? _maxTimestamp(
    List<Map<String, dynamic>> filas,
    String? columna,
  ) {
    if (columna == null) return null;
    DateTime? maximo;
    for (final f in filas) {
      final ts = DateTime.tryParse((f[columna] as String?) ?? '');
      if (ts != null && (maximo == null || ts.isAfter(maximo))) {
        maximo = ts;
      }
    }
    return maximo;
  }

  /// Aplica los upserts de una tabla dentro de UNA transacción (HU-136). Mismo
  /// resultado fila a fila, pero Drift difiere las notificaciones de watch() al
  /// commit: sin esto, cada fila despertaba a TODOS los listeners reactivos
  /// (medido: 300 filas = 151 emisiones y 8× más tiempo de inserción) y producía
  /// jank durante el pull post-login. El aislamiento por fila de HU-082 se
  /// conserva: en SQLite una sentencia fallida CAPTURADA no aborta la transacción.
  Future<void> _aplicarFilas(
    String tabla,
    List<Map<String, dynamic>> filas,
    Future<void> Function(Map<String, dynamic>) upsert,
  ) async {
    if (filas.isEmpty) return;
    var omitidas = 0;
    await _db.transaction(() async {
      for (var i = 0; i < filas.length; i++) {
        // #249: ceder el event loop cada tanda (patrón cooperativo HU-136,
        // como el PBKDF2 del login). En Flutter Web NO hay isolates: un pull
        // grande dentro de esta transacción monopolizaba el main thread y la
        // pestaña quedaba congelada ("renderer frozen") — se vio en vivo al
        // verificar #247. El commit sigue siendo uno solo.
        if (i > 0 && i % 50 == 0) await Future<void>.delayed(Duration.zero);
        final f = filas[i];
        try {
          await upsert(f);
        } catch (e) {
          omitidas++;
          debugPrint('[PULL] Fila omitida en $tabla (id=${f['id']}): $e');
        }
      }
    });
    // #249: el descarte deja de ser invisible — un resumen por tabla, contado
    // y consultable (`filasOmitidasUltimoPull`), en vez de N debugPrint
    // sueltos que nadie mira: así se detecta la próxima asimetría tipo #247.
    if (omitidas > 0) {
      filasOmitidasUltimoPull[tabla] =
          (filasOmitidasUltimoPull[tabla] ?? 0) + omitidas;
      debugPrint(
        '[PULL] ⚠ $tabla: $omitidas de ${filas.length} filas OMITIDAS '
        '(FK rota o datos inválidos).',
      );
    }
  }

  /// #249: filas descartadas por tabla durante el ÚLTIMO pull (se resetea al
  /// empezar [descargarNegocio]). Vacío = pull limpio. Es el dato que faltaba
  /// cuando #247 descartó las recepciones de la demo en silencio durante días.
  final Map<String, int> filasOmitidasUltimoPull = {};

  /// Wrapper de testing de [_aplicarFilas], sin Supabase (HU-136).
  @visibleForTesting
  Future<void> aplicarFilasRemotas(
    String tabla,
    List<Map<String, dynamic>> filas,
    Future<void> Function(Map<String, dynamic>) upsert,
  ) => _aplicarFilas(tabla, filas, upsert);

  /// Ejecuta un select PAGINADO (HU-089) y tolerante a fallos: ante error (RLS, tabla
  /// inexistente, red) devuelve lista vacía en lugar de abortar toda la descarga. El
  /// [consulta] recibe el rango `(desde, hasta)` para aplicarlo con `.range()`.
  Future<List<Map<String, dynamic>>> _selectSeguro(
    Future<dynamic> Function(int desde, int hasta) consulta,
  ) async {
    try {
      return await PaginacionPostgrest.paginarTodo((desde, hasta) async {
        final res = await consulta(desde, hasta);
        return (res as List).cast<Map<String, dynamic>>();
      });
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  // ─── Política de conflictos del pull (HU-028) ───────────────────────────────

  /// Estado local relevante para decidir si se aplica la fila remota.
  /// SQL crudo para poder consultar cualquier tabla de forma genérica; las
  /// append-only no tienen `version` y devuelven null.
  Future<({bool existe, int? version, String? estadoSync})> _estadoLocal(
    String tabla,
    String id,
  ) async {
    try {
      final filas = await _db
          .customSelect(
            'SELECT * FROM $tabla WHERE id = ?',
            variables: [Variable<String>(id)],
          )
          .get();
      if (filas.isEmpty) {
        return (existe: false, version: null, estadoSync: null);
      }
      final d = filas.first.data;
      return (
        existe: true,
        version: (d['version'] as num?)?.toInt(),
        estadoSync: d['estado_sync'] as String?,
      );
    } catch (_) {
      // Tabla sin esas columnas o inaccesible: se comporta como "no existe"
      // (aplicar), que es el comportamiento previo a HU-028.
      return (existe: false, version: null, estadoSync: null);
    }
  }

  /// ¿Se aplica la fila remota [m] de [tabla] sobre lo local? (HU-028)
  ///
  /// Protege dos cosas que hasta ahora el pull pisaba sin mirar: un cambio local
  /// EN VUELO más nuevo que el remoto, y los registros append-only (asientos,
  /// remitos, auditoría), que no deben mutar jamás.
  Future<bool> _aplicaRemoto(
    String tabla,
    Map<String, dynamic> m, {
    bool importesCoinciden = true,

    /// Para append-only: el remoto trae un contenido DISTINTO del ya guardado
    /// (el dato no se pisa, pero hay dos versiones vivas → conflicto).
    bool contenidoDivergente = false,
  }) async {
    final id = m['id'] as String?;
    if (id == null) return true;
    final familia = PoliticaConflictos.familiaDe(tabla);
    final local = await _estadoLocal(tabla, id);
    final aplicar = PoliticaConflictos.debeAplicarRemoto(
      familia: familia,
      existeLocal: local.existe,
      estadoSyncLocal: local.estadoSync,
      versionLocal: local.version,
      versionRemota: (m['version'] as num?)?.toInt(),
      importesCoinciden: importesCoinciden,
    );
    final versionRemota = (m['version'] as num?)?.toInt();
    if (!aplicar) {
      debugPrint(
        '[PULL] $tabla/$id: se conserva lo local (familia $familia, '
        'estadoSync=${local.estadoSync}, vLocal=${local.version}, '
        'vRemota=${m['version']}).',
      );
    }
    // HU-028 fase 4: se deja constancia del cruce (en ambos sentidos: si ganó lo
    // remoto pisando un cambio en vuelo, o si se rechazó el remoto y quedan dos
    // versiones vivas). El pull normal sobre filas sincronizadas NO es conflicto.
    if (PoliticaConflictos.esConflicto(
      familia: familia,
      existeLocal: local.existe,
      seAplico: aplicar,
      estadoSyncLocal: local.estadoSync,
      contenidoDivergente: contenidoDivergente || !importesCoinciden,
    )) {
      await conflictos?.registrar(
        nombreTabla: tabla,
        registroId: id,
        motivo: aplicar
            ? MotivoConflicto.pullPisoLocal
            : MotivoConflicto.pullRechazado,
        negocioId: m['negocio_id'] as String?,
        versionLocal: local.version,
        versionRemota: versionRemota,
        detalle: aplicar
            ? 'El pull aplicó la versión remota sobre un cambio local en vuelo.'
            : 'Se conservó la versión local; el remoto no se aplicó.',
      );
    }
    return aplicar;
  }

  // ─── Upserts (Supabase snake_case → Drift). Marcan estadoSync = 'sincronizado'. ──

  Future<void> _upsertNegocio(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('negocios', m)) return;
    await _db
        .into(_db.negocios)
        .insertOnConflictUpdate(
          NegociosCompanion(
            id: Value(m['id'] as String),
            nombre: Value((m['nombre'] as String?) ?? ''),
            tipo: Value((m['tipo'] as String?) ?? 'restaurante'),
            pais: Value((m['pais'] as String?) ?? 'Argentina'),
            email: Value(m['email'] as String?),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            // HU-028: el reloj del servidor baja al cliente para poder
            // desempatar conflictos (antes nunca se mapeaba).
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertUsuario(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('usuarios', m)) return;
    await _db
        .into(_db.usuarios)
        .insertOnConflictUpdate(
          UsuariosCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            nombre: Value((m['nombre'] as String?) ?? ''),
            rol: Value(
              Permisos.parsearRol(m['rol']),
            ), // HU-108: parseo único, fail-closed
            email: Value(m['email'] as String?),
            activo: Value(m['activo'] as bool? ?? true),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            // HU-028: el reloj del servidor baja al cliente para poder
            // desempatar conflictos (antes nunca se mapeaba).
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertProveedor(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('proveedores', m)) return;
    await _db
        .into(_db.proveedores)
        .insertOnConflictUpdate(
          ProveedoresCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            nombre: Value((m['nombre'] as String?) ?? ''),
            categoria: Value(m['categoria'] as String?),
            contacto: Value(m['contacto'] as String?),
            email: Value(m['email'] as String?),
            telefono: Value(m['telefono'] as String?),
            cuit: Value(m['cuit'] as String?),
            plazoPago: Value(m['plazo_pago'] as String?),
            // #220: si el servidor todavía no tiene las columnas, la clave viene
            // ausente y esto queda en null — que es exactamente "sin cargar".
            // La bajada tolera el desfase; la SUBIDA no, y por eso el SQL va
            // primero (ver `MapeadoresSupabase.proveedor`).
            aliasBancario: Value(m['alias_bancario'] as String?),
            cbu: Value(m['cbu'] as String?),
            activo: Value(m['activo'] as bool? ?? true),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            // HU-028: el reloj del servidor baja al cliente para poder
            // desempatar conflictos (antes nunca se mapeaba).
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertInsumo(
    Map<String, dynamic> m, {
    bool operativo = false,
  }) async {
    // Guarda de conflictos, como las otras 16 tablas del pull (A-03).
    //
    // Faltaba en `insumos` y en `recetas` — las dos tablas MÁS editadas — y no
    // era una decisión: `PoliticaConflictos` ya las clasifica en una familia.
    // Sin esto, renombrar o archivar sin conexión y que el pull llegue antes que
    // el push borraba la edición del usuario sin dejar rastro, ni siquiera en la
    // bitácora de conflictos.
    //
    // OJO con lo que esta guarda NO cubre, porque el commit original lo afirmó
    // de más: el PRECIO no pasa por acá. `registrarPrecioInsumo` sólo refresca
    // `costoPorUnidad`, que es un CACHÉ derivado del último `historial_precios`
    // —y el servidor lo deriva igual, con su propio trigger—. El dato autoral es
    // la fila de historial, que sí se encola; un pull puede hacer retroceder ese
    // caché un rato, hasta que el push llega y el trigger lo recalcula.
    //
    // El nombre de tabla es el LOCAL a propósito, aunque el fetch use la vista
    // `insumos_operativo` cuando el rol es cocinero. `_estadoLocal` arma un
    // `SELECT * FROM <tabla>`: con el nombre de la vista la tabla no existe en
    // SQLite, cae al `catch`, devuelve "no existe" y la guarda aplica SIEMPRE
    // — el bug intacto y con apariencia de arreglado.
    if (!await _aplicaRemoto('insumos', m)) return;
    await _db
        .into(_db.insumos)
        .insertOnConflictUpdate(
          InsumosCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            nombre: Value((m['nombre'] as String?) ?? ''),
            categoria: Value((m['categoria'] as String?) ?? ''),
            unidad: Value((m['unidad'] as String?) ?? 'u'),
            // HU-045: en el pull operativo (cocinero) la columna NO viene. Con
            // Value.absent NO se pisa la caché local — así no se destruye a 0 el costo que
            // un admin haya cacheado en un dispositivo compartido (una fila nueva queda en
            // el default 0.0 por el INSERT).
            costoPorUnidad: operativo
                ? const Value.absent()
                : Value(Dinero.parsear(m['costo_por_unidad'])),
            proveedorId: Value(m['proveedor_id'] as String?),
            // #262: la categoría-entidad. Defensivo: si el pull operativo del
            // cocinero todavía no expone `categoria_id` en su vista, la clave no
            // viene y NO se pisa la FK local (Value.absent) en vez de nulearla.
            categoriaId: m.containsKey('categoria_id')
                ? Value(m['categoria_id'] as String?)
                : const Value.absent(),
            tipo: Value((m['tipo'] as String?) ?? 'ingrediente'),
            activo: Value(m['activo'] as bool? ?? true),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            // HU-028: el reloj del servidor baja al cliente para poder
            // desempatar conflictos (antes nunca se mapeaba).
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertReceta(
    Map<String, dynamic> m, {
    bool operativo = false,
  }) async {
    // Guarda de conflictos, como las otras 16 tablas del pull (A-03).
    //
    // Faltaba en `insumos` y en `recetas` — las dos tablas MÁS editadas — y no
    // era una decisión: `PoliticaConflictos` ya las clasifica en una familia.
    // Sin esto, renombrar o archivar sin conexión y que el pull llegue antes que
    // el push borraba la edición del usuario sin dejar rastro, ni siquiera en la
    // bitácora de conflictos.
    //
    // Lo que esta guarda NO cubre del lado de recetas: el pull OPERATIVO (rol
    // cocinero) ya viene sin `precio_venta_carta` ni `tiempo_elaboracion_minutos`
    // y los deja con `Value.absent()` — o sea que esas dos no se pisan porque
    // nunca llegan, no porque la guarda las defienda. Ver el bloque `operativo ?`
    // más abajo.
    //
    // El nombre de tabla es el LOCAL a propósito, aunque el fetch use la vista
    // `recetas_operativo` cuando el rol es cocinero. `_estadoLocal` arma un
    // `SELECT * FROM <tabla>`: con el nombre de la vista la tabla no existe en
    // SQLite, cae al `catch`, devuelve "no existe" y la guarda aplica SIEMPRE
    // — el bug intacto y con apariencia de arreglado.
    if (!await _aplicaRemoto('recetas', m)) return;
    await _db
        .into(_db.recetas)
        .insertOnConflictUpdate(
          RecetasCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            nombre: Value((m['nombre'] as String?) ?? ''),
            porciones: Value((m['porciones'] as num?)?.toDouble() ?? 1.0),
            // HU-045: el pull operativo no trae estas columnas; Value.absent para NO
            // pisar lo que un admin haya cacheado en un dispositivo compartido.
            precioVentaCarta: operativo
                ? const Value.absent()
                : Value(Dinero.parsearNullable(m['precio_venta_carta'])),
            margenDeseadoPorcentaje: operativo
                ? const Value.absent()
                : Value((m['margen_deseado_porcentaje'] as num?)?.toDouble()),
            // HU-152: mismo trato `operativo` que las dos de arriba (HU-045) — el
            // pull del cocinero no trae la columna y no debe pisar lo cacheado.
            // `numeric` → se parsea como string, igual que precio_venta_carta.
            tiempoElaboracionMinutos: operativo
                ? const Value.absent()
                : Value(
                    Dinero.parsearNullable(m['tiempo_elaboracion_minutos']),
                  ),
            categoria: Value((m['categoria'] as String?) ?? 'Principal'),
            imagenUrl: Value(m['imagen_url'] as String?),
            archivada: Value(m['archivada'] as bool? ?? false),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            // HU-028: el reloj del servidor baja al cliente para poder
            // desempatar conflictos (antes nunca se mapeaba).
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertRecetaIngrediente(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('receta_ingredientes', m)) return;
    await _db
        .into(_db.recetaIngredientes)
        .insertOnConflictUpdate(
          RecetaIngredientesCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            recetaId: Value(m['receta_id'] as String),
            insumoId: Value(m['insumo_id'] as String),
            cantidadNeta: Value(
              (m['cantidad_neta'] as num?)?.toDouble() ?? 0.0,
            ),
            unidadCantidad: Value(m['unidad_cantidad'] as String?),
            desperdicioPorcentaje: Value(
              (m['desperdicio_porcentaje'] as num?)?.toDouble() ?? 0.0,
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertInsumoProveedor(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('insumo_proveedores', m)) return;
    await _db
        .into(_db.insumoProveedores)
        .insertOnConflictUpdate(
          InsumoProveedoresCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            insumoId: Value(m['insumo_id'] as String),
            proveedorId: Value(m['proveedor_id'] as String),
            precio: Value(Dinero.parsearNullable(m['precio'])),
            activo: Value((m['activo'] as bool?) ?? true),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  /// HU-013: agenda de un pedido recurrente.
  ///
  /// `fecha_inicio` y `fecha_ultima_ocurrencia_emitida` son `date` en Supabase:
  /// se parsean con el mismo módulo que las escribe, que las deja a medianoche
  /// local. `fecha_inicio` es el ANCLA de toda la serie, así que un día corrido
  /// acá corre todas las entregas futuras.
  Future<void> _upsertPedidoRecurrente(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('pedidos_recurrentes', m)) return;
    await _db
        .into(_db.pedidosRecurrentes)
        .insertOnConflictUpdate(
          PedidosRecurrentesCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            proveedorId: Value(m['proveedor_id'] as String),
            tipo: Value((m['tipo'] as String?) ?? ''),
            diasSemana: Value((m['dias_semana'] as num?)?.toInt()),
            diaMes: Value((m['dia_mes'] as num?)?.toInt()),
            cadaNDias: Value((m['cada_n_dias'] as num?)?.toInt()),
            ancla: Value(m['ancla'] as String?),
            fechaInicio: Value(
              FechaRecepcion.desdeIso(m['fecha_inicio']) ?? DateTime.now(),
            ),
            fechaUltimaOcurrenciaEmitida: Value(
              FechaRecepcion.desdeIso(m['fecha_ultima_ocurrencia_emitida']),
            ),
            items: Value(m['items'] != null ? jsonEncode(m['items']) : '[]'),
            tieneEfectivo: Value(m['tiene_efectivo'] as bool? ?? false),
            nota: Value(m['nota'] as String?),
            activo: Value(m['activo'] as bool? ?? true),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  /// Wrapper de testing del pull de una agenda, sin Supabase.
  @visibleForTesting
  Future<void> upsertPedidoRecurrenteRemoto(Map<String, dynamic> m) =>
      _upsertPedidoRecurrente(m);

  Future<void> _upsertPedido(Map<String, dynamic> m) async {
    // Corto-circuito de re-pull IDÉNTICO, con el molde de `_upsertRecepcion`.
    //
    // `pedidos` es familia `maestro`, así que con una fila local todavía
    // `pendiente` y `versionLocal >= versionRemota`, `debeAplicarRemoto`
    // devuelve false y `_aplicaRemoto` registra un conflicto `pullRechazado`.
    // Cuando el contenido que baja es EXACTAMENTE el que ya está guardado, ese
    // conflicto es FALSO: no hay nada que reconciliar, sólo un push a medio
    // marcar. Sin este corte, ese falso conflicto se registra en CADA pull, para
    // siempre, y la bitácora de conflictos se llena de ruido que tapa los reales.
    //
    // Beneficia al pull de pedidos entero, no sólo a las entregas de HU-013 —
    // pero con las agendas se volvía sistemático, porque una entrega
    // materializada queda pendiente hasta que drena la cola.
    final pedidoLocal = await (_db.select(
      _db.pedidos,
    )..where((p) => p.id.equals(m['id'] as String))).getSingleOrNull();
    if (pedidoLocal != null &&
        pedidoLocal.estado == ((m['estado'] as String?) ?? 'borrador') &&
        pedidoLocal.items ==
            (m['items'] != null ? jsonEncode(m['items']) : '[]') &&
        pedidoLocal.total == Dinero.parsearNullable(m['total']) &&
        pedidoLocal.nota == (m['nota'] as String?) &&
        pedidoLocal.agendaId == (m['agenda_id'] as String?) &&
        pedidoLocal.fechaRecepcionSolicitada ==
            FechaRecepcion.desdeIso(m['fecha_recepcion_solicitada']) &&
        pedidoLocal.version == ((m['version'] as num?)?.toInt() ?? 0)) {
      return; // re-pull idéntico: ni conflicto ni escritura
    }
    if (!await _aplicaRemoto('pedidos', m)) return;
    await _db
        .into(_db.pedidos)
        .insertOnConflictUpdate(
          PedidosCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            proveedorNombre: Value((m['proveedor_nombre'] as String?) ?? ''),
            proveedorId: Value(m['proveedor_id'] as String?),
            estado: Value((m['estado'] as String?) ?? 'borrador'),
            nota: Value(m['nota'] as String?),
            creadoPor: Value(m['creado_por'] as String?),
            creadoPorNombre: Value(m['creado_por_nombre'] as String?),
            recepcionadoPor: Value(m['recepcionado_por'] as String?),
            recepcionadoPorNombre: Value(
              m['recepcionado_por_nombre'] as String?,
            ),
            items: Value(m['items'] != null ? jsonEncode(m['items']) : '[]'),
            total: Value(Dinero.parsearNullable(m['total'])),
            tieneEfectivo: Value(m['tiene_efectivo'] as bool? ?? false),
            alertas: Value(
              m['alertas'] != null ? jsonEncode(m['alertas']) : null,
            ),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            // HU-142: llega como `aaaa-mm-dd` (columna `date`). Se parsea con el
            // mismo módulo que la escribe, que la deja a medianoche LOCAL: usar
            // _fecha() serviría, pero dejaría el día atado al formato del servidor.
            fechaRecepcionSolicitada: Value(
              FechaRecepcion.desdeIso(m['fecha_recepcion_solicitada']),
            ),
            // HU-013: procedencia. Sin este mapeo la entrega baja a otro
            // dispositivo SIN su marca de recurrente: pierde el icono, se ordena
            // como un pedido normal y —lo grave— el generador de ese dispositivo
            // no la ve como parte de la serie y agenda la siguiente igual.
            agendaId: Value(m['agenda_id'] as String?),
            // HU-028: el reloj del servidor baja al cliente para poder
            // desempatar conflictos (antes nunca se mapeaba).
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            // HU-122: conservar la fecha real de creación del pedido. Sin este mapeo,
            // un INSERT fresco (otro dispositivo / reinstalación) caía al default de
            // Drift (currentDateAndTime) y el pedido aparecía "creado hoy".
            fechaCreacion: Value(_fecha(m['created_at']) ?? DateTime.now()),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  /// Wrapper de testing del pull de un pedido, sin Supabase (HU-122).
  @visibleForTesting
  Future<void> upsertPedidoRemoto(Map<String, dynamic> m) => _upsertPedido(m);

  /// Wrapper de testing del pull de un insumo (A-03), sin Supabase.
  @visibleForTesting
  Future<void> upsertInsumoRemoto(
    Map<String, dynamic> m, {
    bool operativo = false,
  }) => _upsertInsumo(m, operativo: operativo);

  /// Wrapper de testing del pull de una receta (HU-152), sin Supabase.
  @visibleForTesting
  Future<void> upsertRecetaRemota(
    Map<String, dynamic> m, {
    bool operativo = false,
  }) => _upsertReceta(m, operativo: operativo);

  /// Wrapper de testing del pull de la configuracion del negocio (HU-152).
  @visibleForTesting
  Future<void> upsertConfiguracionRemota(Map<String, dynamic> m) =>
      _upsertConfiguracion(m);

  /// Wrapper de testing del pull de un vínculo insumo↔proveedor (HU-138).
  @visibleForTesting
  Future<void> upsertInsumoProveedorRemoto(Map<String, dynamic> m) =>
      _upsertInsumoProveedor(m);

  Future<void> _upsertMotivoRecepcion(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('motivos_recepcion', m)) return;
    await _db
        .into(_db.motivosRecepcion)
        .insertOnConflictUpdate(
          MotivosRecepcionCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            nombre: Value((m['nombre'] as String?) ?? ''),
            activo: Value(m['activo'] as bool? ?? true),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            // HU-028: el reloj del servidor baja al cliente para poder
            // desempatar conflictos (antes nunca se mapeaba).
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  // #262: espejo de _upsertMotivoRecepcion para el catálogo de categorías.
  Future<void> _upsertCategoria(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('categorias', m)) return;
    await _db
        .into(_db.categorias)
        .insertOnConflictUpdate(
          CategoriasCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            nombre: Value((m['nombre'] as String?) ?? ''),
            activo: Value(m['activo'] as bool? ?? true),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  // #262: espejo para la tabla puente proveedor↔categoría.
  Future<void> _upsertProveedorCategoria(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('proveedor_categorias', m)) return;
    await _db
        .into(_db.proveedorCategorias)
        .insertOnConflictUpdate(
          ProveedorCategoriasCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            proveedorId: Value(m['proveedor_id'] as String),
            categoriaId: Value(m['categoria_id'] as String),
            activo: Value(m['activo'] as bool? ?? true),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertRecepcion(Map<String, dynamic> m) async {
    // HU-143: recepciones pasó de append-only a MUTABLE ACOTADA (familia
    // `maestro` en PoliticaConflictos), PERO lo mutable es SOLO el total manual
    // + autoría: los items/nota son EVIDENCIA y jamás se reescriben sobre una
    // fila existente (ver el update acotado más abajo). Un re-pull idéntico
    // sobre una fila local (aún pendiente por un push a medio marcar) es el
    // caso normal: se corta acá sin ruido.
    final recLocal = await (_db.select(
      _db.recepciones,
    )..where((r) => r.id.equals(m['id'] as String))).getSingleOrNull();
    final itemsRemotos = m['items'] != null ? jsonEncode(m['items']) : '[]';
    final totalRemoto = Dinero.parsearNullable(m['total_recibido']);
    if (recLocal != null &&
        recLocal.items == itemsRemotos &&
        recLocal.nota == (m['nota'] as String?) &&
        recLocal.totalRecibido == totalRemoto &&
        recLocal.version == ((m['version'] as num?)?.toInt() ?? 0)) {
      return; // re-pull idéntico: ni conflicto ni escritura
    }
    if (!await _aplicaRemoto('recepciones', m)) {
      return;
    }
    // HU-121: espejo local de la unicidad (pedido, numero). Si una fila LOCAL
    // distinta (optimista, aún sin push) ocupa el número que trae el server, se
    // corre al siguiente libre: el número server-side es autoritativo y esa fila
    // será renumerada por el BEFORE INSERT del server cuando haga su push.
    final pedidoId = m['pedido_id'] as String;
    final numero = (m['numero_recepcion'] as num?)?.toInt() ?? 1;
    final colision =
        await (_db.select(_db.recepciones)..where(
              (r) =>
                  r.pedidoId.equals(pedidoId) &
                  r.numeroRecepcion.equals(numero) &
                  r.id.equals(m['id'] as String).not(),
            ))
            .getSingleOrNull();
    if (colision != null) {
      final delPedido = await (_db.select(
        _db.recepciones,
      )..where((r) => r.pedidoId.equals(pedidoId))).get();
      final maximo = delPedido
          .map((r) => r.numeroRecepcion)
          .reduce((a, b) => a > b ? a : b);
      await (_db.update(_db.recepciones)
            ..where((r) => r.id.equals(colision.id)))
          .write(RecepcionesCompanion(numeroRecepcion: Value(maximo + 1)));
    }
    if (recLocal == null) {
      // Alta: fila completa tal como llegó.
      await _db
          .into(_db.recepciones)
          .insertOnConflictUpdate(
            RecepcionesCompanion(
              id: Value(m['id'] as String),
              negocioId: Value(m['negocio_id'] as String),
              pedidoId: Value(m['pedido_id'] as String),
              numeroRecepcion: Value(
                (m['numero_recepcion'] as num?)?.toInt() ?? 1,
              ),
              recepcionadoPor: Value(m['recepcionado_por'] as String?),
              recepcionadoPorNombre: Value(
                m['recepcionado_por_nombre'] as String?,
              ),
              items: Value(itemsRemotos),
              nota: Value(m['nota'] as String?),
              // HU-143: total manual + autoría + token LWW. El monto llega como
              // string (numeric remoto, HU-081) → Dinero.parsearNullable.
              totalRecibido: Value(totalRemoto),
              totalEditadoPor: Value(m['total_editado_por'] as String?),
              totalEditadoPorNombre: Value(
                m['total_editado_por_nombre'] as String?,
              ),
              fechaTotalEditado: Value(_fecha(m['fecha_total_editado'])),
              version: Value((m['version'] as num?)?.toInt() ?? 0),
              fechaActualizacion: Value(
                _fecha(m['updated_at']) ?? DateTime.now(),
              ),
              fechaRecepcion: Value(
                _fecha(m['fecha_recepcion']) ?? DateTime.now(),
              ),
              estadoSync: const Value('sincronizado'),
            ),
          );
      return;
    }
    // Fila EXISTENTE: update acotado a lo mutable de HU-143 (total + autoría +
    // reloj + número reconciliado). Los items/nota locales NO se tocan: son la
    // evidencia del evento y una divergencia remota no debe pisarla en silencio.
    await (_db.update(
      _db.recepciones,
    )..where((r) => r.id.equals(recLocal.id))).write(
      RecepcionesCompanion(
        numeroRecepcion: Value((m['numero_recepcion'] as num?)?.toInt() ?? 1),
        totalRecibido: Value(totalRemoto),
        totalEditadoPor: Value(m['total_editado_por'] as String?),
        totalEditadoPorNombre: Value(m['total_editado_por_nombre'] as String?),
        fechaTotalEditado: Value(_fecha(m['fecha_total_editado'])),
        version: Value((m['version'] as num?)?.toInt() ?? 0),
        fechaActualizacion: Value(_fecha(m['updated_at']) ?? DateTime.now()),
        estadoSync: const Value('sincronizado'),
      ),
    );
  }

  /// Pull de un adjunto (#248): baja SOLO METADATOS — `contenido` queda NULL
  /// ("no bajado") y los bytes llegan bajo demanda al abrir el visor. Si el
  /// payload igual trajera `contenido_base64` (un pull viejo, un test), se
  /// decodifica y cachea como antes: gratis no se tira nada.
  Future<void> _upsertAdjunto(Map<String, dynamic> m) async {
    final base64Texto = m['contenido_base64'] as String?;
    // HU-068: sobre un adjunto EXISTENTE lo único que puede llegar del remoto
    // es el resultado del reconocimiento (datos_ocr) escrito en otro
    // dispositivo. Los bytes/tipo (evidencia) siguen append-only y no se tocan.
    final adjLocal = await (_db.select(
      _db.adjuntos,
    )..where((a) => a.id.equals(m['id'] as String))).getSingleOrNull();
    if (adjLocal != null) {
      final ocrRemoto = m['datos_ocr'] as String?;
      if (adjLocal.datosOcr == ocrRemoto) return; // re-pull idéntico: sin ruido
      // Un cambio LOCAL en vuelo (pendiente) no se pisa: el push lo resolverá.
      // La divergencia queda en la bitácora (doctrina HU-028: la evidencia
      // divergente es un conflicto para revisión, no una excusa para pisar).
      if (adjLocal.estadoSync == 'pendiente') {
        await conflictos?.registrar(
          nombreTabla: 'adjuntos',
          registroId: adjLocal.id,
          motivo: MotivoConflicto.pullRechazado,
          negocioId: m['negocio_id'] as String?,
          detalle:
              'datos_ocr local en vuelo difiere del remoto; se conservó el local.',
        );
        return;
      }
      await (_db.update(
        _db.adjuntos,
      )..where((a) => a.id.equals(adjLocal.id))).write(
        AdjuntosCompanion(
          datosOcr: Value(ocrRemoto),
          estadoSync: const Value('sincronizado'),
        ),
      );
      return;
    }
    // HU-028: append-only — el remito/comprobante ya guardado no se sobrescribe.
    if (!await _aplicaRemoto('adjuntos', m)) return;
    await _db
        .into(_db.adjuntos)
        .insertOnConflictUpdate(
          AdjuntosCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            // #238: el padre puede ser la recepción O el pago. El cast es
            // nullable en los dos: un payload viejo sin `pago_id` sigue
            // andando (la clave ausente da null).
            recepcionId: Value(m['recepcion_id'] as String?),
            pagoId: Value(m['pago_id'] as String?),
            nombreArchivo: Value((m['nombre_archivo'] as String?) ?? ''),
            mimeType: Value(
              (m['mime_type'] as String?) ?? 'application/octet-stream',
            ),
            tamanioBytes: Value((m['tamanio_bytes'] as num?)?.toInt() ?? 0),
            contenido: Value(
              base64Texto == null || base64Texto.isEmpty
                  ? null
                  : _codificador.decodificar(base64Texto),
            ),
            tipo: Value((m['tipo'] as String?) ?? TipoAdjunto.remito),
            datosOcr: Value(m['datos_ocr'] as String?),
            fechaCreacion: Value(_fecha(m['created_at']) ?? DateTime.now()),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  /// Wrapper de testing del pull de un adjunto (decode + persistencia), sin Supabase.
  @visibleForTesting
  Future<void> upsertAdjuntoRemoto(Map<String, dynamic> m) => _upsertAdjunto(m);

  /// Wrapper de testing del pull de una recepción (HU-121), sin Supabase.
  @visibleForTesting
  Future<void> upsertRecepcionRemota(Map<String, dynamic> m) =>
      _upsertRecepcion(m);

  // ─── Upserts de tablas FINANCIERAS (HU-082 / C4). Los montos llegan como STRING
  //     (columnas `numeric`, HU-081) → se parsean con Dinero.parsear. ──────────────

  Future<void> _upsertConfiguracion(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('configuracion_negocio', m)) return;

    // #206: el id de esta fila lo acuña el CLIENTE (`obtenerOCrear`, con un
    // uuid v4) cuando el negocio todavía no bajó la suya. Si eso pasó, la fila
    // local tiene un id distinto del que el servidor ya tenía, y `negocio_id`
    // es UNIQUE: el `insertOnConflictUpdate` de abajo resuelve por PK, así que
    // al insertar la fila del servidor choca contra el UNIQUE local y el pull
    // la descarta. Cada vez. Para siempre — el dispositivo nunca más recibía la
    // configuración de su propio negocio, en silencio.
    //
    // Se resuelve por `negocio_id`, que es la identidad REAL de la fila: hay
    // una configuración por negocio, y el id es sólo su clave técnica. La fila
    // local con otro id se borra antes de insertar la del servidor.
    //
    // El cambio local que esa fila pudiera tener en vuelo se pierde, y es lo
    // correcto: su INSERT estaba condenado al dead-letter por el mismo UNIQUE
    // del lado del servidor. Pisar un dato que no se iba a subir nunca es
    // mejor que quedarse sin la configuración del negocio.
    final idRemoto = m['id'] as String;
    final negocioId = m['negocio_id'] as String;
    await (_db.delete(_db.configuracionNegocio)..where(
          (c) => c.negocioId.equals(negocioId) & c.id.equals(idRemoto).not(),
        ))
        .go();

    await _db
        .into(_db.configuracionNegocio)
        .insertOnConflictUpdate(
          ConfiguracionNegocioCompanion(
            id: Value(idRemoto),
            negocioId: Value(negocioId),
            umbralAlertaDesviacion: Value(
              (m['umbral_alerta_desviacion'] as num?)?.toDouble() ??
                  ServicioConfiguracionNegocio.umbralAlertaPorDefecto,
            ),
            moneda: Value((m['moneda'] as String?) ?? 'ARS'),
            simboloMoneda: Value((m['simbolo_moneda'] as String?) ?? '\$'),
            pais: Value((m['pais'] as String?) ?? 'Argentina'),
            idioma: Value((m['idioma'] as String?) ?? 'es'),
            foodcostVerdeMax: Value(
              (m['foodcost_verde_max'] as num?)?.toDouble() ??
                  CalculadoraCostos.umbralVerdePorDefecto,
            ),
            foodcostAmarilloMax: Value(
              (m['foodcost_amarillo_max'] as num?)?.toDouble() ??
                  CalculadoraCostos.umbralAmarilloPorDefecto,
            ),
            // HU-152. `Dinero.parsearNullable` y NO `as num?`: la columna es
            // `numeric` y PostgREST la devuelve como STRING. Con el cast a num el
            // valor daría null EN SILENCIO y el costo por hora nunca bajaría a un
            // segundo dispositivo — la app diría "sin configurar" para siempre.
            // #207: si la clave NO vino (pull operativo, que no la pide), se
            // deja la columna INTACTA en vez de escribirle null. La diferencia
            // importa en un dispositivo que ya la tenía y pasa a operativo —por
            // un cambio de rol— : con `Value(null)` el pull le borraría el costo
            // por hora que el admin había bajado, y la app diría "sin
            // configurar" sin que nadie lo haya cambiado.
            costoHoraEmpleado: m.containsKey('costo_hora_empleado')
                ? Value(Dinero.parsearNullable(m['costo_hora_empleado']))
                : const Value.absent(),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            // HU-028: el reloj del servidor baja al cliente para poder
            // desempatar conflictos (antes nunca se mapeaba).
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertFactura(Map<String, dynamic> m) async {
    // HU-028: financiera — del servidor se acepta la transición de ESTADO
    // (derivada de imputaciones), nunca un cambio de importes. Si los montos
    // divergen, se conserva lo local y queda como conflicto para revisión.
    final localF = await (_db.select(
      _db.facturas,
    )..where((f) => f.id.equals(m['id'] as String))).getSingleOrNull();
    final importesOk =
        localF == null ||
        (Dinero.parsear(m['total_bruto']) == localF.totalBruto &&
            Dinero.parsear(m['total_neto']) == localF.totalNeto);
    if (!await _aplicaRemoto('facturas', m, importesCoinciden: importesOk)) {
      return;
    }
    await _db
        .into(_db.facturas)
        .insertOnConflictUpdate(
          FacturasCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            proveedorId: Value(m['proveedor_id'] as String?),
            pedidoId: Value(m['pedido_id'] as String?),
            recepcionId: Value(m['recepcion_id'] as String?),
            numeroFactura: Value((m['numero_factura'] as String?) ?? ''),
            fechaFactura: Value(_fecha(m['fecha_factura']) ?? DateTime.now()),
            fechaVencimiento: Value(
              _fecha(m['fecha_vencimiento']) ?? DateTime.now(),
            ),
            totalNeto: Value(Dinero.parsear(m['total_neto'])),
            ivaTotal: Value(Dinero.parsear(m['iva_total'])),
            totalBruto: Value(Dinero.parsear(m['total_bruto'])),
            estado: Value((m['estado'] as String?) ?? 'pendiente'),
            comprobanteUrl: Value(m['comprobante_url'] as String?),
            comentario: Value(m['comentario'] as String?),
            creadoPor: Value(m['creado_por'] as String?),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            // HU-028: el reloj del servidor baja al cliente para poder
            // desempatar conflictos (antes nunca se mapeaba).
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertPago(Map<String, dynamic> m) async {
    // HU-028: idem facturas — el monto de un pago no se reescribe desde el pull.
    final localP = await (_db.select(
      _db.pagos,
    )..where((p) => p.id.equals(m['id'] as String))).getSingleOrNull();
    final montoOk =
        localP == null || Dinero.parsear(m['monto']) == localP.monto;
    if (!await _aplicaRemoto('pagos', m, importesCoinciden: montoOk)) return;
    await _db
        .into(_db.pagos)
        .insertOnConflictUpdate(
          PagosCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            proveedorId: Value(m['proveedor_id'] as String),
            monto: Value(Dinero.parsear(m['monto'])),
            metodo: Value((m['metodo'] as String?) ?? 'efectivo'),
            referenciaExterna: Value(m['referencia_externa'] as String?),
            fechaPago: Value(_fecha(m['fecha_pago']) ?? DateTime.now()),
            nota: Value(m['nota'] as String?),
            creadoPor: Value(m['creado_por'] as String?),
            version: Value((m['version'] as num?)?.toInt() ?? 0),
            // HU-028: el reloj del servidor baja al cliente para poder
            // desempatar conflictos (antes nunca se mapeaba).
            fechaActualizacion: Value(
              _fecha(m['updated_at']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertFacturaItem(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('factura_items', m)) return;
    await _db
        .into(_db.facturaItems)
        .insertOnConflictUpdate(
          FacturaItemsCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            facturaId: Value(m['factura_id'] as String),
            insumoId: Value(m['insumo_id'] as String),
            cantidad: Value((m['cantidad'] as num?)?.toDouble() ?? 0.0),
            // `neto_unitario` es numeric(14,2) desde HU-081, y PostgREST
            // serializa numeric como STRING: se parsea con el helper, igual que
            // el resto del dinero. Un `as num` pelado acá rompería el pull
            // entero con un TypeError.
            netoUnitario: Value(Dinero.parsear(m['neto_unitario'])),
            // Sin normalizar la escala a propósito: si bajara un 21 en vez de
            // un 0.21 es un dato MAL escrito del otro lado, y taparlo acá
            // dejaría el error vivo en el servidor y en cualquier otro cliente.
            // `esAlicuotaValida` es el control, y va donde se lee.
            alicuota: Value((m['alicuota'] as num?)?.toDouble() ?? 0.21),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertImputacion(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('imputaciones_pago', m)) return;
    await _db
        .into(_db.imputacionesPago)
        .insertOnConflictUpdate(
          ImputacionesPagoCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            pagoId: Value(m['pago_id'] as String),
            facturaId: Value(m['factura_id'] as String),
            montoImputado: Value(Dinero.parsear(m['monto_imputado'])),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertMovimiento(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('movimientos_cuenta_corriente', m)) return;
    await _db
        .into(_db.movimientosCuentaCorriente)
        .insertOnConflictUpdate(
          MovimientosCuentaCorrienteCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            proveedorId: Value(m['proveedor_id'] as String),
            tipoMovimiento: Value(
              (m['tipo_movimiento'] as String?) ?? 'ajuste',
            ),
            monto: Value(Dinero.parsear(m['monto'])),
            saldo: Value(Dinero.parsear(m['saldo'])),
            referenciaId: Value(m['referencia_id'] as String?),
            descripcion: Value(m['descripcion'] as String?),
            fechaMovimiento: Value(
              _fecha(m['fecha_movimiento']) ?? DateTime.now(),
            ),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  Future<void> _upsertHistorialPrecio(Map<String, dynamic> m) async {
    if (!await _aplicaRemoto('historial_precios', m)) return;
    await _db
        .into(_db.historialPrecios)
        .insertOnConflictUpdate(
          HistorialPreciosCompanion(
            id: Value(m['id'] as String),
            negocioId: Value(m['negocio_id'] as String),
            insumoId: Value(m['insumo_id'] as String),
            proveedorId: Value(m['proveedor_id'] as String?),
            usuarioId: Value(m['usuario_id'] as String?),
            fechaRegistro: Value(_fecha(m['fecha_registro']) ?? DateTime.now()),
            precioUnitarioNeto: Value(
              Dinero.parsear(m['precio_unitario_neto']),
            ),
            ivaPorcentaje: Value(
              (m['iva_porcentaje'] as num?)?.toDouble() ?? 0.21,
            ),
            origen: Value((m['origen'] as String?) ?? 'ajuste_manual'),
            referenciaId: Value(m['referencia_id'] as String?),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  /// Wrappers de testing de los upserts financieros (sin Supabase): permiten verificar
  /// que los montos `numeric` (String desde PostgREST) aterrizan exactos (HU-082).
  @visibleForTesting
  Future<void> upsertFacturaRemota(Map<String, dynamic> m) => _upsertFactura(m);
  @visibleForTesting
  Future<void> upsertMovimientoRemoto(Map<String, dynamic> m) =>
      _upsertMovimiento(m);
  @visibleForTesting
  Future<void> upsertPagoRemoto(Map<String, dynamic> m) => _upsertPago(m);

  /// Parsea una fecha ISO-8601 remota; devuelve null si no es válida.
  DateTime? _fecha(dynamic valor) =>
      valor is String ? DateTime.tryParse(valor) : null;
}
