import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../utils/paginacion_postgrest.dart';
import 'servicio_descarga_negocio.dart';

/// Representación liviana de un negocio para el panel del SuperAdmin (HU-037).
class NegocioSuperAdmin {
  final String id;
  final String nombre;
  final String tipo;
  final String? pais;
  final String? email;

  NegocioSuperAdmin({
    required this.id,
    required this.nombre,
    required this.tipo,
    this.pais,
    this.email,
  });

  factory NegocioSuperAdmin.desdeMapa(Map<String, dynamic> m) =>
      NegocioSuperAdmin(
        id: m['id'] as String,
        nombre: (m['nombre'] as String?) ?? 'Sin nombre',
        tipo: (m['tipo'] as String?) ?? '',
        pais: m['pais'] as String?,
        email: m['email'] as String?,
      );
}

/// Servicio del SuperAdmin global (HU-037).
///
/// El SuperAdmin es un usuario de CONTROL autenticado contra Supabase Auth (su rol
/// viaja en `app_metadata`). Lee la lista global de negocios, los crea/edita
/// directo en Supabase (autorizado por RLS `superadmin_*`, HU-042) y, al entrar a
/// uno, DESCARGA sus datos a la base local delegando en [ServicioDescargaNegocio]
/// (la descarga es genérica y reutilizable, no exclusiva de este rol).
class ServicioSuperAdmin {
  final SupabaseClient _supabase;
  final ServicioDescargaNegocio _descarga;

  ServicioSuperAdmin(this._supabase, this._descarga);

  /// Trae TODOS los negocios desde Supabase (vista global del SuperAdmin).
  ///
  /// Paginado por rango (HU-093): PostgREST corta cada request en `max_rows` (=1000), así
  /// que sin `.range()` la navegación del SuperAdmin se truncaría EN SILENCIO con >1000
  /// negocios. Orden ESTABLE `nombre, id` (el desempate por `id` es imprescindible porque
  /// `nombre` no es único: sin él, el rango podría saltear o duplicar filas entre páginas).
  Future<List<NegocioSuperAdmin>> listarNegocios() async {
    final filas = await PaginacionPostgrest.paginarTodo((desde, hasta) async {
      final res = await _supabase
          .from('negocios')
          .select('id, nombre, tipo, pais, email')
          .order('nombre')
          .order('id')
          .range(desde, hasta);
      return (res as List).cast<Map<String, dynamic>>();
    });
    return filas.map(NegocioSuperAdmin.desdeMapa).toList();
  }

  /// Crea un negocio nuevo escribiendo DIRECTO en Supabase (operación global del
  /// SuperAdmin) y lo refleja en la base local. Autorizado por la policy RLS
  /// `superadmin_insert_negocio` (HU-042).
  Future<void> crearNegocio({
    required String nombre,
    required String tipo,
    String pais = 'Argentina',
    String? email,
  }) async {
    final emailLimpio = (email ?? '').trim();
    final id = const Uuid().v4();
    await _supabase.from('negocios').insert(<String, dynamic>{
      'id': id,
      'nombre': nombre.trim(),
      'tipo': tipo,
      'pais': pais,
      'email': emailLimpio.isEmpty ? null : emailLimpio,
    });
    // Reflejo local reutilizando la descarga (trae el negocio recién creado).
    await _descarga.descargarNegocio(id);
  }

  /// Edita los datos de un negocio existente directo en Supabase y actualiza la
  /// cache local. Autorizado por la policy RLS `superadmin_update_negocio` (HU-042).
  Future<void> editarNegocio({
    required String id,
    required String nombre,
    required String tipo,
    required String pais,
    String? email,
  }) async {
    final emailLimpio = (email ?? '').trim();
    await _supabase
        .from('negocios')
        .update(<String, dynamic>{
          'nombre': nombre.trim(),
          'tipo': tipo,
          'pais': pais,
          'email': emailLimpio.isEmpty ? null : emailLimpio,
        })
        .eq('id', id);
    await _descarga.descargarNegocio(id);
  }

  /// Descarga un negocio y sus datos a la base local (Drift) para gestionarlo
  /// reutilizando las pantallas existentes. Delega en [ServicioDescargaNegocio].
  Future<void> descargarNegocio(String negocioId) =>
      _descarga.descargarNegocio(negocioId);
}
