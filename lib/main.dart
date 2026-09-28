import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'database/database.dart';
import 'services/servicio_configuracion.dart';
import 'services/servicio_diagnostico_supabase.dart';
import 'services/servicio_inicializacion.dart';
import 'screens/onboarding_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/superadmin_screen.dart';
import 'controllers/controlador_onboarding.dart';
import 'controllers/controlador_dashboard.dart';
import 'controllers/controlador_proveedores.dart';
import 'controllers/controlador_recetas.dart';
import 'controllers/controlador_insumos.dart';
import 'controllers/controlador_ventana_recepciones.dart';
import 'controllers/controlador_recibir.dart';
import 'controllers/controlador_metricas.dart';
import 'controllers/controlador_pagos.dart';
import 'controllers/controlador_motivos_recepcion.dart';
import 'controllers/controlador_categorias.dart';
import 'controllers/controlador_proveedor_categorias.dart';
import 'services/servicio_preferencias_usuario.dart';
import 'services/servicio_sesion.dart';
import 'utils/escala_texto.dart';
import 'services/servicio_superadmin.dart';
import 'services/servicio_conflictos.dart';
import 'services/servicio_descarga_negocio.dart';
import 'services/servicio_sincronizacion_supabase.dart';
import 'services/servicio_configuracion_negocio.dart';
import 'services/servicio_costos_receta.dart';
import 'services/servicio_precios.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/servicio_recepciones.dart';
import 'services/servicio_recepciones_admin.dart';
import 'services/servicio_reparacion_facturas.dart';
import 'services/servicio_facturacion.dart';
import 'services/servicio_pagos.dart';
import 'services/servicio_procesar_recepcion.dart';
import 'services/servicio_ocr_remito.dart';
import 'services/servicio_pedidos.dart';
import 'services/servicio_pedidos_recurrentes.dart';
import 'services/servicio_transiciones_pedido.dart';
import 'utils/ocr/fabrica_reconocedor.dart';
import 'services/servicio_acceso.dart';
import 'services/servicio_activacion.dart';
import 'services/servicio_registro_negocio.dart';
import 'services/servicio_gestion_equipo.dart';
import 'services/servicio_recuperacion_password.dart';
import 'data/almacen_seguro/almacen_local_supabase_seguro.dart';
import 'data/almacen_seguro/fabrica_almacen_seguro.dart';
import 'data/repositorios/descartador_cola_drift.dart';
import 'data/repositorios/repositorio_cursores_pull.dart';
import 'data/repositorios/repositorio_identidad_remota.dart';
import 'data/repositorios/repositorio_verificacion_email.dart';
import 'data/repositorios/repositorio_codigos_activacion.dart';
import 'services/servicio_motivos_recepcion.dart';
import 'services/servicio_categorias.dart';
import 'services/servicio_proveedor_categorias.dart';
import 'services/servicio_adjuntos.dart';
import 'services/backend_adjuntos.dart';
import 'utils/adjuntos/procesador_imagenes_compress.dart';
import 'data/fabrica_repositorios.dart';
import 'services/servicio_trazabilidad_pedido.dart';

/// Normaliza la URL de Supabase a la URL BASE del proyecto.
/// `Supabase.initialize` agrega `/rest/v1/` por su cuenta; si el `.env` ya la
/// incluye (o tiene barras finales), la quitamos para no duplicar el path
/// (causa de "Failed to fetch ... /rest/v1//rest/v1/...").
String _normalizarUrlSupabase(String url) {
  var u = url.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  for (final sufijo in ['/rest/v1', '/auth/v1', '/storage/v1']) {
    if (u.endsWith(sufijo)) {
      u = u.substring(0, u.length - sufijo.length);
    }
  }
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u;
}

void main() async {
  // Asegurar la inicialización de bindings para Flutter nativo y web
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializar variables de entorno (.env)
  await ServicioConfiguracion.inicializar();

  // Inicializar Supabase si las credenciales están disponibles
  final supabaseUrl = _normalizarUrlSupabase(
    ServicioConfiguracion.obtener('SUPABASE_URL'),
  );
  final supabaseKey = ServicioConfiguracion.obtener('SUPABASE_ANON_KEY');

  // HU-036: almacén CIFRADO de secretos locales (Android Keystore / iOS Keychain).
  // En web queda respaldado por SharedPreferences: la implementación web del
  // paquete es experimental y sin hardware, así que no aportaría seguridad real
  // (ahí la sesión se protege con HTTPS + anti-XSS + rotación de tokens y RLS).
  final almacenSeguro = crearAlmacenSeguro();
  final claveSesionSupabase = supabaseUrl.isEmpty
      ? null
      : AlmacenLocalSupabaseSeguro.claveDesdeUrl(supabaseUrl);

  if (supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty) {
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseKey,
      // HU-036: el JSON de la sesión (con el REFRESH TOKEN, el secreto más
      // valioso del dispositivo) deja de guardarse en claro. Solo en nativo: en
      // web la sesión vive directo en window.localStorage y no pasa por
      // shared_preferences, así que se mantiene el default.
      authOptions: almacenSeguroEsCifrado
          ? FlutterAuthClientOptions(
              localStorage: AlmacenLocalSupabaseSeguro(
                seguro: almacenSeguro,
                claveSesion: claveSesionSupabase!,
              ),
            )
          : const FlutterAuthClientOptions(),
    );

    // Verificar la conexión en modo debug para detectar problemas tempranamente
    if (kDebugMode) {
      final diagnostico = await ServicioDiagnosticoSupabase.verificar();
      debugPrint(diagnostico.resumen);
      if (!diagnostico.exitoso && diagnostico.detalleError != null) {
        debugPrint('[SUPABASE] Detalle: ${diagnostico.detalleError}');
      }
    }
  } else {
    debugPrint(
      '[SUPABASE] ⚠️ Credenciales no configuradas — funcionando en modo offline.',
    );
  }

  // 1. Inicializar Base de Datos Drift
  final baseDatos = BaseDatosApp();
  // HU-028: bitácora LOCAL de conflictos de sincronización (no se sincroniza).
  final servicioConflictos = ServicioConflictos(baseDatos);

  // Inicializar Servicio de Sesión. HU-036: la identidad se lee/escribe en el
  // almacén cifrado, con migración read-through desde las claves viejas en claro
  // (ninguna instalación existente se desloguea al actualizar).
  final sesion = ServicioSesion(
    almacenSeguro: almacenSeguro,
    migrarDesdePrefs: almacenSeguroEsCifrado,
    claveSesionSupabase: claveSesionSupabase,
  );
  await sesion.inicializar();
  // HU-266: expiración ABSOLUTA de la sesión local. Si venció el plazo desde el
  // login, se descarta acá —antes de armar la sincronización— para que una sesión
  // vencida no dispare el pull ni deje identidad stale; el usuario cae en el login.
  await sesion.descartarSesionSiVencida();

  // HU-054: preferencias de apariencia del DISPOSITIVO. Se hidratan antes del
  // primer frame para que la app no arranque con la letra por defecto y salte al
  // tamaño elegido un instante después.
  final preferenciasUsuario = ServicioPreferenciasUsuario();
  await preferenciasUsuario.inicializar();

  // 2. Inicializar Preferencias y aplicar bypass de Review si corresponde
  final servicioInit = await ServicioInicializacion.inicializar(
    baseDatos,
    sesion,
  );

  // 3. Armar la capa de datos (offline-first) y la conexión de sincronización con Supabase.
  //    El "Model" remoto (Supabase) se encapsula en ServicioSincronizacionSupabase.
  ServicioSincronizacionSupabase? servicioSync;
  ServicioSuperAdmin? servicioSuperAdmin;
  ServicioDescargaNegocio? servicioDescarga;
  // Backend de identidad (Supabase Auth + tablas remotas) detrás de un contrato,
  // para que la lógica de login sea testeable (HU-072). Null = sin backend.
  RepositorioIdentidadRemota? identidadRemota;
  // Verificación por email (HU-076 Fase 2): autoservicio "olvidé mi contraseña".
  // Null sin backend ⇒ la recuperación no está disponible (es online-only).
  RepositorioVerificacionEmail? verificacionEmail;
  RepositorioCodigosActivacion? repoCodigos;
  if (supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty) {
    identidadRemota = RepositorioIdentidadRemotaSupabase(
      Supabase.instance.client,
    );
    verificacionEmail = RepositorioVerificacionEmailSupabase(
      Supabase.instance.client,
    );
    repoCodigos = RepositorioCodigosActivacionSupabase(
      Supabase.instance.client,
    );

    // Descarga (pull) de datos de un negocio Supabase → local. Reutilizable por
    // el SuperAdmin y por el login/recarga de un usuario normal. Se crea antes que
    // el servicio de sync porque éste la usa para el pull al reconectar (HU-027).
    servicioDescarga = ServicioDescargaNegocio(
      Supabase.instance.client,
      baseDatos,
      // HU-028: bitácora de conflictos de sincronización.
      conflictos: servicioConflictos,
      // HU-045: el cocinero baja las vistas operativas (sin costo/precio/margen).
      rolActual: () => sesion.usuarioRol,
      // HU-090: al completar el pull completo, marca el negocio como hidratado.
      guarda: sesion,
      // #250: cursores del pull incremental. Con el repo inyectado, cada tabla
      // baja sólo lo cambiado desde la última entrada al negocio; sin él (tests,
      // modo local) el pull sigue siendo completo.
      cursores: RepositorioCursoresPullDrift(baseDatos),
    );

    servicioSync = ServicioSincronizacionSupabase(
      baseDatos: baseDatos,
      clienteSupabase: Supabase.instance.client,
      conflictos: servicioConflictos, // HU-028
      // HU-027: al recuperar conexión, además del push, baja las novedades del
      // negocio activo (cambios hechos por otros dispositivos). Si no hay negocio
      // en sesión, no hay nada que descargar.
      alReconectar: () async {
        final negocioId = sesion.negocioId;
        if (negocioId.isEmpty) return;
        await servicioDescarga?.descargarNegocio(negocioId);
      },
    );
    servicioSync.monitorearConectividad();
    servicioSync.sincronizarAlReconectar(); // push + pull al arrancar

    // SuperAdmin (HU-037): lectura global de negocios + descarga a la base local.
    servicioSuperAdmin = ServicioSuperAdmin(
      Supabase.instance.client,
      servicioDescarga,
    );
  }

  // Fábrica de repositorios + servicios de negocio (MVC con capa de servicios).
  final fabrica = FabricaRepositorios.crear(db: baseDatos, sync: servicioSync);
  final servicioConfiguracion = ServicioConfiguracionNegocio(
    fabrica.configuracion,
  );
  final servicioPrecios = ServicioPrecios(baseDatos, fabrica.sync);
  // #273: los pasos del pedido para su detalle. Service propio y no un metodo
  // mas de ServicioPedidos: necesita recepciones, la cadena factura->pago y la
  // tabla de usuarios, tres cosas que aquel no tiene ni tiene por que tener.
  final servicioTrazabilidad = ServicioTrazabilidadPedido(
    fabrica.recepciones,
    fabrica.cuentaCorriente,
    fabrica.usuarios,
  );
  // HU-152: resuelve el costo de una receta CON mano de obra. Compone el DAO
  // con la configuración del negocio; el DAO sigue devolviendo sólo insumos.
  final servicioCostosReceta = ServicioCostosReceta(
    baseDatos,
    servicioConfiguracion,
  );
  final servicioRecepciones = ServicioRecepciones(
    baseDatos,
    fabrica.recepciones,
    fabrica.auditoria,
    fabrica.sync,
  );
  final servicioFacturacion = ServicioFacturacion(
    baseDatos,
    fabrica.facturas,
    fabrica.cuentaCorriente,
    fabrica.auditoria,
    fabrica.sync,
    sesion, // HU-090: guarda del primer pull
  );
  final servicioPagos = ServicioPagos(
    baseDatos,
    fabrica.cuentaCorriente,
    fabrica.facturas,
    fabrica.auditoria,
    fabrica.sync,
    sesion, // HU-090: guarda del primer pull
  );
  // #229: procesar una recepción = factura + renglones + costeo + pago en UNA
  // transacción. Orquesta los services financieros de arriba.
  final servicioProcesarRecepcion = ServicioProcesarRecepcion(
    baseDatos,
    servicioFacturacion,
    servicioPagos,
    servicioPrecios,
    fabrica.facturaItems,
    servicioConfiguracion,
    fabrica.sync,
  );
  // HU-141: autoridad única de las transiciones de estado de pedidos (valida
  // matriz + audita). ServicioPedidos delega en ella sus cambios de estado.
  final servicioTransiciones = ServicioTransicionesPedido(
    baseDatos,
    fabrica.pedidos,
    fabrica.recepciones,
    fabrica.auditoria,
    fabrica.sync,
  );
  // #262: relación proveedor↔categoría. La consume el selector de insumos por
  // categoría del armado de pedido.
  final servicioProveedorCategorias = ServicioProveedorCategorias(
    fabrica.proveedorCategorias,
    fabrica.categorias,
  );
  final servicioPedidos = ServicioPedidos(
    fabrica.pedidos,
    servicioTransiciones,
    servicioProveedorCategorias,
  );
  // HU-013: agendas de pedidos recurrentes. Reusa `servicioPedidos` sólo para
  // resolver los ítems sugeridos (insumos activos + precios de hoy) con la
  // misma regla que el armado manual.
  final servicioRecurrentes = ServicioPedidosRecurrentes(
    fabrica.pedidosRecurrentes,
    fabrica.pedidos,
    baseDatos,
    servicioPedidos,
  );
  // Login (HU-072): toda la lógica de acceso vive acá, no en el controlador.
  final servicioAcceso = ServicioAcceso(
    sesion,
    fabrica.usuarios,
    fabrica.negocios,
    identidadRemota,
    fabrica.sync,
    servicioDescarga,
    // HU-132: limpiador de cola independiente de la sync — la reconciliación de
    // tenant descarta la cola aunque la sincronización esté desactivada.
    DescartadorColaDrift(baseDatos),
  );
  // Códigos de activación (HU-075). Null sin backend: entonces no se puede validar
  // el código y, por lo tanto, no se puede crear un negocio.
  final servicioActivacion = repoCodigos == null
      ? null
      : ServicioActivacion(repoCodigos);
  // Gestión de equipo (HU-087): alta de miembros con cuenta Supabase Auth real
  // (Edge Function). Null-safe sin backend: el service exige sesión para crear.
  // Se construye ANTES del registro porque el alta del negocio lo usa para crear
  // las cuentas del equipo inicial en la nube (HU-088).
  final servicioGestionEquipo = ServicioGestionEquipo(
    fabrica.usuarios,
    sesion, // #257: negocio activo para el payload de las EF (lo usa el superadmin)
    identidadRemota,
  );
  // Recuperación de contraseña por el propio usuario (HU-076 Fase 2). Null-safe sin
  // backend: el service avisa que se necesita conexión (es online-only).
  final servicioRecuperacion = ServicioRecuperacionPassword(verificacionEmail);
  final servicioRegistro = ServicioRegistroNegocio(
    sesion,
    fabrica.negocios,
    fabrica.usuarios,
    identidadRemota,
    servicioActivacion,
    servicioGestionEquipo,
  );
  final servicioMotivos = ServicioMotivosRecepcion(fabrica.motivosRecepcion);
  // #262: catálogo de categorías de insumo (entidad + CRUD).
  final servicioCategorias = ServicioCategorias(fabrica.categorias);
  // `servicioProveedorCategorias` ya se construyó arriba (lo usa ServicioPedidos).
  // Adjuntos/remitos (HU-066): backend BLOB local + compresión de imágenes.
  // #248: con backend, los bytes que el pull ya no baja (solo metadatos) se
  // piden bajo demanda al abrir el visor y quedan cacheados; sin backend, el
  // dispositivo es local puro y solo ve lo que él mismo adjuntó.
  final servicioAdjuntos = ServicioAdjuntos(
    BackendAdjuntosBlob(
      fabrica.adjuntos,
      remoto: (supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty)
          ? ObtenedorRemotoAdjuntosSupabase(Supabase.instance.client)
          : null,
    ),
    const ProcesadorImagenesCompress(),
  );
  // Vista admin de recepciones/pagos (HU-067): compone recepciones + pedido +
  // proveedor + remito + facturación para la sección "Recepciones por facturar".
  final servicioRecepcionesAdmin = ServicioRecepcionesAdmin(
    baseDatos,
    fabrica.recepciones,
    fabrica.adjuntos,
    fabrica.facturas,
    fabrica.auditoria, // HU-143: audita la edición del total recibido manual
    fabrica
        .sync, // HU-143: encola el UPDATE de pedidos.total al editar la última
  );
  // Sugerencias por OCR del remito (HU-144): motor on-device vía fábrica
  // (ML Kit en Android/iOS; null-object en web/desktop → sin botón).
  final servicioOcrRemito = ServicioOcrRemito(
    crearReconocedorTexto(),
    fabrica.adjuntos,
  );

  // Reparación ÚNICA (HU-070) de facturas huérfanas creadas antes del fix: re-vincula
  // el proveedor y crea el débito de cuenta corriente que faltó. Best-effort: si falla,
  // no bloquea el arranque. El flag evita que corra en cada inicio.
  try {
    final prefs = await SharedPreferences.getInstance();
    const flagReparacion = 'insuma_reparacion_facturas_huerfanas_v1';
    if (!(prefs.getBool(flagReparacion) ?? false)) {
      await ServicioReparacionFacturas(
        baseDatos,
        fabrica.facturas,
        fabrica.cuentaCorriente,
        fabrica
            .sync, // HU-086: reparación atómica (Outbox participa de la transacción)
      ).reparar();
      await prefs.setBool(flagReparacion, true);
    }
  } catch (e) {
    debugPrint('[REPARACION] Facturas huérfanas (HU-070): $e');
  }

  /// --- CREDENCIALES PARA REVISORES DE TIENDAS ---
  /// Google Play Console > App content > App access:
  ///   - Código de acceso: INSUMA.MAGGIE
  ///   - Instrucciones (HU-127, la app abre en Iniciar Sesión): "Abrir la app →
  ///     tocar '¿No tiene cuenta? Crear mi negocio' → avanzar al paso 3 (Código
  ///     de Invitación) e ingresar el código 'INSUMA.MAGGIE' → La app carga datos
  ///     de demostración y accede directamente al Dashboard con funcionalidad
  ///     completa."
  ///
  /// Apple App Store Connect > App Review Information:
  ///   - Mismas instrucciones que Google Play.
  ///   - Contact: [email del desarrollador]

  runApp(
    MultiProvider(
      providers: [
        Provider<BaseDatosApp>.value(value: baseDatos),
        Provider<ServicioInicializacion>.value(value: servicioInit),
        // HU-013: lo consumen la ficha del proveedor (ABM de las agendas) y el
        // disparo del generador al entrar al negocio.
        Provider<ServicioPedidosRecurrentes>.value(value: servicioRecurrentes),
        // HU-013: el slide 2 del wizard necesita la oferta de insumos del
        // proveedor. Hasta ahora este servicio se inyectaba sólo por
        // constructor a ControladorRecibir; el wizard NO puede usar ese
        // controlador —lee y escribe el borrador de pedido vivo del usuario—
        // así que va al árbol como dependencia propia.
        Provider<ServicioPedidos>.value(value: servicioPedidos),
        if (servicioSync != null)
          Provider<ServicioSincronizacionSupabase>.value(value: servicioSync),
        Provider<ServicioSuperAdmin?>.value(value: servicioSuperAdmin),
        // Códigos de activación (HU-075): null sin backend.
        Provider<ServicioActivacion?>.value(value: servicioActivacion),
        // Recuperación de contraseña (HU-076 Fase 2): la consume el diálogo de login.
        Provider<ServicioRecuperacionPassword>.value(
          value: servicioRecuperacion,
        ),
        Provider<ServicioConfiguracionNegocio>.value(
          value: servicioConfiguracion,
        ),
        Provider<ServicioRecepciones>.value(value: servicioRecepciones),
        Provider<ServicioFacturacion>.value(value: servicioFacturacion),
        Provider<ServicioPagos>.value(value: servicioPagos),
        Provider<ServicioProcesarRecepcion>.value(
          value: servicioProcesarRecepcion,
        ),
        // HU-017: la pantalla de historial de precios consulta el servicio.
        Provider<ServicioPrecios>.value(value: servicioPrecios),
        Provider<ServicioTrazabilidadPedido>.value(value: servicioTrazabilidad),
        Provider<ServicioMotivosRecepcion>.value(value: servicioMotivos),
        Provider<ServicioCategorias>.value(value: servicioCategorias),
        Provider<ServicioProveedorCategorias>.value(
          value: servicioProveedorCategorias,
        ),
        Provider<ServicioAdjuntos>.value(value: servicioAdjuntos),
        // HU-144: el modal de verificación consulta si hay motor de escaneo.
        Provider<ServicioOcrRemito>.value(value: servicioOcrRemito),
        ChangeNotifierProvider<ServicioSesion>.value(value: sesion),
        ChangeNotifierProvider<ServicioPreferenciasUsuario>.value(
          value: preferenciasUsuario,
        ),
        ChangeNotifierProvider<ControladorOnboarding>(
          create: (_) => ControladorOnboarding(
            sesion,
            servicioAcceso,
            servicioRegistro,
            servicioActivacion,
          ),
        ),
        ChangeNotifierProvider<ControladorDashboard>(
          create: (_) =>
              ControladorDashboard(sesion, baseDatos, servicioGestionEquipo),
        ),
        ChangeNotifierProvider<ControladorProveedores>(
          create: (_) => ControladorProveedores(
            sesion,
            baseDatos,
            fabrica.sync,
            servicioDescarga,
          ),
        ),
        ChangeNotifierProvider<ControladorRecetas>(
          create: (_) => ControladorRecetas(
            sesion,
            baseDatos,
            servicioCostosReceta,
            fabrica.sync,
            servicioDescarga,
          ),
        ),
        // HU-013: cuántos tramos de 7 días está abierta la pantalla de
        // Recepciones. Va a nivel app y NO dentro de la pestaña: el dashboard
        // la destruye al cambiar de solapa, y si viviera ahí la ventana se
        // resetearía cada vez que el usuario va a Pedidos y vuelve.
        ChangeNotifierProvider<ControladorVentanaRecepciones>(
          create: (_) => ControladorVentanaRecepciones(),
        ),
        ChangeNotifierProvider<ControladorInsumos>(
          create: (_) => ControladorInsumos(
            sesion,
            baseDatos,
            fabrica.sync,
            servicioPrecios,
            fabrica.auditoria,
            servicioDescarga,
          ),
        ),
        ChangeNotifierProvider<ControladorRecibir>(
          create: (_) => ControladorRecibir(
            sesion,
            baseDatos,
            servicioRecepciones,
            fabrica.sync,
            servicioPedidos,
          ),
        ),
        ChangeNotifierProvider<ControladorMetricas>(
          create: (_) =>
              ControladorMetricas(sesion, baseDatos, servicioCostosReceta),
        ),
        ChangeNotifierProvider<ControladorPagos>(
          create: (_) => ControladorPagos(
            sesion,
            baseDatos,
            servicioPagos,
            servicioRecepcionesAdmin,
          ),
        ),
        ChangeNotifierProvider<ControladorMotivosRecepcion>(
          create: (_) => ControladorMotivosRecepcion(sesion, servicioMotivos),
        ),
        ChangeNotifierProvider<ControladorCategorias>(
          create: (_) => ControladorCategorias(sesion, servicioCategorias),
        ),
        ChangeNotifierProvider<ControladorProveedorCategorias>(
          create: (_) => ControladorProveedorCategorias(
            sesion,
            servicioProveedorCategorias,
          ),
        ),
      ],
      child: const InsumaApp(),
    ),
  );
}

/// Widget raíz de la aplicación INSUMA
class InsumaApp extends StatelessWidget {
  const InsumaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'INSUMA Kitchen',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(
            0xFF72BDE8,
          ), // Celeste característico de INSUMA
          brightness: Brightness.light,
        ),
      ),
      // La escala se inyecta acá y no en el ThemeData porque `textScaler` vive en
      // el MediaQuery: es del entorno, no del tema. El `builder` envuelve todas
      // las rutas, incluidos los diálogos, que se montan fuera del árbol de
      // `home` y si no quedarían con la letra sin escalar.
      // HU-054: el `watch` va acá DENTRO y no en el build de arriba. Puesto
      // arriba, cada cambio de tamaño reconstruye el MaterialApp entero: se
      // vuelve a correr `ColorScheme.fromSeed` —un cálculo HCT completo— y se
      // invalida el Navigator con sus rutas apiladas. Y se paga justo mientras
      // el usuario compara tamaños tocando una opción tras otra. El `builder`
      // cuelga por debajo del MaterialApp, así que repinta sólo las rutas y deja
      // el tema intacto.
      builder: (context, child) => EscaladorDeTexto(
        preferencia: context.watch<ServicioPreferenciasUsuario>().tipografia,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const PantallaInicial(),
    );
  }
}

/// Pantalla inicial: enruta al usuario según el estado de la SESIÓN, de forma
/// reactiva. Al guardar/limpiar la sesión, ServicioSesion notifica y este widget
/// se reconstruye hacia el destino correcto (sin navegación manual).
class PantallaInicial extends StatelessWidget {
  const PantallaInicial({super.key});

  @override
  Widget build(BuildContext context) {
    final sesion = context.watch<ServicioSesion>();

    // SuperAdmin global (HU-037) sin negocio activo → su panel de control dedicado.
    if (sesion.esSuperAdmin && sesion.negocioId.isEmpty) {
      return const PantallaSuperAdmin();
    }

    // Usuario autenticado (o SuperAdmin que ya entró a un negocio) → Dashboard.
    if (sesion.estaAutenticado) {
      return const PantallaDashboard();
    }

    // Sin sesión → Onboarding / Login.
    return PantallaOnboarding(alCompletar: () {});
  }
}
