import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart';
import '../database/database.dart';
import 'seed_data.dart';
import 'servicio_configuracion.dart';
import 'servicio_autenticacion.dart';
import 'servicio_sesion.dart';

/// Servicio encargado de la inicialización de la app en su primer arranque.
/// Gestiona la precarga de datos semilla (seed data) en caso de que esté activo
/// el modo de revisión de tiendas (bypass de autenticación/onboarding).
class ServicioInicializacion {
  final BaseDatosApp baseDatos;
  final SharedPreferences preferenciales;

  /// HU-036: la sesión demo se abre a través de [ServicioSesion] (único escritor
  /// de la identidad, ahora en el almacén cifrado). Antes este servicio escribía
  /// las claves directo en SharedPreferences.
  final ServicioSesion? sesion;

  ServicioInicializacion({
    required this.baseDatos,
    required this.preferenciales,
    this.sesion,
  });

  /// Inicializa las preferencias compartidas y verifica si corresponde aplicar el bypass.
  static Future<ServicioInicializacion> inicializar(
    BaseDatosApp db, [
    ServicioSesion? sesion,
  ]) async {
    final prefs = await SharedPreferences.getInstance();
    final servicio = ServicioInicializacion(
      baseDatos: db,
      preferenciales: prefs,
      sesion: sesion,
    );
    await servicio._verificarAplicarBypass();
    return servicio;
  }

  /// Para activar el modo de revisión de tiendas (bypass):
  /// 1. Establecer APP_STORE_REVIEW=true en assets/.env
  /// 2. O compilar con: flutter run --dart-define=APP_STORE_REVIEW=true
  /// IMPORTANTE: Revertir a false antes de publicar en producción.
  ///
  /// Verifica si el binario actual tiene la flag de revisión y no ha hecho el onboarding.
  Future<void> _verificarAplicarBypass() async {
    // Variable de compilación de Dart o de .env para bypass
    final bool esRevisionTienda = ServicioConfiguracion.obtenerBooleano(
      'APP_STORE_REVIEW',
      valorPorDefecto: false,
    );
    final bool onboardingListo =
        preferenciales.getBool('insuma_onboarding_ok') ?? false;

    if (esRevisionTienda && !onboardingListo) {
      await aplicarSemillaDemostracion();
    }
  }

  /// Carga de forma atómica la base de datos local SQLite con registros semilla
  /// para que los revisores de Apple o Google tengan un entorno de prueba 100% operativo offline.
  Future<void> aplicarSemillaDemostracion() async {
    final uuid = const Uuid();
    final negocioId = uuid.v4();

    // 1. Crear Negocio Demo
    await baseDatos
        .into(baseDatos.negocios)
        .insert(
          NegociosCompanion.insert(
            id: negocioId,
            nombre: 'La Cocina de Insuma',
            tipo: 'restaurante',
            pais: const Value('Argentina'),
            email: const Value('hola@insuma.app'),
            fechaCreacion: Value(DateTime.now()),
          ),
        );

    // 2. Crear Usuarios de prueba (Admin para revisión y Cocinero para test de roles)
    const adminEmail = 'admin@insuma.app';
    final adminId = uuid.v4();
    await baseDatos
        .into(baseDatos.usuarios)
        .insert(
          UsuariosCompanion.insert(
            id: adminId,
            negocioId: negocioId,
            nombre: 'Admin Demo',
            rol: const Value('admin'),
            email: const Value(adminEmail),
            passwordHash: Value(
              ServicioAutenticacion.hashearPassword(
                'insuma1234',
                salt: adminEmail,
              ),
            ),
            activo: const Value(true),
            fechaCreacion: Value(DateTime.now()),
          ),
        );

    const cocineroEmail = 'cocinero@insuma.app';
    final cocineroId = uuid.v4();
    await baseDatos
        .into(baseDatos.usuarios)
        .insert(
          UsuariosCompanion.insert(
            id: cocineroId,
            negocioId: negocioId,
            nombre: 'Cocinero Demo',
            rol: const Value('cocinero'),
            email: const Value(cocineroEmail),
            passwordHash: Value(
              ServicioAutenticacion.hashearPassword(
                'insuma1234',
                salt: cocineroEmail,
              ),
            ),
            activo: const Value(true),
            fechaCreacion: Value(DateTime.now()),
          ),
        );

    // 3. Crear Proveedores y guardar mapeo de IDs originales a los nuevos generados
    final Map<String, String> proveedoresIdsMapeados = {};
    for (final p in seedProveedores) {
      final idViejo = p['id']!;
      final idNuevo = uuid.v4();
      proveedoresIdsMapeados[idViejo] = idNuevo;

      await baseDatos
          .into(baseDatos.proveedores)
          .insert(
            ProveedoresCompanion.insert(
              id: idNuevo,
              negocioId: negocioId,
              nombre: p['nombre']!,
              categoria: Value(p['categoria']),
              contacto: Value(p['contacto']),
              email: Value(p['email']),
              telefono: Value(p['telefono']),
              activo: const Value(true),
              fechaCreacion: Value(DateTime.now()),
            ),
          );
    }

    // 4. Crear Insumos semilla y asociar su historial de precios inicial
    for (final i in seedInsumos) {
      final insumoId = uuid.v4();

      // Asociaciones básicas para que la demo tenga relaciones lógicas
      String? provId;
      if (i['categoria'] == 'Bebidas') {
        provId =
            proveedoresIdsMapeados['e8ccfe93']; // proveedor demo de Bebidas
      } else if (i['categoria'] == 'Carnes') {
        provId = proveedoresIdsMapeados['prov13']; // proveedor demo de Carnes
      }

      await baseDatos
          .into(baseDatos.insumos)
          .insert(
            InsumosCompanion.insert(
              id: insumoId,
              negocioId: negocioId,
              nombre: i['nombre']!,
              categoria: i['categoria']!,
              unidad: i['unidad']!,
              costoPorUnidad: const Value(0.0),
              proveedorId: Value(provId),
              tipo: Value(i['tipo'] ?? 'ingrediente'),
              activo: const Value(true),
              fechaCreacion: Value(DateTime.now()),
            ),
          );

      // Historial de precios inicial en $0.0 (listo para ser actualizado)
      await baseDatos
          .into(baseDatos.historialPrecios)
          .insert(
            HistorialPreciosCompanion.insert(
              id: uuid.v4(),
              negocioId: negocioId,
              insumoId: insumoId,
              proveedorId: Value(provId),
              precioUnitarioNeto: 0.0,
              origen: 'ajuste_manual',
              referenciaId: const Value('semilla'),
              fechaRegistro: Value(DateTime.now()),
            ),
          );
    }

    // 5. Configurar la sesión activa. HU-036: se delega en ServicioSesion (único
    //    escritor de la identidad, que la persiste en el almacén cifrado) en vez
    //    de escribir las claves a mano en SharedPreferences.
    await preferenciales.setBool('insuma_onboarding_ok', true);
    await sesion?.guardarSesion(
      negocioId: negocioId,
      usuarioId: adminId,
      nombre: 'Admin Demo',
      rol: 'admin',
    );
    // HU-090: el negocio demo se siembra COMPLETO en local → ya está "hidratado". Se
    // marca su primer pull para que el admin demo pueda registrar facturas/pagos sin
    // conexión (los revisores de tienda operan offline).
    await sesion?.marcarPrimerPull(negocioId);
  }
}
