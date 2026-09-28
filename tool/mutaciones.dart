/// Catálogo de mutaciones: cada entrada rompe un arreglo a propósito y declara
/// qué test TIENE que fallar cuando eso pasa.
///
/// ## Por qué existe
///
/// Tres veces seguidas en este proyecto se escribió un test que probaba **el
/// arreglo** en vez de **el escenario**, y que daba verde con el bug puesto:
///
///  - se escribía `estado_sync: 'pendiente'` a mano en el fixture, un estado
///    que el flujo real de la app nunca produce (A-03);
///  - el "servidor que corta la conexión" hacía `response.close()`, que sin
///    tocar `statusCode` manda un **200 con cuerpo vacío**: el ítem subía bien
///    y nunca se llegaba a la rama que el test decía cubrir (C-02);
///  - el control de la guarda del pull cortaba el cuerpo de la función en el
///    lugar equivocado y reportaba como guardados dos upserts que no lo estaban.
///
/// El patrón es siempre el mismo: **el fixture no produce el estado que el test
/// afirma reproducir**. Un test así no es inútil, es peor: dice que algo está
/// cubierto cuando no lo está, y de eso nadie se entera hasta que el bug vuelve.
///
/// La verificación que lo caza —revertir el arreglo y mirar que el test falle—
/// se venía haciendo a mano y sólo cuando alguien se acordaba. Acá deja de
/// depender de que alguien se acuerde: `dart run tool/verificar_mutaciones.dart`
/// lo hace, y el CI lo corre.
///
/// ## Cómo agregar una
///
/// Cuando arregles un bug real, agregá acá la mutación que lo reintroduce. Si
/// no podés escribir una mutación de una o dos líneas que revierta tu arreglo,
/// probablemente el arreglo no esté localizado y valga la pena repensarlo.
library;

import 'dart:io';

/// Un arreglo roto a propósito, y el test que tiene que detectarlo.
class Mutacion {
  /// Nombre corto, sale en la salida del runner.
  final String nombre;

  /// Ruta relativa a `insuma/`.
  final String archivo;

  /// Texto a reemplazar. **Tiene que aparecer exactamente una vez**: si aparece
  /// cero veces el arreglo se movió y la mutación quedó obsoleta (el runner
  /// falla); si aparece varias, la mutación es ambigua.
  final String buscar;

  /// Con qué se reemplaza, para reintroducir el bug.
  final String reemplazar;

  /// Archivo de test que DEBE fallar con la mutación aplicada.
  final String test;

  /// Qué bug reintroduce. Sale en el mensaje de error, así que escribilo para
  /// alguien que no tiene el contexto.
  final String porque;

  const Mutacion({
    required this.nombre,
    required this.archivo,
    required this.buscar,
    required this.reemplazar,
    required this.test,
    required this.porque,
  });
}

/// Revisa que el ancla de [m] siga siendo válida, SIN correr ningún test.
///
/// Devuelve `null` si está sana, o el motivo si no. Es la mitad barata del
/// control: un ancla que ya no matchea significa que el arreglo se movió y la
/// mutación no está verificando nada, y eso se puede saber leyendo archivos,
/// en milisegundos, sin las 108 corridas de `flutter test` que cuestan 9
/// minutos.
///
/// Vive acá y no dentro del runner para que el test de la suite
/// (`test/mutaciones_vigentes_test.dart`) use EXACTAMENTE la misma lógica: si
/// se duplicara, el test podría dar verde con anclas que el runner rechaza.
///
/// [raiz] permite correrlo desde otro directorio de trabajo; por defecto
/// resuelve relativo al actual, que es `insuma/` tanto para el runner como
/// para `flutter test`.
String? revisarAncla(Mutacion m, {String raiz = ''}) {
  final archivo = File(raiz.isEmpty ? m.archivo : '$raiz/${m.archivo}');
  if (!archivo.existsSync()) {
    return '${m.nombre}: no existe ${m.archivo}';
  }
  final original = archivo.readAsStringSync();

  // Las anclas se escriben con saltos LF en el catálogo, pero los fuentes de
  // este repo están en CRLF en Windows. Sin traducir, cualquier ancla de más de
  // una línea no matchea nunca y se reporta como "obsoleta" con el arreglo
  // intacto. Ver el comentario largo del runner: el diagnóstico engaña en las
  // dos direcciones, porque en un CI Linux (LF) esas mismas anclas funcionan.
  final buscar = original.contains('\r\n')
      ? m.buscar.replaceAll('\n', '\r\n')
      : m.buscar;

  final apariciones = buscar.allMatches(original).length;
  if (apariciones != 1) {
    return '${m.nombre}: el ancla aparece $apariciones veces en ${m.archivo} '
        '(tiene que ser exactamente 1). La mutación quedó obsoleta: '
        'actualizala en tool/mutaciones.dart.';
  }
  return null;
}

const mutaciones = <Mutacion>[
  // ── C-02 · reintentos y drenaje del Outbox ────────────────────────────────
  Mutacion(
    nombre: 'c02-fallo-de-red-gasta-intento',
    archivo: 'lib/services/politica_reintentos.dart',
    buscar: '    if (error is! PostgrestException) return false;',
    reemplazar: '    if (error is! PostgrestException) return true;',
    test: 'test/c02_drenaje_real_test.dart',
    porque:
        'Un fallo de red vuelve a gastar intentos. Ocho ediciones offline '
        'seguidas mandan la primera mutación a dead-letter antes de que haya '
        'existido una sola chance de subirla.',
  ),
  Mutacion(
    nombre: 'c02-5xx-de-postgrest-gasta-intento',
    archivo: 'lib/services/politica_reintentos.dart',
    buscar: "      final c? when c.startsWith('08') || c.startsWith('53') =>",
    reemplazar:
        "      final c? when c.startsWith('~~') || c.startsWith('~~') =>",
    test: 'test/c02_drenaje_real_test.dart',
    porque:
        'El pool de conexiones saturado (53300) vuelve a contar como rechazo '
        'definitivo: veinte minutos de eso mandan toda la cola a dead-letter.',
  ),
  Mutacion(
    nombre: 'c02-push-sin-timeout',
    archivo: 'lib/services/servicio_sincronizacion_supabase.dart',
    buscar:
        '                  .upsert(datos)\n'
        '                  .timeout(tiempoLimitePush);',
    reemplazar: '                  .upsert(datos);',
    test: 'test/c02_drenaje_real_test.dart',
    porque:
        'Un servidor que acepta y nunca contesta vuelve a colgar el drenaje: '
        '`_sincronizando` queda en true de por vida y la app no sincroniza '
        'más hasta que la reinicien.',
  ),
  Mutacion(
    nombre: 'c02-accion-desconocida-sin-dead-letter',
    archivo: 'lib/services/servicio_sincronizacion_supabase.dart',
    buscar: '              rechazoDefinitivo = true;\n              error = ',
    reemplazar:
        '              rechazoDefinitivo = false;\n              error = ',
    test: 'test/c02_drenaje_real_test.dart',
    porque:
        'Una acción que el switch no conoce vuelve a quedarse encolada para '
        'siempre, sin gastar intentos y sin llegar nunca a dead-letter.',
  ),
  Mutacion(
    nombre: 'c02-drenaje-sin-backoff',
    archivo: 'lib/services/servicio_sincronizacion_supabase.dart',
    buscar:
        '                  (t.fechaProximoIntento.isNull() |\n'
        '                      t.fechaProximoIntento.isSmallerOrEqualValue(ahora)),',
    reemplazar: '                  const Constant(true),',
    test: 'test/c02_reintentos_offline_test.dart',
    porque:
        'El drenaje deja de mirar `fechaProximoIntento`, así que el backoff '
        'pasa a ser decorativo: el ítem vuelve a salir en el drenaje '
        'siguiente, que dispara con cada mutación local.',
  ),
  Mutacion(
    nombre: 'c02-tope-de-tiempo-inutil-en-produccion',
    archivo: 'lib/services/servicio_sincronizacion_supabase.dart',
    buscar:
        '  static const Duration tiempoLimitePushPorDefecto = Duration(seconds: 30);',
    reemplazar:
        '  static const Duration tiempoLimitePushPorDefecto = Duration(days: 3650);',
    test: 'test/c02_drenaje_real_test.dart',
    porque:
        'El tope existe pero es inservible. El test inyecta el suyo para no '
        'esperar 30s, asi que sin una afirmacion sobre el valor POR DEFECTO '
        'nadie nota que produccion se quedo sin tope.',
  ),

  // ── #229 · el camino de pago en efectivo ──────────────────────────────────
  //
  // Este camino no tenia una sola prueba hasta #229: `pagarEfectivo: true`
  // aparecia dos veces en todo `test/` y `tieneEfectivo: true`, ninguna. Las
  // mutaciones de abajo existen para que la red nueva no sea decorativa.
  Mutacion(
    nombre: '229-vuelve-el-salto-a-facturado',
    archivo: 'lib/services/servicio_recepciones.dart',
    buscar: '      final estadoFinal = estadoElegido;',
    reemplazar:
        "      final estadoFinal = pagarEfectivo ? 'facturado' : estadoElegido;",
    test: 'test/pago_efectivo_test.dart',
    porque:
        'Reintroduce RN-014 (que #229 elimino): el efectivo vuelve a saltar a '
        'facturado al recibir, se saltea Procesar y la compra queda sin costos '
        'ni pago asentado — el bug original entero, de una linea.',
  ),
  Mutacion(
    nombre: '229-lo-decidido-al-recibir-no-se-persiste',
    archivo: 'lib/services/servicio_recepciones.dart',
    buscar: '          tieneEfectivo: Value(pagarEfectivo),',
    reemplazar: '          tieneEfectivo: const Value.absent(),',
    test: 'test/pago_efectivo_test.dart',
    porque:
        'El write-back del flag parece redundante y es la costura del '
        'destildado de #229. Sin el, destildar al recibir no queda guardado: '
        'la pantalla muestra el switch apagado y la base sigue diciendo que '
        'si. Falla en silencio.',
  ),
  Mutacion(
    nombre: '229-el-efectivo-historico-inunda-pagos',
    archivo: 'lib/services/servicio_recepciones_admin.dart',
    buscar:
        '      if (pedido.tieneEfectivo &&\n'
        '          (pedido.estado == EstadosPedido.facturado ||\n'
        '              pedido.estado == EstadosPedido.pagado)) {\n'
        '        continue;\n'
        '      }',
    reemplazar: '      // (filtro de historicos removido por la mutacion)',
    test: 'test/pago_efectivo_test.dart',
    porque:
        'Todos los pedidos en efectivo cerrados por el flujo viejo aparecen de '
        'golpe en "Recepciones por procesar" pidiendo costos — meses de '
        'compras que el PO dio por procesadas. El primer deploy le tira esa '
        'lista entera al admin.',
  ),
  Mutacion(
    nombre: '229-procesar-deja-de-costear',
    archivo: 'lib/services/servicio_procesar_recepcion.dart',
    buscar: '        await _precios.registrar(',
    reemplazar: '        if (lineas.isEmpty) await _precios.registrar(',
    test: 'test/servicio_procesar_recepcion_test.dart',
    porque:
        'El UNICO costeo que queda (el de Procesar) deja de correr y el '
        'FoodCost se congela. NO falla: un insumo sin historial y con cache en '
        '0 aporta CERO al costo de la receta, asi que el numero sub-reporta y '
        'la pantalla se ve perfecta. Es el modo de falla mas peligroso de #229.',
  ),
  Mutacion(
    nombre: '229-el-costeo-queda-cableado-dos-veces',
    archivo: 'lib/services/servicio_procesar_recepcion.dart',
    // Seis espacios A PROPOSITO: el bucle de VALIDACION del mismo metodo es
    // `    for (final l in lineas) {` con cuatro, y con el prefijo mas corto
    // el ancla matchearia los dos.
    buscar: '      for (final l in lineas) {',
    reemplazar: '      for (final l in [...lineas, ...lineas]) {',
    test: 'test/servicio_procesar_recepcion_test.dart',
    porque:
        'Cada procesamiento deja DOS filas de precio por insumo — lo que '
        'pasaria si alguien reconectara un costeo en la recepcion ademas del '
        'de Procesar. `registrarPrecioInsumo` no tiene idempotencia por '
        '`referenciaId`, el guard de HU-138 protege el ORDEN y no los '
        'duplicados, y si el precio repetido es igual la desviacion da 0: sin '
        'el invariante, el doble conteo no tiene un solo sintoma.',
  ),
  Mutacion(
    nombre: '229-la-agenda-no-hereda-el-efectivo',
    archivo: 'lib/services/servicio_pedidos_recurrentes.dart',
    buscar: '          tieneEfectivo: agenda.tieneEfectivo,',
    reemplazar: '          tieneEfectivo: false,',
    test: 'test/servicio_pedidos_recurrentes_test.dart',
    porque:
        'Las entregas de una agenda en efectivo nacen SIN el flag, asi que a '
        'quien recibe no le avisa nadie que tiene que llevar plata. Es la '
        'fuente de efectivo que no se decide a mano y por eso la que menos se '
        'mira.',
  ),

  // ── #229 · el service de procesar recepción ───────────────────────────────
  Mutacion(
    nombre: '229-el-pago-queda-sin-imputar',
    archivo: 'lib/services/servicio_procesar_recepcion.dart',
    buscar:
        '          imputaciones: [SolicitudImputacion(factura.id, totalBruto)],',
    reemplazar: '          imputaciones: const [],',
    test: 'test/servicio_procesar_recepcion_test.dart',
    porque:
        'El pago en efectivo entra a la cuenta corriente pero no se aplica a '
        'su factura: la factura queda "pendiente" eternamente, el saldo del '
        'proveedor da negativo (como si hubiera anticipo) y el pedido nunca '
        'llega a pagado. Todo con numeros que parecen razonables.',
  ),
  Mutacion(
    nombre: '229-el-costeo-pierde-la-trazabilidad',
    archivo: 'lib/services/servicio_procesar_recepcion.dart',
    buscar: '          referenciaId: recepcionId,',
    reemplazar: '          referenciaId: factura.id,',
    test: 'test/servicio_procesar_recepcion_test.dart',
    porque:
        'El precio queda ligado a la factura en vez de a la recepcion que lo '
        'origino. Se rompe la trazabilidad historica Y el invariante '
        'anti-doble-conteo ("una recepcion deja a lo sumo una fila por insumo '
        'con su referenciaId"), que es lo unico que delataria al bucle viejo '
        'si alguien lo reconectara.',
  ),
  Mutacion(
    nombre: '229-el-pedido-nunca-llega-a-pagado',
    archivo: 'lib/services/servicio_procesar_recepcion.dart',
    buscar:
        '          final marcarPagado =\n'
        '              pago != null &&\n'
        '              TransicionesPedido.puede(ped.estado, EstadosPedido.pagado);',
    reemplazar: '          final marcarPagado = false;',
    test: 'test/servicio_procesar_recepcion_test.dart',
    porque:
        'La transicion facturado -> pagado vuelve a ser letra muerta: el '
        'pedido en efectivo muere en "facturado" y el chip del historial '
        'vuelve a mentir, que es el sintoma que el PO reporto originalmente.',
  ),
  Mutacion(
    nombre: '229-los-parciales-se-marcan-facturados-antes-de-tiempo',
    archivo: 'lib/services/servicio_procesar_recepcion.dart',
    buscar: '        marcarPedidoFacturado: marcarPedidoFacturado,',
    reemplazar: '        marcarPedidoFacturado: true,',
    test: 'test/servicio_procesar_recepcion_test.dart',
    porque:
        'Procesar la PRIMERA recepcion parcial marca el pedido facturado: la '
        'segunda queda excluida de "Recepciones por procesar" para siempre '
        '(el filtro de historicos la lee como efectivo viejo) y esa entrega '
        'no se costea ni se asienta nunca.',
  ),
  Mutacion(
    nombre: '229-la-traza-ocr-se-aplana',
    archivo: 'lib/services/servicio_procesar_recepcion.dart',
    buscar: '          origen: origenPorInsumo[l.insumoId] ?? origenPrecio,',
    reemplazar: '          origen: origenPrecio,',
    test: 'test/controlador_procesar_recepcion_test.dart',
    porque:
        'La traza de HU-144 vuelve a ser un solo origen por compra: la linea '
        'sugerida por el escaneo y la cargada a mano quedan indistinguibles '
        'en el historial, y la trazabilidad por renglon que trajo #229 se '
        'pierde sin que ningun numero cambie.',
  ),

  // ── #227 · el adjunto que se descartaba en silencio ───────────────────────
  Mutacion(
    nombre: '227-el-adjunto-no-revierte-la-recepcion',
    archivo: 'lib/services/servicio_recepciones.dart',
    buscar: '      await adjuntarEnTransaccion?.call(evento.id);',
    reemplazar:
        '      try { await adjuntarEnTransaccion?.call(evento.id); } catch (_) {}',
    test: 'test/adjunto_que_falla_test.dart',
    porque:
        'Vuelve el bug entero: el comprobante que no se puede guardar se traga '
        'y la recepcion queda registrada igual, con su monto llegando a Pagos '
        'y sin un papel que la respalde. Nadie se entera nunca — es la forma '
        'exacta que tenia #227.',
  ),
  Mutacion(
    nombre: '227-la-compresion-vuelve-adentro-de-la-transaccion',
    archivo: 'lib/controllers/controlador_recibir.dart',
    buscar: '      final errorAdjunto = await adjuntos.prepararTodo();',
    reemplazar: '      const String? errorAdjunto = null;',
    test: 'test/adjunto_que_falla_test.dart',
    porque:
        'Sin el pre-flight, validar y comprimir vuelven adentro de la '
        'transaccion: un archivo que la revalidacion post-compresion rechaza '
        'hace fracasar el registro de una entrega fisica que YA ocurrio, y de '
        'paso sostiene el unico escritor de SQLite mientras comprime.',
  ),
  Mutacion(
    nombre: '227-persistir-sin-preparar-pasa-desapercibido',
    archivo: 'lib/controllers/controlador_adjuntos.dart',
    buscar: '    if (_preparados.length != _pendientes.length) {',
    reemplazar: '    if (false) {',
    test: 'test/adjunto_que_falla_test.dart',
    porque:
        'La guarda que obliga a preparar antes de persistir deja de existir: '
        'un llamador nuevo que se olvide del pre-flight escribe cero adjuntos '
        'sin una sola señal, porque el bucle recorre una lista vacia.',
  ),

  // ── #223 / #206 · el dispositivo que deja de recibir novedades ────────────
  Mutacion(
    nombre: '223-descartar-la-cola-deja-las-filas-trabadas',
    archivo: 'lib/data/repositorios/descartador_cola_drift.dart',
    buscar: '    await liberarFilasDeMutaciones(_db, items);',
    reemplazar: '    // (liberacion removida por la mutacion)',
    test: 'test/sync_que_no_vuelve_test.dart',
    porque:
        'Reconciliar el tenant borra la cola y deja las filas marcadas para '
        'subir SIN nada que subir. Desde ese momento cada una rechaza todo lo '
        'que baje del servidor, para siempre y sin avisar: dos dispositivos '
        'del mismo negocio muestran datos distintos y nadie se entera.',
  ),
  Mutacion(
    nombre: '223-el-reparador-libera-de-mas',
    archivo: 'lib/data/liberacion_pendientes.dart',
    buscar:
        "          if (!(vivas[tabla]?.contains(fila.read<String>('id')) ?? false))",
    reemplazar: '          if (true)',
    test: 'test/sync_que_no_vuelve_test.dart',
    porque:
        'El reparador deja de mirar si hay una mutacion viva y suelta TODAS '
        'las filas pendientes, incluidas las que tienen un cambio real '
        'esperando subir. El proximo pull les pisa el dato del usuario antes '
        'de que llegue a viajar.',
  ),

  // ── #215 · los desbordes a ancho de telefono ──────────────────────────────
  Mutacion(
    nombre: '215-los-tests-dejan-de-medir-a-ancho-de-telefono',
    archivo: 'test/helpers/ancho_telefono.dart',
    buscar: '  tester.view.physicalSize = tamano;',
    reemplazar: '  // (el ancho no se fija: la mutacion)',
    test: 'test/helpers/ancho_telefono_test.dart',
    porque:
        'Todo el barrido de #215 se vuelve decorativo de una sola linea: los '
        'tests montan al default de flutter_test (800x600, mas parecido a una '
        'tablet que a un telefono), donde TODO entra. Es exactamente como '
        'cuatro pantallas llegaron a produccion desbordando sin que un solo '
        'test lo notara.',
  ),
  Mutacion(
    nombre: '215-la-card-de-receta-vuelve-a-atarse-al-ancho',
    archivo: 'lib/screens/recetas_tab.dart',
    buscar: '        mainAxisExtent: 132,',
    reemplazar: '        childAspectRatio: 2.8,',
    test: 'test/recetario_operativo_test.dart',
    porque:
        'El alto del tile vuelve a depender del ancho de la pantalla: a 360 dp '
        'da ~120 px contra los ~124 que el contenido necesita y la card corta '
        'su ultima linea. Con la ventana ancha de Chrome sobra lugar y no se '
        've.',
  ),

  // ── #207 · la configuracion que no llegaba al cocinero ────────────────────
  Mutacion(
    nombre: '207-el-cocinero-recibe-el-dato-salarial',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    buscar:
        "    'pais,idioma,foodcost_verde_max,foodcost_amarillo_max,version,updated_at';",
    reemplazar:
        "    'pais,idioma,foodcost_verde_max,foodcost_amarillo_max,version,updated_at,costo_hora_empleado';",
    test: 'test/configuracion_al_cocinero_test.dart',
    porque:
        'El costo por hora de los empleados empieza a viajar al dispositivo '
        'del cocinero, que no lo necesita (no ve costos de receta). Es la '
        'linea que decide que ve cada rol.',
  ),
  Mutacion(
    nombre: '207-el-pull-operativo-borra-el-costo-por-hora',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    buscar:
        "            costoHoraEmpleado: m.containsKey('costo_hora_empleado')",
    reemplazar: '            costoHoraEmpleado: true',
    test: 'test/configuracion_al_cocinero_test.dart',
    porque:
        'La columna ausente pasa a escribirse como null en vez de dejarse '
        'intacta: un dispositivo que ya tenia el costo por hora y pasa a '
        'operativo —por un cambio de rol— lo pierde, y la app dice "sin '
        'configurar" sin que nadie lo haya cambiado.',
  ),

  // ── #233 · el "Últ. compra" de la ficha del proveedor ─────────────────────
  Mutacion(
    nombre: '233-ultimo-costo-cruza-proveedores',
    // #242 movió la autoridad a factura_items: el ancla la sigue.
    archivo: 'lib/data/repositorios/repositorio_factura_items.dart',
    buscar: '        db.facturas.proveedorId.equals(proveedorId) &',
    reemplazar: '        db.facturas.proveedorId.isNotNull() &',
    test: 'test/ultimo_costo_ingreso_test.dart',
    porque:
        'El "Últ. compra" de la ficha deja de filtrar por proveedor: lo que '
        'entrego OTRO proveedor aparece como si ESTE lo hubiera cobrado, y el '
        'que mira la ficha negocia precios contra un numero que ese proveedor '
        'jamas facturo.',
  ),

  // ── #242 · "Últ. compra" real desde factura_items ─────────────────────────
  Mutacion(
    nombre: '242-ult-compra-cuenta-anuladas',
    archivo: 'lib/data/repositorios/repositorio_factura_items.dart',
    buscar:
        "          ..where(db.facturas.estado.equals('anulada').not() & donde)",
    reemplazar: '          ..where(donde)',
    test: 'test/ultimo_costo_ingreso_test.dart',
    porque:
        'Una factura ANULADA vuelve a contar como ultima compra: el numero '
        'que se anulo justamente porque no valia queda como referencia para '
        'negociar precios.',
  ),
  Mutacion(
    nombre: '242-ult-compra-ordena-por-carga',
    archivo: 'lib/data/repositorios/repositorio_factura_items.dart',
    buscar: '            OrderingTerm.desc(db.facturas.fechaFactura),',
    reemplazar: '            OrderingTerm.desc(db.facturaItems.fechaCreacion),',
    test: 'test/ultimo_costo_ingreso_test.dart',
    porque:
        'Vuelve el bug de fondo de #242: procesar una recepcion ATRASADA '
        'despues de una nueva convierte la compra vieja en "Ult. compra", '
        'porque gana la ultima CARGADA y no la ultima ENTREGADA.',
  ),
  Mutacion(
    nombre: '242-la-ficha-pierde-la-ultima-compra',
    archivo: 'lib/services/servicio_precios.dart',
    buscar:
        '  }) async => (await _itemsReales.ultimosIngresosPorInsumo(\n'
        '    proveedorId: proveedorId,\n'
        '    insumosIds: insumosIds,\n'
        '  )).map((id, ingreso) => MapEntry(id, ingreso.precio));',
    reemplazar: '  }) async => const <String, double>{};',
    test: 'test/ultimo_costo_ingreso_test.dart',
    porque:
        'La delegacion a la autoridad real desaparece y la ficha muestra "—" '
        'para absolutamente todo: el dato de referencia de #233 muere en '
        'silencio.',
  ),

  Mutacion(
    nombre: '242-detalle-vende-estimado-como-real',
    archivo: 'lib/screens/recibir/acciones_pedido_mixin.dart',
    buscar: "                    final real = costosReales[item['insumoId']];",
    reemplazar: '                    final double? real = null;',
    test: 'test/detalle_pedido_costo_real_test.dart',
    porque:
        'El detalle del pedido vuelve a mostrar SIEMPRE la estimacion de al '
        'crear el pedido presentada como costo — el reporte textual del PO '
        'en #242.',
  ),

  // ── #248 · el pull baja metadatos; los bytes llegan bajo demanda ──────────
  Mutacion(
    nombre: '248-el-pull-vuelve-a-bajar-las-fotos',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    buscar: '        columnas: columnasMetadatosAdjuntos,',
    reemplazar: '        columnas: null,',
    // #249: el test de costura de servicio_descarga_adjunto_test mira la
    // CONSTANTE y esta mutación la deja intacta (anula el call site) — la
    // caza el test de orquestación, que mira la URL que sale de verdad.
    test: 'test/pull_respeta_padres_caidos_test.dart',
    porque:
        'El pull de adjuntos vuelve al select(*): la foto completa de todo '
        'el historial viaja de nuevo en cada apertura — los minutos de '
        'espera y la pestana congelada del reporte del cliente.',
  ),
  Mutacion(
    nombre: '248-la-primera-vista-no-cachea',
    archivo: 'lib/services/backend_adjuntos.dart',
    buscar: '    await _repo.guardarContenido(adjuntoId, bytes);',
    reemplazar: '    // (cacheo saltado)',
    test: 'test/adjunto_bajo_demanda_test.dart',
    porque:
        'Cada vista de la misma foto vuelve a viajar al servidor, y offline '
        'no se ve NINGUNA foto ajena aunque ya se haya abierto mil veces: '
        'el "queda cacheada" del contrato se vuelve mentira.',
  ),
  Mutacion(
    nombre: '248-el-cache-local-se-ignora',
    archivo: 'lib/services/backend_adjuntos.dart',
    buscar: '    if (locales != null) return locales;',
    reemplazar: '    if (locales != null && locales.isEmpty) return locales;',
    test: 'test/adjunto_bajo_demanda_test.dart',
    porque:
        'Hasta lo adjuntado EN este dispositivo pasa a pedirse por red: '
        'offline no se abre ni el remito que el cocinero acaba de sacar con '
        'su propia camara.',
  ),

  // ── #246 · el superadmin entra ya y el pull corre atrás ───────────────────
  Mutacion(
    nombre: '246-el-superadmin-vuelve-a-esperar-el-pull',
    archivo: 'lib/screens/superadmin_screen.dart',
    buscar: '      unawaited(_descargarEnSegundoPlano(negocio));',
    reemplazar: '      await _descargarEnSegundoPlano(negocio);',
    test: 'test/superadmin_entra_sin_esperar_test.dart',
    porque:
        'Reintroduce el bug del reporte del cliente tal cual: tocar un '
        'negocio vuelve a esperar el pull completo (19 tablas, sin timeout) '
        'antes de entrar — minutos de spinner en el celular.',
  ),

  // ── #249 · el pull respeta la cadena de FK y cuenta sus descartes ─────────
  Mutacion(
    nombre: '249-las-recepciones-se-bajan-sin-pedidos',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    // #250: el pull pasó a `_pullIncremental`; se re-ancla la condición del
    // gate. `false` en vez de `!pedidosOk` fuerza siempre la rama que baja
    // recepciones, aunque pedidos haya caído — el bug de vuelta.
    buscar:
        '    final recepcionesOk = !pedidosOk\n'
        "        ? _saltearPorPadreCaido('recepciones', 'pedidos')",
    reemplazar:
        '    final recepcionesOk = false\n'
        "        ? _saltearPorPadreCaido('recepciones', 'pedidos')",
    test: 'test/pull_respeta_padres_caidos_test.dart',
    porque:
        'Con `pedidos` caído (red, RLS) las recepciones vuelven a bajarse '
        'igual: cada fila revienta la FOREIGN KEY local y se descarta en '
        'silencio — la mecánica exacta del bug de #247 en la demo.',
  ),
  Mutacion(
    nombre: '249-los-adjuntos-se-piden-sin-recepciones',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    buscar: '    if (!recepcionesOk) {',
    reemplazar: '    if (!recepcionesOk && pedidosOk && false) {',
    test: 'test/pull_respeta_padres_caidos_test.dart',
    porque:
        'Los adjuntos vuelven a pedirse aunque las recepciones no hayan '
        'llegado: requests gastados para filas que la FK local va a rechazar '
        'una por una.',
  ),
  Mutacion(
    nombre: '249-el-salteo-finge-exito',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    buscar:
        "      'Se reintenta completa en el próximo pull.',\n"
        '    );\n'
        '    return false;',
    reemplazar:
        "      'Se reintenta completa en el próximo pull.',\n"
        '    );\n'
        '    return true;',
    test: 'test/pull_respeta_padres_caidos_test.dart',
    porque:
        'Una tabla SALTEADA vuelve a contar como bajada: sus hijas se piden '
        'igual y HU-090 marca el primer pull como completo con datos que a '
        'sabiendas faltan — saldos y anticipos derivados con agujeros.',
  ),
  Mutacion(
    nombre: '249-el-descarte-vuelve-a-ser-invisible',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    buscar:
        '      filasOmitidasUltimoPull[tabla] =\n'
        '          (filasOmitidasUltimoPull[tabla] ?? 0) + omitidas;',
    reemplazar: '      // filas omitidas sin contar (mutación #249)',
    test: 'test/pull_respeta_padres_caidos_test.dart',
    porque:
        'Las filas descartadas del pull vuelven a perderse en debugPrints '
        'sueltos que nadie mira: la próxima asimetría tipo #247 pasa otra '
        'vez inadvertida durante días.',
  ),

  // ── #250 · pull incremental con cursor ────────────────────────────────────
  Mutacion(
    nombre: '250-el-cursor-no-filtra',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    buscar: '        if (columnaCursor != null && cursorDesde != null) {',
    reemplazar:
        '        if (false && columnaCursor != null && cursorDesde != null) {',
    test: 'test/pull_incremental_cursor_test.dart',
    porque:
        'El filtro incremental deja de aplicarse: cada pull vuelve a bajar '
        'TODAS las filas de todas las tablas en cada entrada al negocio — el '
        'derroche que #250 existía para eliminar, ahora sin síntoma visible.',
  ),
  Mutacion(
    nombre: '250-el-cursor-avanza-con-filas-omitidas',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    buscar:
        '    final confiable = r.llego && (filasOmitidasUltimoPull[tabla] ?? 0) == 0;',
    reemplazar: '    final confiable = r.llego;',
    test: 'test/pull_incremental_cursor_test.dart',
    porque:
        'El cursor avanza aunque una fila se haya OMITIDO (FK rota): esa fila '
        'queda por debajo del cursor y NO se vuelve a pedir nunca — pérdida '
        'silenciosa y permanente, el peor modo de falla del incremental.',
  ),
  Mutacion(
    nombre: '250-el-cursor-no-calcula-la-marca',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    buscar:
        '    if (columna == null) return null;\n'
        '    DateTime? maximo;',
    reemplazar:
        '    if (columna == null) return null;\n'
        '    DateTime? maximo;\n'
        '    return maximo; // marca siempre null (mutación #250)',
    test: 'test/pull_incremental_cursor_test.dart',
    porque:
        'La alta-marca queda siempre en null, así que el cursor nunca se '
        'guarda: el incremental degrada a pull completo permanente sin avisar.',
  ),

  // ── #244 · los comprobantes del efectivo llegan al clip del pago ──────────
  Mutacion(
    nombre: '244-el-clip-del-pago-ciego-al-efectivo',
    archivo: 'lib/services/servicio_adjuntos.dart',
    buscar: '      _backend.listarComprobantesDeRecepcionesDelPago(pagoId),',
    // El fake y el backend ignorarian un id mutado: se duplica la otra fuente.
    reemplazar: '      _backend.listarComprobantesPorPago(pagoId),',
    test: 'test/comprobante_efectivo_en_clip_test.dart',
    porque:
        'El clip del movimiento del pago vuelve a decir "no hay comprobante" '
        'para TODO pago en efectivo: el papel cuelga de la recepcion y sin el '
        'puente inverso nadie lo va a buscar ahi.',
  ),

  Mutacion(
    nombre: '244-documentos-esconde-lo-historico',
    archivo: 'lib/services/servicio_adjuntos.dart',
    buscar:
        '      _backend.listarPorRecepcion(recepcionId),\n'
        '      _backend.listarFacturasPorRecepcion(recepcionId),\n'
        '      _backend.listarComprobantesPorRecepcion(recepcionId),',
    reemplazar:
        '      _backend.listarPorRecepcion(recepcionId),\n'
        '      _backend.listarFacturasPorRecepcion(recepcionId),\n'
        '      _backend.listarFacturasPorRecepcion(recepcionId),',
    test: 'test/servicio_adjuntos_documentos_test.dart',
    porque:
        'El boton "Documentos" vuelve a esconder los comprobantes de la '
        'entrega: las facturas del wizard viejo (etiquetadas comprobante) y '
        'el papel del efectivo desaparecen justo donde se los busca al pagar.',
  ),
  Mutacion(
    nombre: '244-el-clip-ignora-el-rol',
    archivo: 'lib/services/servicio_adjuntos.dart',
    buscar:
        '      case ContextoAdjuntos.comprobantesDelPago:\n'
        '        if (!puedeVerFinanzas) return Future.value(const []);',
    reemplazar: '      case ContextoAdjuntos.comprobantesDelPago:',
    test: 'test/politica_adjuntos_test.dart',
    porque:
        'La fila del clip del pago pierde su gating: la tabla de politica '
        'existe justamente para que ningun contexto financiero dependa de '
        'que su pantalla se acuerde del GuardiaPermiso.',
  ),

  Mutacion(
    nombre: '244-pull-cocinero-baja-facturas',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    buscar: '      soloOperativo ? TipoAdjunto.financieros : null;',
    reemplazar: "      soloOperativo ? const {'comprobante'} : null;",
    test: 'test/pull_cocinero_tipos_excluidos_test.dart',
    porque:
        'Vuelve la exclusion mono-tipo de HU-110: el telefono del cocinero '
        'baja las facturas de HU-147 y la defensa en profundidad del cliente '
        'queda dependiendo SOLO de la RLS.',
  ),

  // ── #245 · limpieza automática del caché web tras cada deploy ─────────────
  Mutacion(
    nombre: '245-la-limpieza-lee-el-json-cacheado',
    archivo: 'web/index.html',
    buscar:
        "        const res = await fetch('despliegue.json?t=' + Date.now(), {",
    reemplazar:
        "        const res = await fetch('version.json?t=' + Date.now(), {",
    test: 'test/limpieza_cache_web_test.dart',
    porque:
        'El script pasa a leer version.json, que esta en el manifest del '
        'service worker: un SW viejo sirve la copia VIEJA, el cambio de '
        'version jamas se detecta y la limpieza automatica queda decorativa.',
  ),
  Mutacion(
    nombre: '245-la-limpieza-no-borra-nada',
    archivo: 'web/index.html',
    buscar: '          await Promise.all(claves.map((k) => caches.delete(k)));',
    reemplazar: '          await Promise.all(claves.map((k) => k));',
    test: 'test/limpieza_cache_web_test.dart',
    porque:
        'Se desregistra el service worker pero su cache de archivos queda '
        'entero: el navegador puede seguir sirviendo la mezcla de versiones '
        'que era exactamente el bug reportado.',
  ),
  Mutacion(
    nombre: '245-el-deploy-no-sella-despliegue-json',
    archivo: '../.github/workflows/demo.yml',
    buscar: '          cp version.json despliegue.json',
    // OJO: el reemplazo NO puede contener el comando ni comentado — el test
    // busca el substring exacto y lo seguiría encontrando (así nació
    // tautológica esta mutación, tapada por otros tests rojos del archivo).
    reemplazar: '          true # sellado desactivado',
    test: 'test/limpieza_cache_web_test.dart',
    porque:
        'Sin el sellado, el fetch del index da 404 para siempre: toda la '
        'limpieza automatica queda muerta con el codigo entero puesto.',
  ),

  // ── #243 · la siembra de costos y alícuotas al procesar ───────────────────
  Mutacion(
    nombre: '243-procesar-ignora-la-siembra',
    archivo: 'lib/controllers/controlador_procesar_recepcion.dart',
    buscar: '      netoUnitario: previo?.precio,',
    reemplazar: '      netoUnitario: null,',
    test: 'test/controlador_procesar_recepcion_test.dart',
    porque:
        'Los costos vuelven a nacer vacios: el autocompletar de #243 muere y '
        'el admin tipea de nuevo cada precio que el sistema ya sabia.',
  ),
  Mutacion(
    nombre: '243-siembra-acepta-alicuota-invalida',
    archivo: 'lib/controllers/controlador_procesar_recepcion.dart',
    buscar:
        '      alicuota: previo != null && esAlicuotaValida(previo.alicuota)',
    reemplazar: '      alicuota: previo != null',
    test: 'test/controlador_procesar_recepcion_test.dart',
    porque:
        'Una fila legacy con la alicuota en porcentaje (21.0) se siembra tal '
        'cual: el IVA de la linea queda en 2100% y el total bruto explota.',
  ),

  // ── #236 · el historial de la ficha se corta de a 20 ──────────────────────
  Mutacion(
    nombre: '236-el-corte-no-corta',
    archivo: 'lib/screens/proveedores/widgets/historial_proveedor.dart',
    buscar: '    final recortados = filtrados.take(_visibles).toList();',
    reemplazar: '    final recortados = filtrados.toList();',
    test: 'test/historial_proveedor_widget_test.dart',
    porque:
        'La ficha vuelve a construir TODAS las tarjetas de una (shrinkWrap '
        'sin corte): con anios de pedidos, entrar a un proveedor se vuelve '
        'inusable — exactamente lo que #236 vino a evitar.',
  ),
  Mutacion(
    nombre: '236-ver-mas-no-suma',
    archivo: 'lib/screens/proveedores/widgets/historial_proveedor.dart',
    buscar:
        '        onPressed: () => setState(() => _visibles += _tamanoPagina),',
    reemplazar: '        onPressed: () => setState(() => _visibles += 0),',
    test: 'test/historial_proveedor_widget_test.dart',
    porque:
        'El boton "Ver mas" queda decorativo: promete lo que falta y no '
        'muestra nada, y los pedidos viejos se vuelven inalcanzables.',
  ),
  Mutacion(
    nombre: '236-el-filtro-no-resetea-el-corte',
    archivo: 'lib/screens/proveedores/widgets/historial_proveedor.dart',
    buscar: '              _visibles = _tamanoPagina;',
    reemplazar: '              _visibles = _visibles;',
    test: 'test/historial_proveedor_widget_test.dart',
    porque:
        'Un "Ver mas" viejo se arrastra al criterio nuevo: despues de agrandar '
        'el corte y cambiar un filtro, la lista sale mas larga de lo que el '
        'corte promete y el boton desaparece cuando no deberia.',
  ),

  // ── #235 · enviar el pedido por email ─────────────────────────────────────
  Mutacion(
    nombre: '235-email-invalido-genera-mailto',
    archivo: 'lib/utils/validador_datos.dart',
    buscar: '    if (!validarEmail(destinatario)) return null;',
    reemplazar: '    if (destinatario.isEmpty) return null;',
    test: 'test/validador_datos_test.dart',
    porque:
        'Cualquier texto no vacio pasa a generar un mailto: el boton se '
        'habilita con un email basura y el envio falla recien en el cliente '
        'de correo, sin pista de por que.',
  ),
  Mutacion(
    nombre: '235-mailto-cuerpo-sin-codificar',
    archivo: 'lib/utils/validador_datos.dart',
    buscar: "        'body=\${Uri.encodeComponent(mensaje)}',",
    reemplazar: "        'body=\$mensaje',",
    test: 'test/validador_datos_test.dart',
    porque:
        'El cuerpo viaja sin codificar: los saltos de linea y el "&" del '
        'texto rompen la query del mailto y el correo se abre con el mensaje '
        'cortado o vacio.',
  ),
  Mutacion(
    nombre: '235-email-ignora-el-texto-editado',
    archivo: 'lib/services/servicio_envio_pedido.dart',
    buscar:
        '      asunto: MensajesPedido.asuntoEmail,\n'
        '      mensaje: mensaje,',
    reemplazar:
        '      asunto: MensajesPedido.asuntoEmail,\n'
        "      mensaje: '',",
    test: 'test/servicio_envio_pedido_test.dart',
    porque:
        'El correo sale con el cuerpo vacio: lo que el usuario edito en el '
        'resumen se descarta en silencio y el proveedor recibe un email sin '
        'pedido.',
  ),
  Mutacion(
    nombre: '235-boton-email-sin-guardia',
    archivo: 'lib/screens/recibir/resumen_pedido_screen.dart',
    buscar: '            onPressed: _emailValido ? _enviarPorEmail : null,',
    reemplazar: '            onPressed: _enviarPorEmail,',
    test: 'test/resumen_pedido_email_test.dart',
    porque:
        'El boton queda habilitado sin email cargado: tocarlo no abre nada '
        '(o abre un mailto invalido) y el warning de al lado dice una cosa '
        'mientras el boton promete otra.',
  ),

  // ── #234 · pestaña nueva en web + adjuntos del pedido ─────────────────────
  // #258 movió el abridor al State (`abridor` → `widget.abridor`) y el ancla
  // quedó huérfana: el CI reportó "el ancla aparece 0 veces" durante 8 dias
  // sin que nadie lo mirara. Al reponerla se vio que el gating vive en TRES
  // sitios y que UNA sola mutacion daba verde cubriendo un tercio: van dos,
  // una por comportamiento con asercion propia (el boton sobre la imagen y
  // el rotulo del boton del PDF).
  //
  // El tercer sitio (`_barraPdf`, la barra del PDF embebido) NO lleva mutacion
  // a proposito: `_vistaPdfEmbebido` sólo se construye si `puedeEmbeber`, que
  // es true unicamente en web, donde `abreEnPestana` tambien es siempre true.
  // Esa guarda es redundante por construccion y mutarla no prueba nada: el
  // arnes la reporto como "el test pasa igual" y el motivo no es un test flojo
  // sino una rama inalcanzable en produccion. Escribirle un test seria
  // cobertura de adorno. Si algun dia `puedeEmbeber` y `abreEnPestana` dejan
  // de moverse juntos, ahi si hace falta la mutacion y el test.
  //
  // El ancla lleva la linea siguiente porque la version de 8 espacios es
  // SUBSTRING de la de 10 (el runner cuenta apariciones de texto, no lineas).
  Mutacion(
    nombre: '234-la-pestana-se-ofrece-en-android',
    archivo: 'lib/screens/pagos/widgets/visor_remito.dart',
    buscar: '        if (widget.abridor.abreEnPestana)\n          Positioned(',
    reemplazar: '        if (true)\n          Positioned(',
    test: 'test/visor_remito_abridor_test.dart',
    porque:
        'El boton "abrir en pestaña nueva" aparece sobre las IMAGENES tambien '
        'en Android, donde no significa nada: la imagen ya se ve ahi mismo '
        'con zoom, y el tap va al camino del archivo temporal sin necesidad.',
  ),
  Mutacion(
    nombre: '234-el-pdf-promete-pestana-en-android',
    archivo: 'lib/screens/pagos/widgets/visor_remito.dart',
    buscar:
        '                widget.abridor.abreEnPestana\n'
        "                    ? 'Abrir en pestaña nueva'",
    reemplazar:
        "                true\n                    ? 'Abrir en pestaña nueva'",
    test: 'test/visor_remito_abridor_test.dart',
    porque:
        'El rotulo del boton del PDF dice "Abrir en pestaña nueva" en Android, '
        'donde el archivo se abre en otra app: el cartel promete algo que la '
        'plataforma no hace (#234 lo arreglo justamente para que diga la '
        'verdad en cada plataforma).',
  ),
  Mutacion(
    nombre: '234-adjuntos-del-pedido-sin-gating-por-rol',
    // #244 movió el gating a la tabla de política: el ancla lo sigue.
    archivo: 'lib/services/servicio_adjuntos.dart',
    buscar:
        '        if (!puedeVerFinanzas) return _backend.listarPorPedido(id);',
    reemplazar: '        if (false) return _backend.listarPorPedido(id);',
    test: 'test/servicio_adjuntos_pedido_test.dart',
    porque:
        'La vista unificada del historial le muestra facturas y comprobantes '
        'al cocinero, que no debe ver un solo importe (HU-060/110/147). El '
        'gating vive en el Service justamente para que ninguna pantalla '
        'pueda olvidarse de el.',
  ),
  Mutacion(
    nombre: '234-adjuntos-del-pedido-en-desorden',
    archivo: 'lib/services/servicio_adjuntos.dart',
    buscar:
        '    return [...listas[0], ...listas[1], ...listas[2], ...listas[3]];',
    reemplazar:
        '    return [...listas[3], ...listas[2], ...listas[1], ...listas[0]];',
    test: 'test/servicio_adjuntos_pedido_test.dart',
    porque:
        'El visor pasa a abrir por el comprobante en vez del remito: el orden '
        'que-llego -> que-te-cobran -> como-lo-pagaste es el de la operacion '
        'real (#209) y la UI lo da por sentado.',
  ),

  // ── #239 · formulario unico de insumo, sin costo en el alta ───────────────
  Mutacion(
    nombre: '239-costeo-incompleto-no-cuenta',
    archivo: 'lib/database/database.dart',
    buscar: '        insumosSinPrecio += 1;',
    reemplazar: '        insumosSinPrecio += 0;',
    test: 'test/costeo_incompleto_test.dart',
    porque:
        'La receta con ingredientes sin precio vuelve a parecer completa: el '
        'FoodCost sub-reporta con CERO en silencio, que es exactamente el '
        'agujero que esta red vino a cerrar antes de quitar el costo del '
        'alta.',
  ),
  Mutacion(
    nombre: '239-alta-desde-receta-se-pierde',
    archivo: 'lib/screens/recetas/widgets/formulario_receta_modal.dart',
    buscar: '    if (creado == null || !mounted) return;',
    reemplazar: '    if (creado != null || !mounted) return;',
    test: 'test/alta_desde_receta_unico_formulario_test.dart',
    porque:
        'El insumo creado desde la receta no vuelve a la lista de '
        'ingredientes: el usuario lo da de alta, el formulario dice "creado" '
        'y la receta queda igual que antes.',
  ),
  Mutacion(
    nombre: '239-alta-vuelve-a-pedir-costo',
    archivo: 'lib/screens/insumos/widgets/formulario_insumo_modal.dart',
    buscar: '            if (_esEdicion && puedeVerFinanzas) ...[',
    reemplazar: '            if (puedeVerFinanzas) ...[',
    test: 'test/alta_sin_costo_test.dart',
    porque:
        'El campo de costo reaparece en el ALTA: el usuario vuelve a sembrar '
        'un numero inventado en historial_precios como si fuera una compra, '
        'que es la regla de negocio que #239 elimino.',
  ),
  Mutacion(
    nombre: '239-edicion-acepta-costo-cero',
    archivo: 'lib/controllers/controlador_insumos.dart',
    buscar: '    if (cambioCosto && nuevoCosto <= 0) {',
    reemplazar: '    if (cambioCosto && nuevoCosto < 0) {',
    test: 'test/alta_sin_costo_test.dart',
    porque:
        'Un ajuste manual a \$0 pasa: tira a cero el costeo de todas las '
        'recetas que usan el insumo, y el FoodCost sub-reporta sin sintoma.',
  ),

  // ── #264 · registrar pago desde la ficha/cuenta corriente del proveedor ────
  Mutacion(
    nombre: '264-pago-cuenta-corriente-sin-gate',
    archivo: 'lib/screens/pagos/cuenta_corriente_screen.dart',
    buscar: '          if (Permisos.puede(',
    reemplazar: '          if (!Permisos.puede(',
    test: 'test/cuenta_corriente_boton_pago_test.dart',
    porque:
        'El boton "Registrar pago" del AppBar deja de gatear por finanzas: '
        'aparece para roles sin permiso (el cocinero) y desaparece para el '
        'admin. El AppBar queda fuera del GuardiaPermiso del body, asi que sin '
        'este gate un rol sin finanzas veria una accion que no le corresponde.',
  ),

  // ── #237 · filtros en la pantalla de Pagos ────────────────────────────────
  Mutacion(
    nombre: '237-cuit-sin-normalizar',
    archivo: 'lib/utils/filtros_pagos.dart',
    buscar: "  return soloDigitos(cuit ?? '').contains(digitosBuscados);",
    reemplazar: "  return (cuit ?? '').contains(digitosBuscados);",
    test: 'test/filtros_pagos_test.dart',
    porque:
        'Tipear el CUIT sin guiones deja de encontrar al proveedor guardado '
        'con guiones: la pantalla dice "sin coincidencias" de algo que '
        'existe.',
  ),
  Mutacion(
    nombre: '237-legacy-desaparece-en-silencio',
    archivo: 'lib/utils/filtros_pagos.dart',
    buscar: '      ocultas++;',
    reemplazar: '      ocultas += 0;',
    test: 'test/filtros_pagos_test.dart',
    porque:
        'Las recepciones sin proveedor identificado se ocultan bajo un filtro '
        'y NADIE lo dice: plata pendiente de procesar que desaparece de la '
        'vista sin aviso.',
  ),
  Mutacion(
    nombre: '237-orden-invertido',
    archivo: 'lib/utils/filtros_pagos.dart',
    buscar: '        ? saldoDe(b).compareTo(saldoDe(a))',
    reemplazar: '        ? saldoDe(a).compareTo(saldoDe(b))',
    test: 'test/filtros_pagos_test.dart',
    porque:
        '"Mayor deuda primero" ordena al reves: el proveedor al que MENOS se '
        'le debe encabeza la lista de a quien pagarle primero.',
  ),
  Mutacion(
    nombre: '237-set-vacio-filtra-todo',
    archivo: 'lib/utils/filtros_pagos.dart',
    buscar:
        '    if (criterios.proveedorIds.isNotEmpty &&\n'
        '        !criterios.proveedorIds.contains(p.id)) {',
    reemplazar:
        '    if (criterios.proveedorIds.isEmpty &&\n'
        '        !criterios.proveedorIds.contains(p.id)) {',
    test: 'test/filtros_pagos_test.dart',
    porque:
        'Sin ningun proveedor tildado, la seccion de saldos sale VACIA: el '
        'estado neutro del multi-select pasa de "no filtra" a "filtra todo".',
  ),
  Mutacion(
    nombre: '237-filtra-solo-una-seccion',
    archivo: 'lib/screens/pagos/pagos_screen.dart',
    buscar:
        '          ...provsFiltrados.map((pr) => _cardProveedor(ctrl, pr)),',
    reemplazar:
        '          ...ctrl.proveedores.map((pr) => _cardProveedor(ctrl, pr)),',
    test: 'test/pagos_filtros_screen_test.dart',
    porque:
        'El filtro aplica solo a las recepciones y la seccion de saldos '
        'muestra todo igual: el PO pidio explicitamente que aplique a AMBAS '
        'secciones.',
  ),
  Mutacion(
    nombre: '237-badge-siempre-apagado',
    archivo: 'lib/screens/pagos/pagos_screen.dart',
    buscar: '                  isLabelVisible: _criterios.hayAlguno,',
    reemplazar: '                  isLabelVisible: false,',
    test: 'test/pagos_filtros_screen_test.dart',
    porque:
        'Con filtros activos y el panel cerrado, nada indica que la lista '
        'esta recortada: el usuario mira una pantalla incompleta creyendo '
        'que es todo lo que hay.',
  ),
  Mutacion(
    nombre: '237-aviso-legacy-mudo',
    archivo: 'lib/screens/pagos/pagos_screen.dart',
    buscar: '        if (resultadoRec.ocultasSinProveedor > 0)',
    reemplazar: '        if (resultadoRec.ocultasSinProveedor > 999999)',
    test: 'test/pagos_filtros_screen_test.dart',
    porque:
        'El contador de recepciones sin proveedor identificado existe pero el '
        'cuerpo nunca lo muestra: la plata vuelve a desaparecer en silencio, '
        'ahora con el dato calculado y tirado.',
  ),

  // ── #238 · los textos factura/pago y el comprobante en el pago ────────────
  Mutacion(
    nombre: '238-wizard-persiste-todo-como-comprobante',
    archivo: 'lib/services/servicio_procesar_recepcion.dart',
    buscar:
        '      pagadoEnEfectivo ? TipoAdjunto.comprobante : TipoAdjunto.factura;',
    reemplazar: '      TipoAdjunto.comprobante;',
    test: 'test/comprobante_facturar_round_trip_test.dart',
    porque:
        'La factura de una transferencia vuelve a guardarse como "comprobante '
        'de pago" sin que haya habido pago: evidencia falsa en la cuenta '
        'corriente, e invisible en el visor de facturas.',
  ),
  Mutacion(
    nombre: '238-respaldo-pierde-el-historico',
    archivo: 'lib/services/servicio_adjuntos.dart',
    buscar:
        '      _backend.listarFacturasPorRecepcion(recepcionId),\n'
        '      _backend.listarComprobantesPorRecepcion(recepcionId),\n'
        '      _backend.listarComprobantesDePagosDeRecepcion(recepcionId),\n'
        '    ]);\n'
        '    return [...listas[0], ...listas[1], ...listas[2]];',
    reemplazar:
        '      _backend.listarFacturasPorRecepcion(recepcionId),\n'
        '      _backend.listarFacturasPorRecepcion(recepcionId),\n'
        '      _backend.listarComprobantesDePagosDeRecepcion(recepcionId),\n'
        '    ]);\n'
        '    return [...listas[0], ...listas[2]];',
    test: 'test/servicio_adjuntos_respaldo_test.dart',
    porque:
        'El boton unificado de la cuenta corriente deja de mostrar los '
        'comprobantes historicos (todo lo que el wizard viejo guardo): anios '
        'de papeles se vuelven invisibles justo donde se los busca.',
  ),
  Mutacion(
    nombre: '238-adjunto-huerfano-o-bigamo',
    archivo: 'lib/data/repositorios/repositorio_adjuntos.dart',
    buscar: '    if ((recepcionId == null) == (pagoId == null)) {',
    reemplazar: '    if (false) {',
    test: 'test/repositorio_adjuntos_pago_test.dart',
    porque:
        'Un adjunto puede nacer sin padre (invisible en todos los listados) o '
        'con dos (el CHECK del servidor lo rechaza y muere en dead-letter). '
        'La guarda local es el espejo de ese CHECK.',
  ),
  Mutacion(
    nombre: '238-outbox-pierde-el-pago-del-comprobante',
    archivo: 'lib/data/repositorios/repositorio_adjuntos.dart',
    buscar: "    'pago_id': a.pagoId,",
    reemplazar: "    'pago_id': null,",
    test: 'test/repositorio_adjuntos_pago_test.dart',
    porque:
        'El payload del Outbox viaja sin pago_id: el CHECK exactamente-uno '
        'del servidor rechaza la fila y el comprobante de la transferencia '
        'muere en dead-letter, en silencio.',
  ),
  Mutacion(
    nombre: '238-pull-descarta-el-pago-del-comprobante',
    archivo: 'lib/services/servicio_descarga_negocio.dart',
    buscar: "            pagoId: Value(m['pago_id'] as String?),",
    reemplazar: '            pagoId: const Value(null),',
    test: 'test/servicio_descarga_adjunto_test.dart',
    porque:
        'El comprobante registrado en otro dispositivo baja sin su pago: '
        'queda sin padre visible y el boton de la cuenta corriente no lo '
        'encuentra nunca.',
  ),
  Mutacion(
    nombre: '238-pago-sin-su-comprobante',
    archivo: 'lib/services/servicio_pagos.dart',
    buscar: '      await adjuntarEnTransaccion?.call(pago.id);',
    reemplazar: '      await Future<void>.value();',
    test: 'test/registrar_pago_con_comprobante_test.dart',
    porque:
        'El pago se asienta y el archivo del comprobante se descarta sin una '
        'sola senial — el mismo fallo silencioso que #227 saco de las '
        'recepciones, reintroducido en los pagos.',
  ),

  // ── #240 · los comprobantes del pago llegan a las vistas unificadas ───────
  Mutacion(
    nombre: '240-el-pedido-ignora-los-comprobantes-del-pago',
    archivo: 'lib/services/servicio_adjuntos.dart',
    buscar: '      _backend.listarComprobantesDePagosDelPedido(pedidoId),',
    // Vuelve a sumar el grupo viejo dos veces en vez del nuevo: el fake de los
    // tests ignora el argumento, asi que mutar el id no se notaria.
    reemplazar:
        '      _backend.listarPorPedidoDeTipo(pedidoId, TipoAdjunto.comprobante),',
    test: 'test/servicio_adjuntos_pedido_test.dart',
    porque:
        'Es el bug que reporto el PO: lo adjuntado en "Registrar pago" cuelga '
        'del pago (recepcion NULL) y el visor de adjuntos del pedido vuelve a '
        'no mostrarlo nunca.',
  ),
  Mutacion(
    nombre: '240-el-respaldo-ignora-los-comprobantes-del-pago',
    archivo: 'lib/services/servicio_adjuntos.dart',
    buscar: '      _backend.listarComprobantesDePagosDeRecepcion(recepcionId),',
    // Idem la de arriba: se suma el grupo viejo repetido en vez del nuevo.
    reemplazar: '      _backend.listarComprobantesPorRecepcion(recepcionId),',
    test: 'test/servicio_adjuntos_respaldo_test.dart',
    porque:
        'El boton "Ver factura / comprobante" de la cuenta corriente muestra '
        'la deuda y calla como se pago: el comprobante de la transferencia '
        'queda visible solo en el movimiento del pago.',
  ),
  Mutacion(
    nombre: '240-el-comprobante-sale-una-vez-por-imputacion',
    archivo: 'lib/data/repositorios/repositorio_adjuntos.dart',
    buscar: '    return porId.values.toList(growable: false);',
    reemplazar: '    return filas;',
    test: 'test/repositorio_adjuntos_pago_test.dart',
    porque:
        'Un pago que imputa dos facturas del mismo pedido muestra su '
        'comprobante repetido en el visor: el join trae una fila por '
        'imputacion y alguien tiene que compactar.',
  ),
  Mutacion(
    nombre: '240-la-ficha-esconde-los-adjuntos',
    archivo: 'lib/screens/proveedores/widgets/historial_proveedor.dart',
    buscar: '            if (ped.estado != EstadosPedido.cancelado)',
    reemplazar: '            if (false)',
    test: 'test/historial_proveedor_widget_test.dart',
    porque:
        'La ficha del proveedor vuelve a ser el unico historial sin acceso a '
        'los papeles del pedido: para verlos hay que irse a otra pantalla, '
        'que es la mitad del reporte del PO en #240.',
  ),
  // ── #251 · el comentario en Diferencias es OPCIONAL ───────────────────────
  Mutacion(
    nombre: '251-la-diferencia-vuelve-a-exigir-comentario',
    archivo: 'lib/utils/desenlace_recepcion.dart',
    // #265 quitó el bloque del motivo (el ancla vieja ya no existe): se ancla en
    // la línea de `recibida`, que sobrevive, y se inserta el bloque justo después.
    buscar:
        "    final recibida = (it['cantidadRecibida'] as num?)?.toDouble() ?? 0.0;",
    reemplazar:
        "    final recibida = (it['cantidadRecibida'] as num?)?.toDouble() ?? 0.0;\n"
        '    if (estado == DesenlaceRecepcion.diferencia &&\n'
        "        (it['comentario'] ?? '').toString().trim().isEmpty) {\n"
        "      return 'El ítem tiene diferencias: agregá un comentario.';\n"
        '    }',
    test: 'test/desenlace_recepcion_test.dart',
    porque:
        'Vuelve a bloquear la recepción con diferencias que no lleva comentario '
        '(el comentario en Diferencias es OPCIONAL desde #251); trabar por eso '
        'un flujo válido es justo lo que el PO pidió sacar.',
  ),
  // ── #265 · el motivo del rechazo es OPCIONAL ──────────────────────────────
  Mutacion(
    nombre: '265-el-rechazo-vuelve-a-exigir-motivo',
    archivo: 'lib/utils/desenlace_recepcion.dart',
    buscar:
        "    final recibida = (it['cantidadRecibida'] as num?)?.toDouble() ?? 0.0;",
    reemplazar:
        "    final recibida = (it['cantidadRecibida'] as num?)?.toDouble() ?? 0.0;\n"
        '    if (estado == DesenlaceRecepcion.rechazado &&\n'
        "        (it['motivoId'] ?? '').toString().trim().isEmpty) {\n"
        "      return 'El ítem rechazado: seleccioná un motivo.';\n"
        '    }',
    test: 'test/desenlace_recepcion_test.dart',
    porque:
        'Reintroduce la obligatoriedad del motivo al rechazar (recibir 0), que '
        '#265 volvió OPCIONAL: bloquearía de nuevo la confirmación de una '
        'recepción con un ítem rechazado sin motivo.',
  ),
  // ── #263 · la recepción arranca vacía; el usuario marca Correcto ───────────
  Mutacion(
    nombre: '263-recepcion-arranca-en-correcto',
    archivo: 'lib/screens/recibir/widgets/verificacion_recepcion_modal.dart',
    buscar: "        'estado': DesenlaceRecepcion.pendiente,",
    reemplazar: "        'estado': DesenlaceRecepcion.correcto,",
    test: 'test/verificacion_recepcion_modal_test.dart',
    porque:
        'La recepción vuelve a arrancar con todos los ítems pre-marcados '
        'Correcto: se puede confirmar sin revisar lo que llegó, que es justo lo '
        'que #263 elimina.',
  ),
  Mutacion(
    nombre: '263-marcar-correcto-no-fija-estado',
    archivo: 'lib/screens/recibir/widgets/verificacion_recepcion_modal.dart',
    buscar:
        "    item['estado'] = DesenlaceRecepcion.correcto;\n"
        "    item['cantidadRecibida'] = pedida;",
    reemplazar: "    item['cantidadRecibida'] = pedida;",
    test: 'test/verificacion_recepcion_modal_test.dart',
    porque:
        'Marcar "Correcto" (por ítem o con el botón global) autocompleta la '
        'cantidad pero NO fija el estado: el ítem queda en "pendiente" y NUNCA '
        'desbloquea Confirmar aunque el usuario lo haya marcado.',
  ),
  Mutacion(
    nombre: '263-pendiente-no-bloquea-confirmar',
    archivo: 'lib/utils/desenlace_recepcion.dart',
    buscar:
        "    if (estado == DesenlaceRecepcion.pendiente) {\n"
        "      return 'Marcá el desenlace de \"\$nombre\" (Correcto, Diferencias o Rechazado).';",
    reemplazar:
        "    if (false && estado == DesenlaceRecepcion.pendiente) {\n"
        "      return 'Marcá el desenlace de \"\$nombre\" (Correcto, Diferencias o Rechazado).';",
    test: 'test/desenlace_recepcion_test.dart',
    porque:
        'Saca la rama que bloquea la confirmación mientras un ítem sigue en '
        '"pendiente" (#263): sin ella, un ítem sin resolver se cuela y la '
        'recepción se confirma como si estuviera atendido.',
  ),
  // ── #252 · contador por pestaña en Pedidos ────────────────────────────────
  Mutacion(
    nombre: '252-el-contador-suma-los-que-no-van',
    archivo: 'lib/utils/estados_pedido.dart',
    buscar:
        '      if (e.value == estado) return e.key;\n'
        '    }\n'
        '    return null;',
    reemplazar:
        '      if (e.value == estado) return e.key;\n'
        '    }\n'
        '    return PestanaPedido.activos;',
    test: 'test/estados_pedido_test.dart',
    porque:
        'Los estados que no son de ninguna solapa (en_espera → Recepciones, y '
        'todo el historial) caen en Activos: el contador infla y muestra pedidos '
        'que esa pestaña no lista (el bug del .length crudo que #252 evita).',
  ),
  // ── #253 · volver al inicio SÓLO tras un envío exitoso ────────────────────
  Mutacion(
    nombre: '253-el-resumen-se-cierra-al-fallar-el-envio',
    archivo: 'lib/screens/recibir/resumen_pedido_screen.dart',
    buscar: '    if (await EnlacesExternos.abrir(url)) {',
    reemplazar: '    if (!await EnlacesExternos.abrir(url)) {',
    test: 'test/resumen_pedido_envio_test.dart',
    porque:
        'Invierte el desenlace: el Resumen se cierra cuando el envío FALLA y se '
        'queda cuando sale bien. Saltar al inicio sin haber enviado parece que '
        'la app se comió el pedido; quedarse tras enviar obliga a volver a mano '
        '— las dos mitades de lo que #253 arregla.',
  ),

  // ── #254 · la contraseña del login se lee (contraste) ─────────────────────
  Mutacion(
    nombre: '254-el-campo-glass-vuelve-al-fondo-claro',
    archivo: 'lib/screens/onboarding/widgets/input_glassmorphic.dart',
    buscar: '            color: const Color(0x66000000), // negro 40% opacidad',
    reemplazar:
        '            color: const Color(0x2EFFFFFF), // negro 40% opacidad',
    test: 'test/input_glassmorphic_password_test.dart',
    porque:
        'Devuelve el fondo del campo a un blanco translúcido: sobre el degradé '
        'celeste, el texto blanco queda ilegible aun revelándolo con el ojo '
        '— exactamente el defecto que reportó el cliente en #254.',
  ),

  // ── #256 · el icono de mensaje abre el chat VACÍO del proveedor ────────────
  Mutacion(
    nombre: '256-el-chat-vuelve-a-llevar-mensaje',
    archivo: 'lib/services/servicio_envio_pedido.dart',
    buscar: "    return ValidadorDatos.urlWhatsapp(telefonoProveedor ?? '');",
    reemplazar:
        "    return ValidadorDatos.urlWhatsapp(telefonoProveedor ?? '', mensaje: 'x');",
    test: 'test/servicio_envio_pedido_test.dart',
    porque:
        'El icono de mensaje vuelve a precargar texto en el chat, en vez de '
        'abrirlo en blanco. Era justo lo que el cliente no quería en #256: que '
        'el icono reenviara el pedido en lugar de solo contactar al proveedor.',
  ),

  // ── #261 · la guía del Paso 2 muestra existentes + staged (filmstrip) ──────
  Mutacion(
    nombre: '261-la-guia-esconde-los-existentes',
    archivo:
        'lib/screens/pagos/procesar_recepcion/widgets/preview_factura_staged.dart',
    buscar: 'final docs = <DocVisualizable>[...existentes, ...staged];',
    reemplazar: 'final docs = <DocVisualizable>[...staged];',
    test: 'test/preview_factura_staged_test.dart',
    porque:
        'La guía vuelve a mostrar SOLO los staged y esconde los adjuntos ya '
        'persistidos de la recepción (el remito cargado al recibir): es justo el '
        'hueco que reportó el PO y que #261 vino a cerrar.',
  ),
  Mutacion(
    nombre: '261-el-panel-no-salta-al-nuevo-staged',
    archivo:
        'lib/screens/pagos/procesar_recepcion/widgets/preview_factura_staged.dart',
    buscar: 'setState(() => _seleccion = _existentesCount + nuevo - 1);',
    reemplazar: 'setState(() {});',
    test: 'test/preview_factura_staged_test.dart',
    porque:
        'Al adjuntar una factura, el panel NO salta a mostrarla (se queda en el '
        'existente): el PO carga un adjunto para tipear los precios de ÉL y no lo '
        've, que es el reflejo del hueco original.',
  ),

  // ── #258 · PDF inline en el visor y en la guía ────────────────────────────
  // La rama web real (`<embed>` en un `HtmlElementView`) no corre en la VM; lo
  // testeable es el DESPACHO: que un PDF embebible se muestre embebido y no como
  // placeholder, y que la guía del Paso 2 embeba el PDF en web.
  Mutacion(
    nombre: '258-el-visor-no-embebe-el-pdf',
    archivo: 'lib/screens/pagos/widgets/visor_remito.dart',
    buscar:
        '  bool get _pdfEmbebible => _esPdf && widget.visorPdf.puedeEmbeber;',
    reemplazar: '  bool get _pdfEmbebible => false;',
    test: 'test/visor_remito_pdf_test.dart',
    porque:
        'El visor nunca embebe el PDF: aun en web caería al placeholder "abrir '
        'afuera", que es justo lo que #258 vino a evitar (ver el PDF inline).',
  ),
  Mutacion(
    nombre: '258-la-guia-no-embebe-el-pdf',
    archivo:
        'lib/screens/pagos/procesar_recepcion/widgets/preview_factura_staged.dart',
    buscar: '    } else if (esPdf && _visor.puedeEmbeber) {',
    reemplazar: '    } else if (false) {',
    test: 'test/preview_factura_staged_test.dart',
    porque:
        'La guía del Paso 2 deja de embeber el PDF (cae siempre al placeholder): '
        'en web la factura PDF no se vería inline como guía (#258/#261).',
  ),

  // ── #257 · el superadmin manda su negocio activo a las Edge Functions ──────
  // La autorización real vive en las EF (Deno), que la suite Dart no alcanza; lo
  // que SÍ es testeable acá es el plumbing: que el negocio activo viaje en el
  // payload. Sin eso, la EF no sabe sobre qué negocio opera el superadmin.
  Mutacion(
    nombre: '257-el-negocio-activo-no-viaja',
    archivo: 'lib/services/servicio_gestion_equipo.dart',
    buscar: '  String get _negocioActivo => _sesion.negocioId;',
    reemplazar: "  String get _negocioActivo => '';",
    test: 'test/servicio_gestion_equipo_test.dart',
    porque:
        'El negocio activo deja de viajar en el payload de las 3 Edge Functions. '
        'El superadmin no podría crear/resetear/dar de baja: la EF no sabe sobre '
        'qué negocio opera (no tiene fila en `usuarios` de dónde derivarlo).',
  ),

  // ── #262 · catálogo de categorías de insumo (Fase 1) ──────────────────────
  Mutacion(
    nombre: '262-categoria-no-detecta-duplicado',
    archivo: 'lib/services/servicio_categorias.dart',
    buscar: '      if (c.nombre.trim().toLowerCase() == objetivo) return c;',
    reemplazar: '      if (false) return c;',
    test: 'test/servicio_categorias_test.dart',
    porque:
        'La búsqueda por nombre nunca encuentra coincidencia: se pueden crear '
        'categorías duplicadas (rompe la unicidad case-insensitive por negocio) y '
        'un nombre inactivo homónimo ya NO se reactiva (chocaría con el índice '
        'único al reinsertar). Es el corazón de la validación del catálogo.',
  ),

  // ── #262 · relación proveedor↔categoría (Fase 2) ──────────────────────────
  Mutacion(
    nombre: '262-proveedor-categoria-no-es-idempotente',
    archivo: 'lib/data/repositorios/repositorio_proveedor_categorias.dart',
    buscar: '    final existente = await _porIdOrNull(id);',
    reemplazar: '    final ProveedorCategoria? existente = null;',
    test: 'test/repositorio_proveedor_categorias_test.dart',
    porque:
        'asignar deja de mirar si el vínculo ya existe y SIEMPRE inserta: la '
        'segunda asignación del mismo par revienta el índice único {proveedor, '
        'categoría}, y reactivar una desasignada deja de funcionar. Pierde la '
        'idempotencia que sostiene el id determinista y el backfill dual.',
  ),
  Mutacion(
    nombre: '262-backfill-elige-mal-el-display',
    archivo: 'lib/database/migraciones/migrador_categorias_v24.dart',
    buscar: 'if (actual == null || srcId.compareTo(actual.srcIdGanador) < 0) {',
    reemplazar:
        'if (actual == null || srcId.compareTo(actual.srcIdGanador) > 0) {',
    test: 'test/migrador_categorias_v24_test.dart',
    porque:
        'el display ganador pasa a ser el del registro de MAYOR id en vez del '
        'de menor: cliente y servidor eligen distinto representante y el nombre '
        'mostrado de la categoría diverge entre dispositivos.',
  ),
  Mutacion(
    nombre: '262-backfill-no-crea-sin-categoria',
    archivo: 'lib/database/migraciones/migrador_categorias_v24.dart',
    buscar: '''        final clave = (texto == null || _clave(texto).isEmpty)
            ? claveSinCategoria
            : _clave(texto);''',
    reemplazar:
        '''        final clave = (texto == null || _clave(texto).isEmpty)
            ? _clave(texto ?? '')
            : _clave(texto);''',
    test: 'test/migrador_categorias_v24_test.dart',
    porque:
        'un insumo sin texto de categoría deja de caer en "Sin categoría" y '
        'apunta a una categoría de clave vacía que no existe: queda huérfano y '
        'el fallback de lectura no lo cubre.',
  ),
  Mutacion(
    nombre: '262-suministradas-muestra-inactivas',
    archivo: 'lib/services/servicio_proveedor_categorias.dart',
    buscar: '''    final ids = vinculos.map((v) => v.categoriaId).toSet();
    final catalogo = await _categorias.listar(negocioId);''',
    reemplazar: '''    final ids = vinculos.map((v) => v.categoriaId).toSet();
    final catalogo = await _categorias.listar(
      negocioId,
      incluirInactivos: true,
    );''',
    test: 'test/servicio_proveedor_categorias_test.dart',
    porque:
        'categoriasDe deja de cruzar con el catálogo ACTIVO y muestra categorías '
        'desactivadas como si el proveedor todavía las suministrara.',
  ),
  Mutacion(
    nombre: '262-selector-pierde-fallback-sin-categoria',
    archivo: 'lib/services/servicio_pedidos.dart',
    buscar: 'final catId = insumo.categoriaId ?? sinCategoriaId;',
    reemplazar: "final catId = insumo.categoriaId ?? '';",
    test: 'test/insumos_ofrecidos_categoria_test.dart',
    porque:
        'un insumo sin categoriaId deja de caer en "Sin categoría" y desaparece '
        'del selector aunque el proveedor suministre esa categoría: queda '
        'inalcanzable en el pedido.',
  ),
  // ── #266 · expiración absoluta de la sesión local (30 días) ────────────────
  Mutacion(
    nombre: '266-comparador-expiracion-invertido',
    archivo: 'lib/services/servicio_sesion.dart',
    buscar: '    return transcurrido >= duracionMaxSesion.inMilliseconds;',
    reemplazar: '    return transcurrido < duracionMaxSesion.inMilliseconds;',
    test: 'test/hu266_expiracion_sesion_test.dart',
    porque:
        'Invierte la expiración: una sesión de 31 días pasaría a contar como '
        'vigente (y una fresca como vencida). Deja el hueco que la HU cierra.',
  ),
  Mutacion(
    nombre: '266-estaAutenticado-ignora-expiracion',
    archivo: 'lib/services/servicio_sesion.dart',
    buscar: '      (negocioId.isNotEmpty || esSuperAdmin) && !sesionExpirada;',
    reemplazar: '      (negocioId.isNotEmpty || esSuperAdmin);',
    test: 'test/hu266_expiracion_sesion_test.dart',
    porque:
        'Saca el fold que exige !sesionExpirada: la app quedaría autenticada con '
        'una sesión ya vencida, que es exactamente lo que #266 impide.',
  ),
  Mutacion(
    nombre: '266-fecha-login-fuera-de-claves-secretas',
    archivo: 'lib/services/servicio_sesion.dart',
    buscar: '    keyFechaLogin,\n  ];',
    reemplazar: '  ];',
    test: 'test/hu266_expiracion_sesion_test.dart',
    porque:
        'Si la fecha de login no está en clavesSecretas, no se hidrata al '
        'arrancar (una sesión vencida revive tras reiniciar) ni se borra en '
        'cerrarSesion (contamina la sesión siguiente).',
  ),

  // ── Secretos en el bundle (2026-09-16) ────────────────────────────────────
  // El ancla NO es codigo de lib/: es el ejemplo de configuracion. El arnes
  // sirve igual — reintroduce el "bug" (una credencial de servicio donde no va)
  // y exige que el control lo detecte. Es la unica forma de saber que el test
  // de secretos sigue mirando lo que dice mirar.
  Mutacion(
    nombre: 'seguridad-un-secreto-entra-al-bundle',
    archivo: 'assets/.env.example',
    buscar: 'SUPABASE_ANON_KEY=',
    reemplazar: 'SUPABASE_ANON_KEY=sb_secret_mutacion_no_es_una_clave_real',
    test: 'test/secretos_no_entran_al_bundle_test.dart',
    porque:
        'Una clave de SERVICIO en assets/.env viaja dentro del APK y del build '
        'web: cualquiera la extrae y con ella IGNORA las policies de RLS, '
        'leyendo y escribiendo los datos de todos los negocios. El 2026-09-16 '
        'estuvo a punto de entrar una, y el unico freno fue que alguien lo '
        'notara a tiempo.',
  ),

  // ── Cobertura de sincronizacion por tabla (2026-09-18) ────────────────────
  // El ancla es la DECLARACION de la base: se agrega una tabla nueva, como
  // haria cualquier HU que suma una entidad, y el control tiene que exigir que
  // alguien decida si viaja o no.
  Mutacion(
    nombre: 'seguridad-tabla-nueva-sin-decidir-si-sincroniza',
    archivo: 'lib/database/database.dart',
    buscar: '    CursoresPull,',
    reemplazar: '    CursoresPull, Descuentos,',
    test: 'test/sincronizacion_cubre_las_tablas_test.dart',
    porque:
        'Una tabla que entra a la base sin que nadie decida si se sincroniza '
        'es la forma de perder datos sin sintoma: la app escribe local, nadie '
        'encola, y el pull ni siquiera pisa la fila porque la ve pendiente. '
        'Paso de verdad con alertas_desviacion. La mutacion agrega una tabla '
        'que no figura en ninguna de las dos listas, que es exactamente lo '
        'que hace una HU nueva cuando suma una entidad y se olvida de la '
        'cañeria. El test lee database.dart como TEXTO, asi que no necesita '
        'que la clase exista.',
  ),
  // ── #268 · el semaforo de entrega ─────────────────────────────────────────
  //
  // Tres anclas y no una, porque el modulo tiene tres reglas que se rompen por
  // separado y cada una falla de una forma distinta: el borde vencido/hoy es un
  // error VISIBLE, el signo rompe una HU que todavia no existe, y el filtro por
  // estado es el que ningun test de pantalla puede detectar.
  Mutacion(
    nombre: '268-ayer-se-muestra-como-que-llega-hoy',
    archivo: 'lib/utils/semaforo_entrega.dart',
    buscar: '    final categoria = dias < 0',
    reemplazar: '    final categoria = dias <= 0',
    test: 'test/semaforo_entrega_test.dart',
    porque:
        'Corre el borde entre VENCIDO y HOY un dia: una entrega de ayer se '
        'pinta "Llega hoy", en el color de hoy, y deja de aparecer como '
        'atrasada. Es exactamente lo contrario de lo que la HU vino a hacer '
        '—saber a quien reclamarle— y no se nota mirando la pantalla, porque '
        'el chip se ve igual de prolijo. Es la clase de corte que alguien '
        '"simplifica" a <= pensando que es lo mismo.',
  ),
  Mutacion(
    nombre: '268-el-signo-de-los-dias-al-revés',
    archivo: 'lib/utils/semaforo_entrega.dart',
    buscar: '    final dias = FechaRecepcion.diasEntre(hoy, entrega);',
    reemplazar: '    final dias = FechaRecepcion.diasEntre(entrega, hoy);',
    test: 'test/semaforo_entrega_test.dart',
    porque:
        'Invierte el signo de `dias`, que es un CONTRATO con la HU de las '
        'secciones (#277): esa HU deriva su seccion "Mañana" de `dias == 1` en '
        'vez de agregar un quinto valor al enum. Con el signo dado vuelta, '
        '"Mañana" pasa a juntar lo vencido de AYER. Los dos argumentos son del '
        'mismo tipo, asi que el compilador no dice nada, y la categoria sigue '
        'saliendo bien: lo unico que cambia es el numero. Sin un test sobre el '
        'signo, esto se descubre recien cuando #277 esta en produccion.',
  ),
  Mutacion(
    nombre: '268-el-historial-se-llena-de-entregas-atrasadas',
    archivo: 'lib/utils/semaforo_entrega.dart',
    buscar: '  if (pedido.estado != estadoPendiente) return null;',
    reemplazar: '  if (false) return null;',
    test: 'test/semaforo_entrega_test.dart',
    porque:
        'Saca el filtro por estado, que es la unica regla del modulo que NO se '
        'puede probar desde la pantalla: Recepciones ya lista solo `en_espera`, '
        'asi que un test de widget pasa con el filtro y sin el. Sin la regla, '
        'un pedido `enviado` que el proveedor no confirmo muestra "llega en 2 '
        'dias" —afirmando una entrega que nadie prometio— y, peor, toda entrega '
        'del Historial se pinta "Atrasada N dias", porque por definicion tiene '
        'fecha pasada. Es el mismo modo de falla que documenta `serieFrenada`.',
  ),
  // ── #277 · las secciones de Recepciones ───────────────────────────────────
  //
  // La pantalla tenia cobertura CERO antes de esta HU, que es por lo que el
  // agrupamiento se extrajo a un modulo puro. Estas anclas existen para que esa
  // red no sea decorativa: las tres rompen algo que no se ve mirando la
  // pantalla, porque la lista sigue saliendo prolija.
  Mutacion(
    nombre: '277-la-seccion-manana-desaparece',
    archivo: 'lib/utils/secciones_recepciones.dart',
    buscar:
        '      return s.dias == 1 ? _Seccion.manana : _Seccion.posteriores;',
    reemplazar:
        '      return s.dias == 0 ? _Seccion.manana : _Seccion.posteriores;',
    test: 'test/secciones_recepciones_test.dart',
    porque:
        'Un off-by-one en el unico lugar donde "Mañana" se DERIVA de los dias '
        'en vez de ser un valor del enum. Con == 0 la condicion no se cumple '
        'nunca —ese caso ya se fue por la rama `hoy`— asi que la seccion Mañana '
        'no aparece mas y sus entregas se mezclan con las de la semana que '
        'viene. La lista sigue saliendo prolija: no hay error, no hay hueco, '
        'solo una seccion menos que nadie extraña hasta que se pasa una '
        'entrega.',
  ),
  Mutacion(
    nombre: '277-las-secciones-salen-en-orden-de-llegada',
    archivo: 'lib/utils/secciones_recepciones.dart',
    buscar: '  for (final seccion in _Seccion.values) {',
    reemplazar: '  for (final seccion in porSeccion.keys) {',
    test: 'test/secciones_recepciones_test.dart',
    porque:
        'Recorrer las claves del mapa en vez del enum es la "simplificacion" '
        'obvia —ya estan agrupadas, para que iterar las cinco— y rompe lo unico '
        'que esta HU vino a hacer: el orden de las secciones pasa a depender de '
        'en que orden llegaron los pedidos. Con la primera entrega del dia '
        'siendo una vencida, "Vencidos" arranca arriba de "Sin fecha"; al dia '
        'siguiente, al reves. No falla nunca y no se puede reproducir a pedido.',
  ),
  Mutacion(
    nombre: '277-el-tope-esconde-vencidos-sin-avisar',
    archivo: 'lib/utils/secciones_recepciones.dart',
    buscar:
        '    if (recorta) filas.add(BotonVerRestantes(delGrupo.length - tope));',
    reemplazar: '    if (false) filas.add(BotonVerRestantes(0));',
    test: 'test/secciones_recepciones_test.dart',
    porque:
        'Saca el boton y convierte el tope en un OCULTAMIENTO: con 34 atrasados '
        'se ven 5 y las otras 29 desaparecen de la pantalla sin ninguna señal. '
        'Un vencido es un compromiso abierto con el proveedor y esconderlo es '
        'la regresion que la ventana movil ya tiene prohibida por escrito '
        '(`ventana_recepciones.dart`: las vencidas se muestran SIEMPRE). El '
        'contador del separador sigue diciendo 34, asi que ni siquiera el '
        'numero delata el faltante.',
  ),
  // ── #269 · la regla de atomicidad, ahora en un solo lugar ─────────────────
  Mutacion(
    nombre: '269-la-transaccion-deja-de-suspender-el-outbox',
    archivo: 'lib/data/transaccionador.dart',
    buscar:
        '    return sync != null ? sync.enTransaccion(cuerpo) : _db.transaction(cuerpo);',
    reemplazar: '    return _db.transaction(cuerpo);',
    test: 'test/transaccionador_test.dart',
    porque:
        'Manda TODO por la transaccion Drift cruda, salteando el '
        '`enTransaccion` del sincronizador. Parece equivalente —las dos abren '
        'una transaccion y las dos commitean— y por eso es la simplificacion '
        'que alguien hace al leer el archivo. Lo que se pierde es la SUSPENSION '
        'DEL DRENAJE: las inserciones en la cola dejan de participar de la '
        'transaccion y el envio a red puede dispararse a mitad de camino. El '
        'modo de falla no tiene sintoma: la escritura anda, la fila queda '
        '`pendiente`, y como ese estado es terminal el pull no la pisa y nadie '
        'la vuelve a encolar. Hasta #269 esta regla estaba copiada en SEIS '
        'services: seis oportunidades de escribir la septima al reves.',
  ),
  Mutacion(
    nombre: '269-el-outbox-vuelve-a-pisar-la-reprogramacion',
    archivo: 'lib/data/repositorios/repositorio_pedidos.dart',
    buscar: '      MapeadoresSupabase.pedido(filaCompleta),',
    reemplazar: "      {'id': id, 'estado': estado},",
    test: 'test/outbox_no_pisa_la_reprogramacion_test.dart',
    porque:
        'Vuelve a encolar el payload PARCIAL en cambiarEstado. El Outbox '
        'deduplica por (tabla, registro, accion) con DELETE + INSERT, asi que '
        'esa mutacion borra cualquier UPDATE pendiente del mismo pedido: '
        'reprogramar sin señal y despues confirmar hace desaparecer la fecha '
        'nueva, que nunca viaja. NO HAY NINGUN ERROR ni sintoma local: la fila '
        'en Drift tiene la fecha bien, asi que en ese dispositivo todo se ve '
        'correcto y la divergencia aparece recien en el otro, o despues de '
        'reinstalar. El payload parcial parece una optimizacion razonable '
        '("para que mandar la fila entera si solo cambio el estado"), y es '
        'exactamente la trampa.',
  ),
  Mutacion(
    nombre: '269-el-superadmin-puede-tocar-el-menu',
    archivo: 'lib/utils/acciones_tarjeta_pedido.dart',
    buscar:
        '        habilitada: !esSuperAdmin,\n        motivo: esSuperAdmin ? motivoSuperAdmin : null,\n      ),\n    );\n  }\n\n  if (TransicionesPedido.esCancelable(estado)) {',
    reemplazar:
        '        habilitada: true,\n        motivo: null,\n      ),\n    );\n  }\n\n  if (TransicionesPedido.esCancelable(estado)) {',
    test: 'test/acciones_tarjeta_pedido_test.dart',
    porque:
        'Le habilita al superadministrador la accion de cambiar la fecha. El '
        'superadmin LEE todos los negocios y no ESCRIBE en ninguno (HU-247): '
        'como la app es offline-first, su cambio se guarda local, el push '
        'muere con RLS 42501 y le queda un dato divergente que solo existe en '
        'su dispositivo, sin ningun cartel. Es la misma familia de bug que '
        '#259. Y no se caza mirando la pantalla: el menu se ve igual de bien.',
  ),
  Mutacion(
    nombre: '269-se-puede-reprogramar-lo-que-ya-paso',
    archivo: 'lib/utils/transiciones_pedido.dart',
    buscar:
        '  static bool esReprogramable(String estado) =>\n      estado == EstadosPedido.enviado || estado == EstadosPedido.enEspera;',
    reemplazar: '  static bool esReprogramable(String estado) => true;',
    test: 'test/acciones_tarjeta_pedido_test.dart',
    porque:
        'Deja reprogramar una entrega YA RECIBIDA, facturada o pagada. Mover '
        'esa fecha reescribe el pasado: los reportes y el historial de precios '
        'pasan a contar la compra en un dia en el que no ocurrio, y no hay '
        'forma de notar que el numero cambio. Un `=> true` parece inofensivo '
        'porque el menu sigue viendose normal.',
  ),
  Mutacion(
    nombre: '269-la-reprogramacion-de-agenda-muere-en-el-push',
    archivo: 'lib/services/servicio_transiciones_pedido.dart',
    buscar: '      if (agendaId != null && nuevaFecha != null) {',
    reemplazar: '      if (false) {',
    test: 'test/servicio_transiciones_pedido_test.dart',
    porque:
        'Saca la validacion previa del indice unico '
        '`ux_pedidos_ocurrencia (agenda_id, fecha_recepcion_solicitada)`. La '
        'base local NO replica ese indice, asi que reprogramar una entrega '
        'recurrente encima de otra de la misma serie se escribe local sin '
        'problema: el usuario ve la fecha cambiada, y el push muere en '
        'dead-letter sin que nadie se entere. El chequeo parece defensivo y de '
        'mas —la base local lo acepta— y es justo por eso que hace falta.',
  ),
  // ── #273 · trazabilidad del pedido ────────────────────────────────────────
  Mutacion(
    nombre: '273-el-reenvio-pisa-la-fecha-de-envio',
    archivo: 'lib/data/repositorios/repositorio_pedidos.dart',
    buscar: '      envio != null && previo.fechaEnvio == null;',
    reemplazar: '      envio != null;',
    test: 'test/registro_envio_pedido_test.dart',
    porque:
        'Hace que re-enviar un pedido corregido (HU-141) SOBRESCRIBA la fecha '
        'de envio original. Se pierde para siempre el momento en que ese '
        'pedido salio de la casa —el hecho que la trazabilidad quiere '
        'mostrar— y queda en su lugar el de una correccion. Sacar la segunda '
        'condicion parece una simplificacion sin consecuencias: la columna se '
        'escribe igual y la pantalla muestra una fecha valida. Nadie nota que '
        'es la fecha equivocada.',
  ),
  Mutacion(
    nombre: '273-la-auditoria-vuelve-a-fecharse-en-el-flush',
    archivo: 'lib/data/repositorios/repositorio_auditoria.dart',
    buscar: "      'ocurrido_en': ocurrio.toUtc().toIso8601String(),\n",
    reemplazar: '',
    test: 'test/repositorio_auditoria_ocurrido_en_test.dart',
    porque:
        'Saca la fecha del hecho del payload. La tabla remota tiene '
        '`created_at DEFAULT now()`, asi que Postgres vuelve a estampar el '
        'momento del FLUSH: como la app es offline-first, un hecho del lunes '
        'que se sube el jueves queda fechado el jueves. Una auditoria con la '
        'fecha del flush no sirve para auditar, que es su unico trabajo, y no '
        'hay ningun error: la fila sube bien y la fecha se ve plausible.',
  ),
  Mutacion(
    nombre: '273-el-primer-recibido-pasa-a-ser-el-ultimo',
    archivo: 'lib/utils/trazabilidad_pedido.dart',
    buscar:
        '          (a, b) => a.numeroRecepcion <= b.numeroRecepcion ? a : b,',
    reemplazar:
        '          (a, b) => a.numeroRecepcion >= b.numeroRecepcion ? a : b,',
    test: 'test/trazabilidad_pedido_test.dart',
    porque:
        'Invierte cual recepcion responde "cuando se recibio": con parciales '
        'pasa a mostrar la ULTIMA en vez de la primera. Son dos preguntas '
        'distintas —cuando llego la mercaderia por primera vez, contra cuando '
        'termino de llegar— y la segunda hace ver como tardio un pedido que '
        'llego a tiempo y se completo despues. Un pedido con UNA sola '
        'recepcion, que es el caso comun, da lo mismo con las dos versiones: '
        'por eso no se caza mirando la pantalla.',
  ),
  Mutacion(
    nombre: '273-el-envio-sin-registrar-se-lee-como-no-enviado',
    archivo: 'lib/utils/trazabilidad_pedido.dart',
    buscar:
        "          : (pedido.estado == 'borrador'\n"
        '                ? MotivoSinDato.noOcurrio\n'
        '                : MotivoSinDato.anteriorAlRegistro),',
    reemplazar: '          : MotivoSinDato.noOcurrio,',
    test: 'test/trazabilidad_pedido_test.dart',
    porque:
        'Hace que TODO pedido sin fecha de envio diga "todavia no", incluidos '
        'los anteriores a #273, que SI se enviaron pero cuyo envio la app de '
        'entonces no guardaba. La trazabilidad pasa a afirmar algo falso sobre '
        'todo el historial —que esos pedidos nunca salieron— en vez de admitir '
        'que el dato no se guardaba. Unificar los dos casos parece una '
        'simplificacion obvia y es la diferencia entre "no paso" y "no lo se".',
  ),
];
