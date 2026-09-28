import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'servicio_configuracion.dart';

/// Resultado estructurado de la verificación de conexión con Supabase.
class ResultadoDiagnosticoSupabase {
  final bool exitoso;
  final String resumen;
  final String? detalleError;

  const ResultadoDiagnosticoSupabase({
    required this.exitoso,
    required this.resumen,
    this.detalleError,
  });

  @override
  String toString() => resumen;
}

/// Servicio de diagnóstico que verifica la conexión con Supabase en runtime.
///
/// Uso recomendado únicamente en modo debug (kDebugMode) durante el arranque
/// de la aplicación para detectar problemas de configuración tempranamente.
class ServicioDiagnosticoSupabase {
  ServicioDiagnosticoSupabase._();

  /// Verifica que las credenciales de Supabase sean válidas y que la conexión
  /// con el servidor sea funcional.
  ///
  /// Pasos:
  /// 1. Valida que las variables SUPABASE_URL y SUPABASE_ANON_KEY no estén vacías.
  /// 2. Verifica que Supabase haya sido inicializado.
  /// 3. Realiza una consulta de prueba real para confirmar conectividad.
  static Future<ResultadoDiagnosticoSupabase> verificar() async {
    // Paso 1: Validar que las credenciales estén cargadas en la configuración
    final url = ServicioConfiguracion.obtener('SUPABASE_URL');
    final anonKey = ServicioConfiguracion.obtener('SUPABASE_ANON_KEY');

    if (url.isEmpty) {
      return const ResultadoDiagnosticoSupabase(
        exitoso: false,
        resumen: '[SUPABASE] ❌ SUPABASE_URL no está definida en assets/.env',
        detalleError:
            'La variable SUPABASE_URL está vacía. Verificar assets/.env.',
      );
    }

    if (anonKey.isEmpty) {
      return const ResultadoDiagnosticoSupabase(
        exitoso: false,
        resumen:
            '[SUPABASE] ❌ SUPABASE_ANON_KEY no está definida en assets/.env',
        detalleError:
            'La variable SUPABASE_ANON_KEY está vacía. Verificar assets/.env.',
      );
    }

    // Paso 2: Verificar que Supabase fue inicializado correctamente
    SupabaseClient cliente;
    try {
      cliente = Supabase.instance.client;
    } catch (e) {
      return ResultadoDiagnosticoSupabase(
        exitoso: false,
        resumen: '[SUPABASE] ❌ Supabase no fue inicializado correctamente',
        detalleError: e.toString(),
      );
    }

    // Paso 3: Verificar la URL configurada
    final urlConfigurada = ServicioConfiguracion.obtener('SUPABASE_URL');
    debugPrint('[SUPABASE] 🔍 Conectando a: $urlConfigurada');

    // Paso 4: Realizar una petición real de prueba para confirmar conectividad
    try {
      // Usamos una consulta de bajo impacto (HEAD a la tabla negocios, limite 1)
      // Si la tabla no existe, Supabase devuelve un error 404/42P01, lo cual
      // también confirma que la conexión y autenticación son válidas.
      await cliente.from('negocios').select('id').limit(1);

      return ResultadoDiagnosticoSupabase(
        exitoso: true,
        resumen: '[SUPABASE] ✅ Conexión exitosa — Proyecto: $urlConfigurada',
      );
    } on PostgrestException catch (e) {
      // Un error PostgreSQL (ej: tabla no encontrada, RLS denegado) confirma
      // que la conexión es válida pero hay un problema de esquema o permisos.
      if (e.code == '42P01') {
        return ResultadoDiagnosticoSupabase(
          exitoso: false,
          resumen:
              '[SUPABASE] ⚠️ Conexión OK, pero la tabla "negocios" no existe en el proyecto',
          detalleError:
              'Asegúrate de que el esquema de la base de datos esté creado en Supabase. Código: ${e.code}',
        );
      }
      if (e.code == 'PGRST301' || e.message.contains('JWT')) {
        return ResultadoDiagnosticoSupabase(
          exitoso: false,
          resumen:
              '[SUPABASE] ❌ SUPABASE_ANON_KEY inválida — Error de autenticación JWT',
          detalleError: e.message,
        );
      }
      // Otro error de Postgrest (ej: RLS bloqueó la consulta anónima — es esperado)
      return ResultadoDiagnosticoSupabase(
        exitoso: true,
        resumen:
            '[SUPABASE] ✅ Conexión OK (RLS activo — acceso anónimo restringido)',
        detalleError: '${e.code}: ${e.message}',
      );
    } catch (e) {
      // Error de red u otro error inesperado
      return ResultadoDiagnosticoSupabase(
        exitoso: false,
        resumen: '[SUPABASE] ❌ Error de red o configuración inesperado',
        detalleError: e.toString(),
      );
    }
  }
}
