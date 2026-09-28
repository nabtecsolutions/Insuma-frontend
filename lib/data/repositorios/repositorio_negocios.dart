import 'package:drift/drift.dart';
import '../../database/database.dart';
import '../mapeadores_supabase.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio de Negocios (HU-072).
///
/// Distingue dos altas con semántica de sincronización OPUESTA:
/// - [crear]: el negocio es nuevo y todavía NO existe en el backend → se ENCOLA su INSERT.
/// - [espejarLocal]: el negocio YA existe en el backend y sólo falta en esta base
///   local (dispositivo nuevo) → NO se encola nada.
/// Colapsarlas cambiaría qué se sincroniza.
abstract class RepositorioNegocios {
  Future<Negocio?> obtener(String id);

  /// Alta de un negocio nuevo (se encola el INSERT hacia Supabase).
  Future<Negocio> crear({
    required String id,
    required String nombre,
    required String tipo,
    String pais,
    String? email,
  });

  /// Espeja un negocio que ya existe en el backend. NO encola (evita duplicar).
  Future<void> espejarLocal({
    required String id,
    required String nombre,
    required String tipo,
    String pais,
    String? email,
  });
}

class RepositorioNegociosDrift extends RepositorioSincronizable
    implements RepositorioNegocios {
  RepositorioNegociosDrift(super.db, super.sync);

  static const String _tabla = 'negocios';

  @override
  Future<Negocio?> obtener(String id) =>
      (db.select(db.negocios)..where((n) => n.id.equals(id))).getSingleOrNull();

  @override
  Future<Negocio> crear({
    required String id,
    required String nombre,
    required String tipo,
    String pais = 'Argentina',
    String? email,
  }) async {
    await db
        .into(db.negocios)
        .insert(
          NegociosCompanion.insert(
            id: id,
            nombre: nombre,
            tipo: tipo,
            pais: Value(pais),
            email: Value(email),
            fechaCreacion: Value(DateTime.now()),
          ),
        );
    final creado = await (db.select(
      db.negocios,
    )..where((n) => n.id.equals(id))).getSingle();
    await encolarInsert(_tabla, id, MapeadoresSupabase.negocio(creado));
    return creado;
  }

  @override
  Future<void> espejarLocal({
    required String id,
    required String nombre,
    required String tipo,
    String pais = 'Argentina',
    String? email,
  }) async {
    await db
        .into(db.negocios)
        .insert(
          NegociosCompanion.insert(
            id: id,
            nombre: nombre,
            tipo: tipo,
            pais: Value(pais),
            email: Value(email),
            fechaCreacion: Value(DateTime.now()),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }
}
